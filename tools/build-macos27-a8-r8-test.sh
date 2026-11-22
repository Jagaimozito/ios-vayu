#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/outputs/macos27-a8-r8-test"
mkdir -p "$OUT"
xcrun --sdk macosx metal -c "$ROOT/research/macos27/a8-r8-upload-test.metal" -o "$OUT/a8-r8-upload-test.air" -mmacosx-version-min=27.0
xcrun --sdk macosx metallib "$OUT/a8-r8-upload-test.air" -o "$OUT/a8-r8-upload-test.metallib"
xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
  "$ROOT/research/macos27/a8-r8-upload-test.mm" -framework Foundation -framework Metal \
  -o "$OUT/a8-r8-upload-test"
codesign --force --sign - "$OUT/a8-r8-upload-test"
shasum -a 256 "$OUT/a8-r8-upload-test" "$OUT/a8-r8-upload-test.metallib"
file "$OUT/a8-r8-upload-test"
