#!/bin/bash
# Build the SWEET macOS 27 kernel on this Mac: the same xnu-12377 tree as iOS 27 (work/xnu-12377), built for
# PLATFORM=MacOSX (macosx SDK -> XNU_TARGET_OS_OSX) with xnu/macos27/MASTER.arm64.sweet.MacOSX. Its objects go
# to BUILD/obj-macos27-sweet, so the iOS 27 build (BUILD/obj-ios26-sweet) is not touched.
#
#   tools/mkmacos27kernel.sh            -> work/xnu-12377/BUILD/obj-macos27-sweet/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet
#                                          log: work/xnu12377-macos27-build.log
#
# The source tree is shared with iOS 27: a source fix needed only for macOS goes under #if XNU_TARGET_OS_OSX
# (or CONFIG_EMBEDDED for iOS-only code), so the iOS kernel keeps building unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
X=$REPO/work/xnu-12377
[ -d "$X/config" ] || { echo "no $X" >&2; exit 1; }
# Xcode's current SDK omits availability.pl. Use the SDK-header reader unless
# the caller supplied a compatible availability.pl implementation.
export XNU_AVAILABILITY_PL="${XNU_AVAILABILITY_PL:-$REPO/tools/macos27-availability-versions.py}"
cp xnu/macos27/MASTER.arm64.sweet.MacOSX "$X/config/MASTER.arm64.sweet.MacOSX"
# Keep the kernel support libraries separate from the iOS SDK. The XNU tree's
# bootstrap SDK is iOS-built, while this macOS kernel needs a macOS-built
# firehose archive. Reuse its headers and cc_kext archive in a distinct SDK,
# then substitute the local macOS 27.2 firehose archive.
KERNEL_SDKROOT="$X/BUILD/sdk-macos27"
if [ ! -f "$KERNEL_SDKROOT/usr/local/lib/kernel/libcc_kext.a" ]; then
	ditto "$X/BUILD/sdk-ios26" "$KERNEL_SDKROOT"
fi
MACOS_FIREHOSE="$REPO/work/xnu-local-latest/dxb/fakeroot/usr/local/lib/kernel/libfirehose_kernel.a"
[ -s "$MACOS_FIREHOSE" ] || { echo "no macOS firehose archive: $MACOS_FIREHOSE" >&2; exit 1; }
mkdir -p "$KERNEL_SDKROOT/usr/local/lib/kernel"
cp "$MACOS_FIREHOSE" "$KERNEL_SDKROOT/usr/local/lib/kernel/libfirehose_kernel.a"
cd "$X"
make -j4 MAKEJOBS=-j4 \
	SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" KERNEL_SDKROOT="$KERNEL_SDKROOT" \
	OBJROOT="$X/BUILD/obj-macos27-sweet" SYMROOT="$X/BUILD/obj-macos27-sweet" \
	KERNEL_CONFIGS=DEVELOPMENT ARCH_CONFIGS=ARM64 MACHINE_CONFIGS=SWEET \
	BUILD_WERROR=0 BUILD_LTO=0 BUILD_DSYM=0 DO_CTFMERGE=0 MEMORY_SIZE=34359738368 \
	SYSCTL_HW_PHYSICALCPU=8 SYSCTL_HW_LOGICALCPU=8 RC_DARWIN_KERNEL_VERSION=25.5.0 \
	2>&1 | tee "$REPO/work/xnu12377-macos27-build.log"
K=$X/BUILD/obj-macos27-sweet/DEVELOPMENT_ARM64_SWEET/kernel.development.sweet
[ -f "$K" ] || { echo "no kernel: see work/xnu12377-macos27-build.log" >&2; exit 1; }
# Must be plain arm64 like the iOS 27 kernel (makedefs: SWEET -> -arch arm64, -march=armv8.2-a+crypto):
# the Kryo 485 has no pointer authentication, so an arm64e (PAC) kernel would fault on its first PAC instruction.
python3 - "$K" <<'PY'
import struct, sys
magic, cputype, cpusub = struct.unpack_from('<III', open(sys.argv[1], 'rb').read(12))
sub = cpusub & 0xff
print('kernel cputype %#x cpusubtype %d (%s)' % (cputype, sub, 'arm64e' if sub == 2 else 'arm64'))
sys.exit(1 if sub == 2 else 0)
PY
shasum -a 256 "$K"
