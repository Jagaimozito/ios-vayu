#!/usr/bin/env python3
"""Fail closed unless a macOS 27 plugin has a clean two-minute UI observation.

Inputs are a unified-log export (including loginwindow, launchd and WindowServer)
and a WindowServer NativeAdrenoMetal trace captured during the observation.
The log export must end with a timestamp marker, for example:
  GATE_OBSERVED_THROUGH=2026-11-22 14:32:00

The stable 490b9191 leak-fix build had zero NativeAdrenoMetal refusals (observed
at 23:04 and 23:42), so this gate treats any refusal as a failure, rather than
maintaining a growing allowlist.
"""

from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime
from pathlib import Path


STAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)")
FOOTER = re.compile(r"^GATE_OBSERVED_THROUGH=(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)\s*$", re.M)
MILESTONE = "LoginwindowUIShown"
WINDOWSERVER_EXIT = re.compile(
    r"(?:\bWindowServer\b.*\b(?:EXITED|EXIT|exited|crash(?:ed)?|terminated|exit\()"
    r"|\b(?:EXITED|EXIT|exited|crash(?:ed)?|terminated)\b.*\bWindowServer\b)",
    re.I,
)
REFUSAL = re.compile(r"native-metal:\s*([^\r\n]*?\brefused\s*:[^\r\n]*)", re.I)


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--system-log", required=True, type=Path)
    parser.add_argument("--gpu-trace", required=True, type=Path)
    parser.add_argument("--window-seconds", type=int, default=120)
    args = parser.parse_args()

    system = args.system_log.read_text(errors="replace")
    trace = args.gpu_trace.read_text(errors="replace")

    milestones = []
    timed_lines = []
    for line in system.splitlines():
        match = STAMP.match(line)
        if not match:
            continue
        try:
            at = parse_time(match.group(1))
        except ValueError:
            continue
        timed_lines.append((at, line))
        if MILESTONE in line:
            milestones.append((at, line))

    footer_match = FOOTER.search(system)
    if not milestones:
        print("FAIL: system log has no LoginwindowUIShown milestone")
        return 1
    if not footer_match:
        print("FAIL: system log is missing GATE_OBSERVED_THROUGH timestamp")
        return 1
    shown_at, shown_line = milestones[-1]
    try:
        observed_through = parse_time(footer_match.group(1))
    except ValueError:
        print("FAIL: invalid GATE_OBSERVED_THROUGH timestamp")
        return 1
    duration = (observed_through - shown_at).total_seconds()
    if duration < args.window_seconds:
        print(f"FAIL: only {duration:.1f}s observed after LoginwindowUIShown; need {args.window_seconds}s")
        return 1

    exits = [line for at, line in timed_lines if at >= shown_at and at <= observed_through and WINDOWSERVER_EXIT.search(line)]
    if exits:
        print(f"FAIL: {len(exits)} WindowServer exit/crash event(s) during the UI window")
        for line in exits[:10]:
            print(line)

    if "native-metal dump cb" not in trace and "WindowServer: native-metal:" not in trace:
        print("FAIL: GPU trace contains no WindowServer NativeAdrenoMetal capture")
        return 1
    refusals = REFUSAL.findall(trace)
    if refusals:
        categories = sorted({
            " ".join(item.split("refused", 1)[0].strip().split()[:2])
            for item in refusals
        })
        print(f"FAIL: {len(refusals)} NativeAdrenoMetal refusal(s); categories: {', '.join(categories)}")
        for item in refusals[:10]:
            print("native-metal: " + item.strip())

    if exits or refusals:
        return 1
    print(f"PASS: LoginwindowUIShown observed for {duration:.1f}s; no WindowServer exits and no GPU refusals")
    print("This candidate passes the 490b9191 zero-refusal baseline gate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
