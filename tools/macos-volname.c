/*
 * macos-volname: what hfs.util -p asks of a mounted HFS volume (getmntinfo match, then getattrlist ATTR_VOL_NAME),
 * printed step by step, for Disk Arbitration's failing probe of the SWEET root (2026-11-22).
 * Build on the Mac: clang -arch arm64 -O2 -o outputs/volname tools/macos-volname.c
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/attr.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	const char *dev = argc > 1 ? argv[1] : "/dev/ufsroot0";
	struct statfs *m;
	int n = getmntinfo(&m, MNT_NOWAIT);
	printf("getmntinfo: %d mounts\n", n);
	const char *mp = NULL;
	for (int i = 0; i < n; i++) {
		printf("  %s on %s type %s flags %#x fsid %#x:%#x\n", m[i].f_mntfromname, m[i].f_mntonname, m[i].f_fstypename,
		    m[i].f_flags, m[i].f_fsid.val[0], m[i].f_fsid.val[1]);
		if (!strcmp(m[i].f_mntfromname, dev))
			mp = m[i].f_mntonname;
	}
	printf("match for %s: %s\n", dev, mp ? mp : "(none)");
	if (!mp)
		mp = "/";
	struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT, .volattr = ATTR_VOL_INFO | ATTR_VOL_NAME };
	struct { uint32_t len; attrreference_t name; char buf[1024]; } __attribute__((packed)) r;
	memset(&r, 0, sizeof(r));
	int e = getattrlist(mp, &al, &r, sizeof(r), 0);
	printf("getattrlist(%s, ATTR_VOL_NAME): %d errno %d (%s)\n", mp, e, e ? errno : 0, e ? strerror(errno) : "ok");
	if (!e)
		printf("  len %u name offset %d length %u: '%s'\n", r.len, r.name.attr_dataoffset, r.name.attr_length,
		    (char *)&r.name + r.name.attr_dataoffset);
	struct attrlist al2 = { .bitmapcount = ATTR_BIT_MAP_COUNT, .commonattr = ATTR_CMN_NAME };
	memset(&r, 0, sizeof(r));
	e = getattrlist(mp, &al2, &r, sizeof(r), 0);
	printf("getattrlist(%s, ATTR_CMN_NAME): %d errno %d: '%s'\n", mp, e, e ? errno : 0, e ? "" : (char *)&r.name + r.name.attr_dataoffset);
	return 0;
}
