#!/usr/bin/env python3
"""Run nine isolated bundle cases; report the separate unresolved case."""
from pathlib import Path
import sys
import unittest

fixture = Path(sys.argv[1]).resolve(strict=True)
sys.path.insert(0, str(fixture))
import test_provider_bundle

excluded = "test_python_generated_bytecode_is_removed_only_when_reproducible"
all_cases = list(unittest.defaultTestLoader.loadTestsFromTestCase(test_provider_bundle.ProviderBundleTests))
selected = [case for case in all_cases if case._testMethodName != excluded]
if len(all_cases) != 10 or len(selected) != 9 or sum(case._testMethodName == excluded for case in all_cases) != 1:
    raise SystemExit("Unexpected bundle test inventory")
print("Explicitly unverified:", excluded, flush=True)
result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite(selected))
if result.testsRun != 9 or result.skipped or not result.wasSuccessful():
    raise SystemExit(1)
