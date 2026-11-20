#!/bin/bash
# macOS 27 kernel test image: the macOS kernel (tools/mkmacos27kernel.sh) with the phone's device tree and
# boot-args taken from the working iOS 27 boot image, then the menu image with both:
#
#   tools/mkmacos27boot.sh IOS27_boot.img [KERNEL]
#     -> outputs/guacamole-macos27-kernel.img     (macOS payload only)
#        outputs/guacamole-menu-ios27-macos27.img (menu: iOS 27 + macOS 27 + Android)
#
# Boot-args: the iOS 27 ones with ufsroot=macos, without rootrw=1 (nothing is installed on `macos` yet, the
# kernel is expected to stop at the root mount) and without sweetfb_noconsole=1, plus -v: the kernel log is
# drawn on the screen. ufsrw=1 stays so the SWEETLOG ring reaches the end of `macos`
# (PART=macos sh tools/ios27-klog-pull.sh). The ADT is the iOS 27 one (same hardware); a Mac17,5 identity
# comes later. Writes nothing to the phone.
set -euo pipefail
[ $# -ge 1 ] || { sed -n '2,13p' "$0"; exit 1; }
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
IOS=$(abs "$1")
cd "$(dirname "$0")/.."
K=${2:-work/xnu-12377/BUILD/obj-macos27-sweet/DEVELOPMENT_ARM64_SWEET/mach.development.sweet}
[ -f "$K" ] || { echo "no kernel $K: run tools/mkmacos27kernel.sh" >&2; exit 1; }
[ -f shim/out/Image ] || { echo "no shim/out/Image: BOARD=guacamole shim/build.sh" >&2; exit 1; }
ARGS=$(python3 - "$IOS" <<'PY'
import re, struct, sys, time
b = open(sys.argv[1], 'rb').read()
f = struct.unpack_from('<8s10I', b, 0)
page, ksz, rsz = f[8], f[1], f[3]
off = page * (1 + (ksz + page - 1) // page)
rd = b[off:off + rsz]
assert rd[:8] == b'SWEETXNU', 'not a SWEETXNU payload'
adt_off, adt_size = struct.unpack_from('<QQ', rd, 0x20)
open('work/macos27-from-ios27.adt', 'wb').write(rd[adt_off:adt_off + adt_size])
a = rd[0x48:0x48 + 608].split(b'\0')[0].decode().split()
drop = {'rootrw=1', 'sweetfb_noconsole=1'}
a = [x for x in a if x not in drop]
a = ['ufsroot=macos' if x.startswith('ufsroot=') else 'sweettime=%d' % time.time() if x.startswith('sweettime=') else x for x in a]
for x in ('-v', 'keepsyms=1'):
    if x not in a:
        a.insert(0, x)
print(' '.join(a))
PY
)
echo "boot-args: $ARGS"
python3 tools/mkpayload.py "$K" work/macos27-from-ios27.adt work/payload-macos27.bin --cmdline "$ARGS"
python3 tools/mkguacboot.py dtb/android-boot_b.img shim/out/Image outputs/guacamole-macos27-kernel.img --ramdisk work/payload-macos27.bin
python3 tools/mkmenuboot.py dtb/android-boot_b.img shim/out/Image "$IOS" outputs/guacamole-macos27-kernel.img outputs/guacamole-menu-ios27-macos27.img
shasum -a 256 outputs/guacamole-macos27-kernel.img outputs/guacamole-menu-ios27-macos27.img
