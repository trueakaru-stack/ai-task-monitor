#!/usr/bin/env python3
"""Verify every named suite in the explicitly limited XCTest run."""
from pathlib import Path
import re
import sys

log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
entries = Path(sys.argv[2]).read_text(encoding="utf-8").split()
failed = False
total = 0
for entry in entries:
    suite, raw = entry.rsplit(":", 1)
    count = int(raw)
    total += count
    pattern = re.compile(r"Test Suite '" + re.escape(suite) + r"' passed at[^\n]*\n\s*Executed " + raw + r" tests?, with 0 failures\b")
    if not pattern.search(log):
        print("Missing successful expected suite:", suite, "count", count)
        failed = True
started = len(re.findall(r"Test Case '-\[AITaskMonitorTests\.[^\]]+\]' started\.", log))
skipped = len(re.findall(r"Test Case .* skipped \(", log))
print("Limited XCTest:", len(entries), "suites;", started, "started of", total, ";", skipped, "skipped")
if len(entries) != 69 or total != 371 or started != total or skipped:
    failed = True
sys.exit(1 if failed else 0)
