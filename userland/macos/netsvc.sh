#!/bin/sh
# netsvc for macOS (2026-11-22): what userland/flame/netsvc.m does on iOS, with macOS's scutil. wland (ipnet.c) runs
# /var/local/bin/netsvc for each DHCP lease on its utun; without it configd never heard of the Wi-Fi: SSH and plain
# IP worked, but there were no DNS servers and reachability said "Not Reachable", so apps had no internet.
#   netsvc up IF ADDR MASK ROUTER DNS [DNS2]   publish IF as a network service (IPv4 + DNS)
#   netsvc down IF                             remove it        netsvc show IF   print the keys
cmd=${1:-show}; ifname=${2:-utun0}
svc="5EE7C0DE-0000-4000-8000-$(printf %012d "$(printf '%s' "$ifname" | cksum | cut -d' ' -f1)" | cut -c1-12)"
k4="State:/Network/Service/$svc/IPv4"; kd="State:/Network/Service/$svc/DNS"; ki="State:/Network/Interface/$ifname/IPv4"
case "$cmd" in
up)
	[ $# -ge 6 ] || { echo "usage: netsvc up IF ADDR MASK ROUTER DNS [DNS2]" >&2; exit 2; }
	addr=$3 mask=$4 router=$5 dns="$6${7:+ $7}"
	/usr/sbin/scutil <<EOS
d.init
d.add Addresses * $addr
d.add SubnetMasks * $mask
d.add Router $router
d.add InterfaceName $ifname
d.add ConfigMethod Manual
set $k4
d.init
d.add ServerAddresses * $dns
set $kd
d.init
d.add Addresses * $addr
d.add SubnetMasks * $mask
set $ki
quit
EOS
	echo "netsvc: $ifname $addr router $router dns $dns -> service $svc"
	;;
down)
	printf 'remove %s\nremove %s\nremove %s\nquit\n' "$k4" "$kd" "$ki" | /usr/sbin/scutil
	echo "netsvc: $ifname removed"
	;;
show)
	printf 'show %s\nshow %s\nshow State:/Network/Global/IPv4\nshow State:/Network/Global/DNS\nquit\n' "$k4" "$kd" | /usr/sbin/scutil
	;;
esac
