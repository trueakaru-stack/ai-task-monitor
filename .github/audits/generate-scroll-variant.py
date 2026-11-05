#!/usr/bin/env python3
"""Apply one synthetic layout variant to an isolated checkout of the pinned source."""

import hashlib
import json
import pathlib
import sys

EXPECTED_ROOT_SHA256 = "4fcb7a47f5a6df8c41c69d15c845c3bccc8939a5e1e2c78ae20bb65bc6097fb1"
VARIANTS = {"baseline", "outer", "clip", "outer-clip"}


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise SystemExit("Pinned source does not contain exactly one expected layout anchor.")
    return source.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[2] not in VARIANTS:
        raise SystemExit("Expected: generate-scroll-variant.py <macos-copy> <variant> <audit-output>.")
    project, variant, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
    root_file = project / "Sources" / "AITaskMonitor" / "RootView.swift"
    raw = root_file.read_bytes()
    if hashlib.sha256(raw).hexdigest() != EXPECTED_ROOT_SHA256:
        raise SystemExit("The pinned RootView source hash is different; no variant was written.")
    source = raw.decode("utf-8")
    if variant in {"outer", "outer-clip"}:
        source = replace_once(
            source,
            "        }\n    }\n\n    private var providerTabs: some View {",
            "        }\n        .frame(maxWidth: .infinity, alignment: .leading)\n    }\n\n    private var providerTabs: some View {",
        )
    if variant in {"clip", "outer-clip"}:
        source = replace_once(
            source,
            "    @State private var measuredCompactContentHeight: CGFloat = 0\n",
            "    @State private var measuredCompactContentHeight: CGFloat = 0\n    @State private var auditClipWidth: CGFloat = 0\n",
        )
        source = replace_once(
            source,
            ".frame(width: max(0, geometry.size.width - scrollerWidth), alignment: .leading)",
            ".frame(width: auditClipWidth > 0 ? auditClipWidth : max(0, geometry.size.width - scrollerWidth), alignment: .leading)",
        )
        source = replace_once(
            source,
            ".background(OverlayScrollerProbe(alwaysVisible: true).frame(width: 0, height: 0))",
            ".background(ScrollVariantClipProbe(width: $auditClipWidth).frame(width: 0, height: 0))\n                        .background(OverlayScrollerProbe(alwaysVisible: true).frame(width: 0, height: 0))",
        )
    generated = source.encode("utf-8")
    root_file.write_bytes(generated)
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"variant": variant, "sourceSHA256": EXPECTED_ROOT_SHA256,
                "generatedRootSHA256": hashlib.sha256(generated).hexdigest()}
    (output / "variant-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
