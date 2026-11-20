#!/bin/bash
# Build the macOS 27.2 (26B123, UniversalMac) root image for the `macos` partition on macOS (hdiutil + bsdtar), from
# the tars and lowered overlays in research/macos27 (NOTES.md "macOS 27.2 arm64e userland lowering"). Same approach
# as tools/mkios27root-mac.sh: one case-sensitive journaled HFS+ volume, the lowered overlays laid over Apple's files.
#
# What a Mac spreads over several APFS volumes goes into the one volume here:
#   - System volume (os-root.tar) at /.
#   - Data volume: a Mac's installer creates it from /System/Library/Templates/Data (private/etc, private/var, Users,
#     Library, Applications, ...). Here the template is merged into / without replacing anything, so the firmlinked
#     paths of /usr/share/firmlinks (/private, /Users, /Library, /Applications, ...) are real directories, and
#     /System/Volumes/Data is a symlink to / for code that uses the Data volume's path.
#   - Preboot: the SystemOS and AppOS cryptexes at /System/Volumes/Preboot/Cryptexes/{OS,App}; the system volume's own
#     /System/Cryptexes/{OS,App} symlinks already point there. Both dyld shared caches (system, DriverKit) are also
#     hard-linked to their root paths, and cryptex-only files to theirs, as on iOS.
# First goal: launchd starting and the verbose console, no WindowServer.
#
#   tools/mkmacos27root-mac.sh [SIZE]      (SIZE default 40g: about 31 GB of files; the raw .cdr is SIZE bytes)
#       -> research/macos27/macos27-root.cdr (raw) and macos27-root.simg (fastboot: `fastboot flash macos ...`)
#
# Needs sudo (ownership). Writes nothing to the phone.
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$(dirname "$0")/../research/macos27"
size=${1:-40g}
R=/tmp/macos27-root
for f in os-root.tar systemos-cryptex.tar appos-cryptex.tar overlay/os-root-lowered.tar \
	overlay/systemos-cryptex-lowered.tar overlay/appos-cryptex-lowered.tar overlay/dsc-system-lowered-0.tar \
	overlay/dsc-driverkit-lowered-0.tar; do
	[ -f "$f" ] || { echo "missing research/macos27/$f" >&2; exit 1; }
done
[ ! -e macos27-root.sparseimage ] || { echo "macos27-root.sparseimage exists: remove it first" >&2; exit 1; }

hdiutil create -size "$size" -type SPARSE -fs "Case-sensitive Journaled HFS+" -layout NONE -volname MacRoot27 macos27-root
hdiutil attach -owners on -nobrowse -mountpoint "$R" macos27-root.sparseimage
trap 'hdiutil detach "$R" >/dev/null 2>&1 || true' EXIT

x() {	# extract tar $1 into $2 as root, keeping owners and modes, without the tars' AppleDouble entries
	echo "extract $1 -> ${2#"$R"}/"
	sudo mkdir -p "$2"
	sudo tar -xpf "$1" -C "$2" --exclude '._*' --exclude './._*' --exclude '*/._*'
}
P="$R/System/Volumes/Preboot/Cryptexes"
x os-root.tar "$R"
x overlay/os-root-lowered.tar "$R"
x systemos-cryptex.tar "$P/OS"
x overlay/systemos-cryptex-lowered.tar "$P/OS"
for t in overlay/dsc-system-lowered-*.tar; do x "$t" "$P/OS"; done
x overlay/dsc-driverkit-lowered-0.tar "$P/OS"
x appos-cryptex.tar "$P/App"
x overlay/appos-cryptex-lowered.tar "$P/App"

# Data volume template merged into / (cp -n: nothing of the system volume is replaced; symlinks stay symlinks).
tpl="$R/System/Library/Templates/Data"
sudo test -d "$tpl" || { echo "no System/Library/Templates/Data in os-root.tar" >&2; exit 1; }
sudo cp -Rpn "$tpl/." "$R/"
echo "Data template merged into /"
# /System/Volumes/Data: an empty mount point in the tar; here the Data volume is / itself.
if sudo test -d "$R/System/Volumes/Data" && [ -z "$(sudo ls -A "$R/System/Volumes/Data")" ]; then
	sudo rmdir "$R/System/Volumes/Data"
	sudo ln -s / "$R/System/Volumes/Data"
	echo "/System/Volumes/Data -> /"
fi

# Shared caches where dyld also looks without the cryptex: hard links (no extra space).
for d in System/Library/dyld System/DriverKit/System/Library/dyld; do
	sudo test -d "$P/OS/$d" || continue
	sudo mkdir -p "$R/$d"
	for f in "$P/OS/$d"/*; do sudo ln -f "$f" "$R/$d/${f##*/}"; done
	echo "dyld caches: /$d"
done
# Cryptex files with no counterpart in the root: hard-linked (symlinks copied) to their root paths.
for c in OS App; do
	(cd "$P/$c" && sudo find . ! -type d ! -path './System/Library/dyld/*' ! -path './System/DriverKit/System/Library/dyld/*') |
	while IFS= read -r f; do
		f=${f#./}
		if ! sudo test -e "$R/$f" && ! sudo test -L "$R/$f"; then
			sudo mkdir -p "$R/$(dirname "$f")"
			src="$P/$c/$f"
			if sudo test -L "$src"; then sudo cp -P "$src" "$R/$f"; else sudo ln "$src" "$R/$f"; fi
		fi
	done
done
echo "cryptex-only files linked into /"

# launchd: Boot.fips -N if macOS launchd has that task (lowered corecrypto fails cc_fips_test's integrity HMAC on iOS;
# POST tests still run). Skipped, not fatal, if this launchd has no embedded Boot.fips.
if sudo python3 "$TOOLS/launchd-fips-noverify.py" "$R/sbin/launchd" /tmp/macos27-launchd.new; then
	sudo sh -c 'cat /tmp/macos27-launchd.new > "$1"' _ "$R/sbin/launchd"	# keeps owner, mode, hard links
	echo "launchd: Boot.fips -N"
else
	echo "launchd: no Boot.fips change (see the message above)"
fi
sudo rm -f /tmp/macos27-launchd.new

df -h "$R"
hdiutil detach "$R"
trap - EXIT
# The partition gets the bare volume: a raw image (UDTO) of the sparse image, no partition map.
hdiutil convert macos27-root.sparseimage -format UDTO -o macos27-root
rm -f macos27-root.sparseimage	# disk space: the .cdr has everything; peak is sparse + cdr, then cdr + simg
ls -l macos27-root.cdr
shasum -a 256 macos27-root.cdr
# Sparse image for fastboot: ONLY with tools/hfs2simg.py (a generic converter drops all-zero blocks HFS uses).
python3 "$TOOLS/hfs2simg.py" macos27-root.cdr macos27-root.simg
ls -l macos27-root.simg
