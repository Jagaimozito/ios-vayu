#!/usr/bin/env python3
"""Emit the availability version list expected by XNU's make_symbol_aliasing.sh."""
import pathlib
import re
import subprocess
import sys

if len(sys.argv) != 2 or sys.argv[1] not in ("--macosx", "--ios"):
    raise SystemExit("usage: availability.pl --macosx|--ios")

platform, sdk, prefix = (
    ("MAC", "macosx", "__MAC_")
    if sys.argv[1] == "--macosx"
    else ("IPHONE", "iphoneos", "__IPHONE_")
)
sdk_root = subprocess.check_output(
    ["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True
).strip()
header = pathlib.Path(sdk_root) / "usr/include/AvailabilityVersions.h"
versions = []
pattern = re.compile(r"^#define " + re.escape(prefix) + r"(\d+)_(\d+)(?:_(\d+))?\s")
for line in header.read_text().splitlines():
    match = pattern.match(line)
    if match:
        versions.append(".".join(part for part in match.groups() if part is not None))
print(" ".join(versions))
