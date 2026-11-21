#!/bin/bash
# Add tools/macos27-extras.sh's files (Wi-Fi + SSH) to the EXISTING macOS 27 root image instead of rebuilding it, then
# remake the fastboot image. Run on the Mac from anywhere; needs sudo.
#
#   tools/macos27-patch-cdr.sh     research/macos27/macos27-root.cdr -> (changed in place) + macos27-root.simg
#
# Then: fastboot flash macos research/macos27/macos27-root.simg
set -euo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
cd "$TOOLS/../research/macos27"
[ -f macos27-root.cdr ] || { echo "missing research/macos27/macos27-root.cdr" >&2; exit 1; }
M=/tmp/macos27-root-patch
mkdir -p "$M"
hdiutil attach -owners on -nobrowse -imagekey diskimage-class=CRawDiskImage -mountpoint "$M" macos27-root.cdr
trap 'hdiutil detach "$M" >/dev/null 2>&1 || true' EXIT
bash "$TOOLS/macos27-extras.sh" "$M"
df -h "$M"
hdiutil detach "$M"
trap - EXIT
python3 "$TOOLS/hfs2simg.py" macos27-root.cdr macos27-root.simg
ls -l macos27-root.simg
