#!/bin/sh
# hfs.util wrapper (SWEET macOS, 2026-11-22). macOS 27's hfs.util -p on a disk whose HFS volume is already mounted
# prints the volume name and then exits FSUR_IO_FAIL (252) instead of FSUR_RECOGNIZED (255). The SWEET root is such
# a disk (mounted by the kernel, no APFS container), so Disk Arbitration never recognised it ("Mounted: No") and
# login waited on it. For that one case the name is passed on as recognised; everything else goes to the real tool.
R="$(dirname "$0")/hfs.util.real"
if [ "$1" = "-p" ] && [ -n "$2" ]; then
	case "$2" in
	/dev/*) d="$2" ;;
	*) d="/dev/$2" ;;
	esac
	if /sbin/mount | /usr/bin/awk -v d="$d" '$1 == d && /\(hfs/ { f = 1 } END { exit !f }'; then
		out=$("$R" "$@")
		st=$?
		if [ $st -eq 252 ] && [ -n "$out" ]; then
			printf '%s' "$out"
			exit 255
		fi
		printf '%s' "$out"
		exit $st
	fi
fi
exec "$R" "$@"
