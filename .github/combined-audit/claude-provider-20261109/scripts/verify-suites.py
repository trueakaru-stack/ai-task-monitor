#!/usr/bin/env python3
"""Check the complete XCTest run against the required synthetic suites."""
from pathlib import Path
import re
import sys

log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
expected = Path(sys.argv[2]).read_text(encoding="utf-8").split()
failed = False
for entry in expected:
    suite, count = entry.rsplit(":", 1)
    pattern = re.compile(r"Test Suite '" + re.escape(suite) + r"' passed at[^\n]*\n\s*Executed " + re.escape(count) + r" tests?, with 0 failures\b")
    if not pattern.search(log):
        print("Missing successful expected suite:", suite, "count", count)
        failed = True
started = len(re.findall(r"Test Case '-\[AITaskMonitorTests\.[^\]]+\]' started\.", log))
skipped = len(re.findall(r"Test Case .* skipped \(", log))
print("Full XCTest run:", started, "started;", skipped, "skipped")
if started < 400 or skipped:
    failed = True
sys.exit(1 if failed else 0)
