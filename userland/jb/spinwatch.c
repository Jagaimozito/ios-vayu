/*
 * spinwatch: restarts daemons that get stuck spinning a whole core. 2026-11-17.
 *   spinwatch [NAME...]        (default: locationd)  run by launchd (com.sweet.spinwatch), log on stdout
 * locationd comes up spinning at ~98 % of a core after every boot (thread in libdispatch's
 * _dispatch_wait_for_enqueuer -> _pthread_yield_to_enqueuer_4dispatch: a queue link that never appears; NOTES
 * "Responsiveness"); killed, launchd starts a fresh one that behaves. Root cause still open. Every 10 s this looks at
 * the CPU time of the named processes (sysctl KERN_PROC_ALL, proc_pidinfo PROC_PIDTASKINFO); one above 85 % of a core
 * for 3 checks in a row (30 s) gets SIGKILL (pid > 1 and the name checked again right before), at most once per
 * 5 minutes per name. Signed with tsample.plist (root reads every process).
 * MIT, as userland/.
 */
#include <mach/mach_time.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

struct ptaskinfo {
	uint64_t virtual_size, resident_size, total_user, total_system, threads_user, threads_system;
	int32_t policy, faults, pageins, cow_faults, msgs_sent, msgs_recv, sys_mach, sys_unix, csw, threadnum, numrunning,
	    priority;
};
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
#define PIDTASKINFO 4
#define MAXW 8
#define INTERVAL 10
#define LIMIT 85.0
#define STRIKES 3
#define COOLDOWN 300

static struct {
	int pid, strikes;
	uint64_t cpu;           /* task user + system time, mach units */
	uint64_t last_kill;     /* monotonic seconds (the wall clock jumps at boot: sweettime, then network time) */
} w[MAXW];

static uint64_t mono_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec + 1;         /* + 1: 0 means never */
}

static void say(const char *fmt, const char *name, int pid, double pct)
{
	char ts[32];
	time_t now = time(NULL);
	strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
	printf("%s spinwatch: ", ts);
	printf(fmt, name, pid, pct);
	printf("\n");
	fflush(stdout);
}

static int name_of(int pid, char *out, size_t len)
{
	int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
	struct kinfo_proc kp;
	size_t l = sizeof kp;
	if (sysctl(mib, 4, &kp, &l, NULL, 0) != 0 || l != sizeof kp)
		return -1;
	strlcpy(out, kp.kp_proc.p_comm, len);
	return 0;
}

int main(int argc, char **argv)
{
	const char *names[MAXW];
	int n = 0;
	for (int i = 1; i < argc && n < MAXW; i++)
		names[n++] = argv[i];
	if (n == 0)
		names[n++] = "locationd";
	mach_timebase_info_data_t tb;
	mach_timebase_info(&tb);
	for (int i = 0; i < n; i++)
		say("watching %s (pid %d, limit %.0f%% of a core for 30 s)", names[i], 0, LIMIT);
	uint64_t last = mach_absolute_time();
	for (;;) {
		sleep(INTERVAL);
		uint64_t now = mach_absolute_time();
		double wall_ns = (double)(now - last) * tb.numer / tb.denom;
		last = now;
		int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
		size_t len = 0;
		if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0)
			continue;
		len += 64 * sizeof(struct kinfo_proc);
		struct kinfo_proc *kp = malloc(len);
		if (!kp || sysctl(mib, 3, kp, &len, NULL, 0) != 0) {
			free(kp);
			continue;
		}
		size_t count = len / sizeof *kp;
		for (int i = 0; i < n; i++) {
			int pid = -1;
			for (size_t k = 0; k < count; k++)
				if (strncmp(kp[k].kp_proc.p_comm, names[i], MAXCOMLEN) == 0) {
					pid = kp[k].kp_proc.p_pid;
					break;
				}
			struct ptaskinfo t;
			if (pid <= 1 || proc_pidinfo(pid, PIDTASKINFO, 0, &t, sizeof t) != (int)sizeof t) {
				w[i].pid = 0;
				continue;
			}
			uint64_t cpu = t.total_user + t.total_system;
			if (w[i].pid != pid) {          /* new process: start counting */
				w[i].pid = pid;
				w[i].cpu = cpu;
				w[i].strikes = 0;
				continue;
			}
			double pct = 100.0 * (double)(cpu - w[i].cpu) * tb.numer / tb.denom / wall_ns;
			w[i].cpu = cpu;
			w[i].strikes = pct > LIMIT ? w[i].strikes + 1 : 0;
			if (w[i].strikes < STRIKES)
				continue;
			uint64_t t_now = mono_s();
			if (w[i].last_kill && t_now - w[i].last_kill < COOLDOWN) {
				if (w[i].strikes == STRIKES)
					say("%s[%d] spinning (%.0f%%) but restarted less than 5 min ago: left alone", names[i], pid, pct);
				continue;
			}
			char now_name[MAXCOMLEN + 1];
			if (pid <= 1 || name_of(pid, now_name, sizeof now_name) != 0 ||
			    strncmp(now_name, names[i], MAXCOMLEN) != 0)
				continue;
			say("%s[%d] spinning at %.0f%% of a core for 30 s: SIGKILL (launchd restarts it)", names[i], pid, pct);
			kill(pid, SIGKILL);
			w[i].last_kill = t_now;
			w[i].strikes = 0;
			w[i].pid = 0;
		}
		free(kp);
	}
}
