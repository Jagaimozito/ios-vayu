#!/bin/sh
# macOS 27 bring-up diagnostics on the console (job com.sweet.diag, tools/macos27-extras.sh). 2026-11-20 v2: rounds
# 3 and 8 also dump wland's milestones and its last 30 lines (DIAG 6 was still at rmtfs with only 2 lines to go on).
# v3: wland's utun gets the DHCP address but no routes on macOS (on iOS netsvc tells configd, which sets the default
# route; there is no macOS netsvc): add the default route through the utun with the lease, once it is up.
netfix() {
	netstat -rn -f inet 2>/dev/null | grep -q '^default' && return	# (v4: `route get default` said yes with no default route)
	for i in $(ifconfig -l); do
		case $i in utun*) ;; *) continue ;; esac
		a=$(ifconfig "$i" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\) --> .*/\1/p')
		[ -n "$a" ] || continue
		echo "SWEET DIAG: default route -> $i ($a): $(route -n add -net 0.0.0.0/0 -interface "$i" 2>&1)"
	done
}
sleep 45
n=0
while [ $n -lt 40 ]; do
	{
		netfix
		echo "SWEET DIAG $n: wland: $(tail -n 2 /var/local/wland.out 2>/dev/null | tr '\n' ' ')"
		echo "SWEET DIAG $n: inet: $(ifconfig 2>/dev/null | grep 'inet ' | tr '\n' ' ')"
		echo "SWEET DIAG $n: routes: $(netstat -rn -f inet 2>/dev/null | grep -E '^(default|172|0)' | tr -s ' ' | tr '\n' ';')"
		echo "SWEET DIAG $n: cfprefsd: $(launchctl print system/com.apple.cfprefsd.xpc.daemon 2>&1 | grep -i -E 'last exit|runs' | tr '\n' ' ')"
		if [ $n -eq 3 ] || [ $n -eq 8 ]; then
			echo "SWEET DIAG $n: ---- wland milestones ----"
			grep -i -E 'pas|mission|wlfw|radio|scan|join|dhcp|utun|fail|error|timeout|refus|cannot|lease|ready' /var/local/wland.out 2>/dev/null |
				grep -v 'rmtfs: write' | tail -n 20 | sed 's/^/SWEET WL: /'
			echo "SWEET DIAG $n: ---- wland last 30 lines ($(wc -l < /var/local/wland.out 2>/dev/null) total) ----"
			tail -n 30 /var/local/wland.out 2>/dev/null | cut -c1-150 | sed 's/^/SWEET WL: /'
		fi
	} > /dev/console
	n=$((n + 1))
	sleep 30
done
