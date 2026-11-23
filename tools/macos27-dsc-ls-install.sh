#!/bin/bash
# Test, then install, the LaunchServices LinkBinding patch (dyld_shared_cache_arm64e.01).
#   1. copy the patched .01:  ssh guacmac 'cat > /var/local/dsc.01.new' < outputs/dsc.01.ls-linkbinding
#   2. test only:             ssh guacmac 'bash -s' test < tools/macos27-dsc-ls-install.sh
#   3. install:               ssh guacmac 'bash -s' install < tools/macos27-dsc-ls-install.sh   (then reboot)
#   undo:                     ssh guacmac 'bash -s' restore < tools/macos27-dsc-ls-install.sh  (then reboot)
set -u
NEW=/var/local/dsc.01.new
WANT_NEW=418833088b0091f5945d54aadd35222eba7b9c10b564a3d65dde4ea7f888641c
WANT_OLD=058aca5b552180f523016110f8b178e0e71f7baaf400bab15bcf510ac0227eec
DIRS="/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld /System/Library/dyld"
sum() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
echo "== installed .01 copies"
for d in $DIRS; do f=$d/dyld_shared_cache_arm64e.01; [ -e "$f" ] && echo "$f: $(sum "$f")" && ls -l "$f"; done
case "${1:-test}" in
test)
	[ "$(sum $NEW)" = "$WANT_NEW" ] || { echo "copy outputs/dsc.01.ls-linkbinding to $NEW first (sha mismatch)"; exit 1; }
	T=/var/local/dsc-test; rm -rf $T; mkdir -p $T
	for d in $DIRS; do [ -e $d/dyld_shared_cache_arm64e ] && { SRC=$d; break; }; done
	echo "cache directory in use: $SRC"
	for f in $SRC/dyld_shared_cache_arm64e*; do ln -s "$f" "$T/$(basename "$f")"; done
	rm -f $T/dyld_shared_cache_arm64e.01; ln -s $NEW $T/dyld_shared_cache_arm64e.01
	for p in /Applications /; do
		echo "== probe $p with the patched cache"
		launchctl asuser 501 sudo -u corey env DYLD_SHARED_REGION=private DYLD_SHARED_CACHE_DIR=$T \
		    perl -e 'alarm 30; exec @ARGV' /var/local/bin/voliconprobe $p 2>&1 | grep -E 'icon for|dyld|cache' || echo "  icon for $p: CRASHED or TIMED OUT"
	done
	;;
install)
	[ "$(sum $NEW)" = "$WANT_NEW" ] || { echo "sha mismatch on $NEW"; exit 1; }
	for d in $DIRS; do
		f=$d/dyld_shared_cache_arm64e.01; [ -e "$f" ] || continue
		cur=$(sum "$f")
		if [ "$cur" = "$WANT_NEW" ]; then echo "$f already patched"; continue; fi
		[ "$cur" = "$WANT_OLD" ] || { echo "$f is neither the codesign-public nor the patched cache ($cur): left alone"; continue; }
		[ -e "$f.pre-ls" ] || cat "$f" > "$f.pre-ls"
		cat $NEW > "$f.new" && mv "$f.new" "$f" && echo "installed $f (previous kept as $f.pre-ls)"
	done
	sync
	echo "== where the installed copies lie on /dev/disk0 (for an offline TWRP restore)"
	for d in $DIRS; do f=$d/dyld_shared_cache_arm64e.01; [ -e "$f" ] && /var/local/bin/extents "$f"; done
	echo "now reboot: rm -f /var/run/com.apple.logind.didRunThisBoot; sync; reboot"
	;;
restore)
	for d in $DIRS; do f=$d/dyld_shared_cache_arm64e.01; [ -e "$f.pre-ls" ] && cat "$f.pre-ls" > "$f.new" && mv "$f.new" "$f" && echo "restored $f"; done
	sync
	;;
esac
