/*
 * ksysctl: iOS has no sysctl command. Read kernel settings by name, or set an integer one (root).
 *   ksysctl NAME...            print each (integer or string)
 *   ksysctl NAME=VALUE         set an integer setting, then print it
 * 2026-11-23. MIT, as userland/.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/sysctl.h>

static int show(const char *name)
{
	char buf[4096];
	size_t len = sizeof(buf) - 1;
	if (sysctlbyname(name, buf, &len, NULL, 0) != 0) {
		fprintf(stderr, "%s: %s\n", name, strerror(errno));
		return 1;
	}
	if (len == sizeof(int)) {
		int v;
		memcpy(&v, buf, sizeof(v));
		printf("%s: %d\n", name, v);
	} else if (len == sizeof(long long) && buf[len - 1] != 0) {
		long long v;
		memcpy(&v, buf, sizeof(v));
		printf("%s: %lld\n", name, v);
	} else {
		buf[len] = 0;
		printf("%s: %s\n", name, buf);
	}
	return 0;
}

int main(int argc, char **argv)
{
	int rc = 0;
	if (argc < 2) {
		fprintf(stderr, "usage: ksysctl NAME... | NAME=VALUE\n");
		return 2;
	}
	for (int i = 1; i < argc; i++) {
		char *eq = strchr(argv[i], '=');
		if (eq) {
			*eq = 0;
			int v = atoi(eq + 1);
			if (sysctlbyname(argv[i], NULL, NULL, &v, sizeof(v)) != 0) {
				fprintf(stderr, "%s: %s\n", argv[i], strerror(errno));
				rc = 1;
				continue;
			}
		}
		rc |= show(argv[i]);
	}
	return rc;
}
