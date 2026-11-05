#!/usr/bin/env python3
"""Expose task replacement only in a pinned disposable synthetic CI copy."""

import hashlib
import json
import pathlib
import sys

EXPECTED = "110ebd014105b0816ad69b3e6d2694e2fa9c8e27f11e63a7f0542005b8c4c7f2"
APPEND = r'''

// Test-only extension generated in a disposable GitHub-hosted checkout.
@MainActor
extension TaskStore {
    func replaceSyntheticAuditTasks(_ values: [MonitoredTask]) {
        let env = ProcessInfo.processInfo.environment
        precondition(env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" && env["GITHUB_ACTIONS"] == "true" &&
                     env["CI"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted" &&
                     env["RUNNER_OS"] == "macOS" && diagnosticWorker == nil)
        tasks = values
    }
}
'''


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Expected: generate-scroll-bottom.py <macos-copy> <audit-output>.")
    project, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    target = project / "Sources" / "AITaskMonitor" / "TaskStore.swift"
    source = target.read_bytes()
    if hashlib.sha256(source).hexdigest() != EXPECTED:
        raise SystemExit("Pinned TaskStore hash mismatch; no synthetic extension was written.")
    generated = source + APPEND.encode("utf-8")
    target.write_bytes(generated)
    manifest = {"sourceSHA256": EXPECTED, "generatedSHA256": hashlib.sha256(generated).hexdigest()}
    (output / "bottom-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
