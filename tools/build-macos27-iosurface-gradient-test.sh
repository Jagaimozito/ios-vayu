#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/macos27-iosurface-gradient-test"
mkdir -p "$OUT"
xcrun --sdk macosx metal -c "$ROOT/research/macos27/iosurface-gradient-test.metal" -o "$OUT/iosurface-gradient-test.air" \
	-mmacosx-version-min=27.0 -fmodules-cache-path="$OUT/module-cache"
xcrun --sdk macosx metallib "$OUT/iosurface-gradient-test.air" -o "$OUT/iosurface-gradient-test.metallib"
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 -fmodules-cache-path="$OUT/module-cache" \
	"$ROOT/research/macos27/iosurface-gradient-test.mm" -framework Foundation -framework IOSurface -framework Metal \
	-o "$OUT/iosurface-gradient-test"
xcrun --sdk macosx clang -arch arm64 -O2 -mmacosx-version-min=27.0 \
	-o "$OUT/macos-surfdump" "$ROOT/tools/macos-surfdump.c" -framework IOSurface -framework CoreFoundation
codesign --force --sign - "$OUT/iosurface-gradient-test"
codesign --force --sign - "$OUT/macos-surfdump"
shasum -a 256 "$OUT/iosurface-gradient-test" "$OUT/iosurface-gradient-test.metallib" "$OUT/macos-surfdump"
file "$OUT/iosurface-gradient-test" "$OUT/macos-surfdump"
