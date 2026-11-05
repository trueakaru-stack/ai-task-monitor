#!/usr/bin/env python3
"""Instrument an isolated pinned copy and optionally add a transparent outer document frame."""

import hashlib
import json
import pathlib
import sys

ROOT_HASH = "4fcb7a47f5a6df8c41c69d15c845c3bccc8939a5e1e2c78ae20bb65bc6097fb1"
CARD_HASH = "31439a037b66b3fbfbb5df1b981814caecf4039ddf48ca0706853f14a1dd4f03"


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise SystemExit("Pinned source does not have exactly one expected audit anchor.")
    return source.replace(old, new, 1)


def main() -> None:
    if len(sys.argv) != 4 or sys.argv[2] not in {"baseline", "wide"}:
        raise SystemExit("Expected: generate-scroll-wide.py <macos-copy> <baseline|wide> <audit-output>.")
    project, variant, output = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
    root_path = project / "Sources" / "AITaskMonitor" / "RootView.swift"
    card_path = project / "Sources" / "AITaskMonitor" / "TaskCardView.swift"
    root_raw, card_raw = root_path.read_bytes(), card_path.read_bytes()
    if hashlib.sha256(root_raw).hexdigest() != ROOT_HASH or hashlib.sha256(card_raw).hexdigest() != CARD_HASH:
        raise SystemExit("Pinned source hash mismatch; no instrumentation was written.")
    root, card = root_raw.decode("utf-8"), card_raw.decode("utf-8")
    root = replace_once(
        root,
        "ForEach(store.filteredTasks) { task in TaskCardView(task: task, showProvider: store.providers.count > 1) }",
        "ForEach(store.filteredTasks) { task in\n                                TaskCardView(task: task, showProvider: store.providers.count > 1)\n                                    .background(ScrollWideCardProbe(taskID: task.id).allowsHitTesting(false))\n                            }",
    )
    if variant == "wide":
        root = replace_once(
            root,
            ".frame(width: max(0, geometry.size.width - scrollerWidth), alignment: .leading)",
            ".frame(width: max(0, geometry.size.width - scrollerWidth), alignment: .leading)\n                        .frame(width: geometry.size.width, alignment: .leading)",
        )
    card = replace_once(
        card,
        'Button(tr("Скрыть", "Hide")) { store.dismissLoop(for: task.id) }\n                    .controlSize(.large)',
        'Button(tr("Скрыть", "Hide")) { store.dismissLoop(for: task.id) }\n                    .background(ScrollWideButtonProbe().allowsHitTesting(false))\n                    .controlSize(.large)',
    )
    root_bytes, card_bytes = root.encode("utf-8"), card.encode("utf-8")
    root_path.write_bytes(root_bytes)
    card_path.write_bytes(card_bytes)
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"variant": variant, "sourceRootSHA256": ROOT_HASH, "sourceCardSHA256": CARD_HASH,
                "generatedRootSHA256": hashlib.sha256(root_bytes).hexdigest(),
                "generatedCardSHA256": hashlib.sha256(card_bytes).hexdigest()}
    (output / "wide-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
