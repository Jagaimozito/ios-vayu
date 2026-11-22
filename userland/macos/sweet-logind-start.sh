#!/bin/sh
# HFS+ keeps /var/run across boots. Apple daemons use didRunThisBoot markers
# to distinguish the first startup/session of a boot. Clear the stale markers
# once per kernel boot, but not on a KeepAlive restart mid-boot.
set -eu
boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || /usr/sbin/sysctl kern.boottime 2>/dev/null || true)
stamp=/var/db/.sweet-logind-bootstamp
old=$(cat "$stamp" 2>/dev/null || true)
if [ -n "$boot" ] && [ "$boot" != "$old" ]; then
	rm -f /var/run/com.apple.*.didRunThisBoot
	umask 077
	printf '%s\n' "$boot" > "$stamp.tmp"
	mv -f "$stamp.tmp" "$stamp"
fi
exec /System/Library/CoreServices/logind "$@"
