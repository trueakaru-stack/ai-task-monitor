#!/usr/bin/env python3
"""Add one fixedSize experiment to an already-instrumented disposable copy."""

import hashlib
import json
import pathlib
import sys

INSTRUMENTED_ROOT = "3ab24b097c056dcd2e338265769aed68314a5d4db8fefcfda20a3189e8aedc57"
INSTRUMENTED_CARD = "00063888e01ffba46d648d37b58b9dc249099c6166f619b118ede6091155aabe"
FRAME = ".frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)"
FIXED = ".fixedSize(horizontal: true, vertical: false)"


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[2] not in {"fixed-before", "fixed-after"}:
        raise SystemExit("Expected: generate-scroll-fixed.py <macos-copy> <fixed-before|fixed-after> <audit-output>.")
    project, variant, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
    root = project / "Sources" / "AITaskMonitor" / "RootView.swift"
    card = project / "Sources" / "AITaskMonitor" / "TaskCardView.swift"
    root_raw, card_raw = root.read_bytes(), card.read_bytes()
    if hashlib.sha256(root_raw).hexdigest() != INSTRUMENTED_ROOT or hashlib.sha256(card_raw).hexdigest() != INSTRUMENTED_CARD:
        raise SystemExit("Instrumented baseline hash mismatch; no experiment was written.")
    source = root_raw.decode("utf-8")
    if source.count(FRAME) != 1:
        raise SystemExit("Expected exactly one scroll-view frame.")
    if variant == "fixed-before":
        replacement = FIXED + "\n                    " + FRAME
    else:
        replacement = FRAME + "\n                    " + FIXED
    result = source.replace(FRAME, replacement, 1).encode("utf-8")
    root.write_bytes(result)
    manifest = {"variant": variant, "instrumentedRootSHA256": INSTRUMENTED_ROOT,
                "instrumentedCardSHA256": INSTRUMENTED_CARD,
                "generatedRootSHA256": hashlib.sha256(result).hexdigest()}
    (output / "fixed-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
