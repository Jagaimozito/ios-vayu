#!/bin/sh
# Build the userland helpers the macOS 27 root needs, for macOS (arm64, ad-hoc signed): macOS does not run iOS-platform
# binaries. Plain C, no frameworks, same sources as the iOS build (userland/build.sh).
#
#   userland/build-macos.sh      -> userland/out/macos/wland
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk macosx --show-sdk-path)
CC="xcrun --sdk macosx clang -arch arm64 -mmacos-version-min=14.0 -isysroot $SDK -O2 -Wall -Wextra"
mkdir -p out/macos
# Wi-Fi (userland/wland/README.md). Its netsvc step (configd) is iOS-only and just logs a failure on macOS: the
# address, route and SSH work without it; DNS for the phone itself waits for a macOS netsvc.
(cd wland && $CC -DWLAND_MACOS -Wno-unused-parameter -o ../out/macos/wland wland.c smem.c pmem.c glink.c link.c qmi.c rmtfs.c \
	pdmapper.c tftp.c scm.c wlfw.c radio.c ipnet.c bridge.c dms.c gnss.c)
codesign -f -s - out/macos/wland
echo out/macos/wland
