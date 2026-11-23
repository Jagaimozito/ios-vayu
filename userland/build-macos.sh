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
# Brightness (the panel's own, DCS 0x51) and Night Shift (the display controller's colour stage) for macOS:
# userland/jb/sweet-displayd.m with DisplayServices as the brightness source (2026-11-22).
xcrun --sdk macosx clang -arch arm64 -mmacos-version-min=14.0 -isysroot $SDK -O2 -fobjc-arc -framework Foundation \
	-framework CoreGraphics -o out/macos/sweet-displayd jb/sweet-displayd.m
codesign -f -s - --entitlements macos/sweet-displayd-ents.plist out/macos/sweet-displayd
echo out/macos/sweet-displayd
# Bluetooth: btbridge (userland/bt) in its -p mode, a pty at /dev/cu.BLTH for macOS's bluetoothd (H4 transport,
# BT_HCI_TRANSPORT=H4) instead of iOS's kernel control (2026-11-22).
$CC -Wno-unused-parameter -Wno-sign-compare -o out/macos/btbridge bt/btbridge.c wland/pmem.c -Iwland -Ibt
codesign -f -s - out/macos/btbridge
echo out/macos/btbridge
