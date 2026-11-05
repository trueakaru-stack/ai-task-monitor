#!/usr/bin/env python3
"""Change only the scroller's autohide flag in an isolated pinned source copy."""

import hashlib
import json
import pathlib
import sys

EXPECTED = "ee8c56b778c8b3db27df9a71af0cf2a5634e8574b6736629038538e0e88c0cba"


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Expected: generate-scroll-autohide.py <macos-copy> <audit-output>.")
    project, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    target = project / "Sources" / "AITaskMonitor" / "OverlayScrollerProbe.swift"
    raw = target.read_bytes()
    if hashlib.sha256(raw).hexdigest() != EXPECTED:
        raise SystemExit("Pinned scroller hash mismatch; no experiment was written.")
    source = raw.decode("utf-8")
    old = "scrollView.autohidesScrollers = false"
    if source.count(old) != 1:
        raise SystemExit("Expected exactly one scroller autohide assignment.")
    generated = source.replace(old, "scrollView.autohidesScrollers = true", 1).encode("utf-8")
    target.write_bytes(generated)
    manifest = {"variant": "autohide", "sourceSHA256": EXPECTED,
                "generatedSHA256": hashlib.sha256(generated).hexdigest()}
    (output / "autohide-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
