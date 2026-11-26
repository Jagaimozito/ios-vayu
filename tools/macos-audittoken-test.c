/*
 * macos-audittoken-test: does this kernel's audit token identify the process that sent it? (2026-11-23)
 *
 * WindowServer refuses the Accessibility Keyboard's key events ("Sender is prohibited from synthesizing events")
 * without tccd ever answering, and the permission prompt names the requester "Application". SkyLight's check
 * (_CGXSenderCanSynthesizeEvents, outputs/skylight-synth-check.txt) takes the sender's audit token from the message
 * trailer, audit_token_to_pid / _pidversion, then TCCAccessPreflightWithAuditToken(kTCCServicePostEvent). tccd and
 * the prompt resolve the token back to a process and its code signature (csops_audittoken, SecTask). If the token's
 * PID version does not match the kernel's own, every such lookup fails. This prints, for itself:
 *   the token's fields (pid, pidversion, uids, asid), csops vs csops_audittoken (status, cdhash),
 *   SecTaskCreateWithAuditToken's signing identifier, and the same for a task port of another PID if given.
 *
 * Build on the Mac:  xcrun --sdk macosx clang -arch arm64 -mmacos-version-min=14.0 -O2 -Wall \
 *     -framework Security -framework CoreFoundation -lbsm -o outputs/audittoken-test tools/macos-audittoken-test.c
 * Run on the phone:  /var/local/bin/audittoken-test   (as root, and as corey: sudo -u corey ...)
 */
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <bsm/libbsm.h>
#include <errno.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CS_OPS_STATUS   0
#define CS_OPS_CDHASH   5
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int csops_audittoken(pid_t pid, unsigned int ops, void *useraddr, size_t usersize, audit_token_t *token);

static void
hex(const char *what, const uint8_t *b, size_t n)
{
	printf("%s", what);
	for (size_t i = 0; i < n; i++)
		printf("%02x", b[i]);
	printf("\n");
}

static void
check(const char *who, audit_token_t tok)
{
	pid_t pid = audit_token_to_pid(tok);
	printf("== %s\n", who);
	printf("token val: %u %u %u %u %u %u %u %u\n", tok.val[0], tok.val[1], tok.val[2], tok.val[3], tok.val[4],
	    tok.val[5], tok.val[6], tok.val[7]);
	printf("pid %d pidversion %d euid %d ruid %d asid %d\n", pid, audit_token_to_pidversion(tok),
	    audit_token_to_euid(tok), audit_token_to_ruid(tok), audit_token_to_asid(tok));
	uint32_t st = 0, st2 = 0;
	int r1 = csops(pid, CS_OPS_STATUS, &st, sizeof(st));
	int e1 = errno;
	int r2 = csops_audittoken(pid, CS_OPS_STATUS, &st2, sizeof(st2), &tok);
	int e2 = errno;
	printf("csops status: %d (%s) flags 0x%08x | csops_audittoken status: %d (%s) flags 0x%08x\n",
	    r1, r1 ? strerror(e1) : "ok", st, r2, r2 ? strerror(e2) : "ok", st2);
	uint8_t h1[20] = { 0 }, h2[20] = { 0 };
	r1 = csops(pid, CS_OPS_CDHASH, h1, sizeof(h1));
	e1 = errno;
	r2 = csops_audittoken(pid, CS_OPS_CDHASH, h2, sizeof(h2), &tok);
	e2 = errno;
	printf("cdhash csops %d (%s), csops_audittoken %d (%s)\n", r1, r1 ? strerror(e1) : "ok", r2, r2 ? strerror(e2) : "ok");
	hex("  csops            ", h1, sizeof(h1));
	hex("  csops_audittoken ", h2, sizeof(h2));
	SecTaskRef t = SecTaskCreateWithAuditToken(NULL, tok);
	if (t == NULL) {
		printf("SecTaskCreateWithAuditToken: NULL\n");
		return;
	}
	CFErrorRef err = NULL;
	CFStringRef ident = SecTaskCopySigningIdentifier(t, &err);
	char buf[256] = "(none)";
	if (ident)
		CFStringGetCString(ident, buf, sizeof(buf), kCFStringEncodingUTF8);
	printf("SecTask signing identifier: %s%s\n", buf, err ? " (error)" : "");
	if (err) {
		CFStringRef d = CFErrorCopyDescription(err);
		if (d && CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8))
			printf("  error: %s\n", buf);
	}
	CFRelease(t);
}

int
main(int argc, char **argv)
{
	audit_token_t tok;
	mach_msg_type_number_t n = TASK_AUDIT_TOKEN_COUNT;
	kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&tok, &n);
	if (kr != KERN_SUCCESS) {
		printf("task_info(TASK_AUDIT_TOKEN): %d\n", kr);
		return 1;
	}
	printf("self pid %d uid %d\n", getpid(), getuid());
	check("own token (task_info)", tok);
	if (argc > 1) {
		pid_t other = atoi(argv[1]);
		mach_port_t task = MACH_PORT_NULL;
		kr = task_name_for_pid(mach_task_self(), other, &task);
		if (kr != KERN_SUCCESS)
			kr = task_for_pid(mach_task_self(), other, &task);
		if (kr != KERN_SUCCESS) {
			printf("task port for %d: %d\n", other, kr);
			return 1;
		}
		n = TASK_AUDIT_TOKEN_COUNT;
		kr = task_info(task, TASK_AUDIT_TOKEN, (task_info_t)&tok, &n);
		if (kr != KERN_SUCCESS) {
			printf("task_info(%d, TASK_AUDIT_TOKEN): %d\n", other, kr);
			return 1;
		}
		char who[64];
		snprintf(who, sizeof(who), "pid %d (task_info)", other);
		check(who, tok);
	}
	return 0;
}
