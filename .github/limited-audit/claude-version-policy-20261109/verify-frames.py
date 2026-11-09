#!/usr/bin/env python3
import struct
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Expected frame directory")
root = Path(sys.argv[1]).resolve(strict=True)
if not str(root).startswith("/private/tmp/aitm-policy-") or root.name != "frames":
    raise SystemExit("Unexpected frame directory")
expected = {
    f"claude-requirement-{state}-{language}-{mode}.png"
    for state in ("disconnected", "partial", "connected")
    for language in ("ru", "en")
    for mode in ("dark", "light")
}
entries = list(root.iterdir())
if {item.name for item in entries} != expected or len(entries) != 12:
    raise SystemExit("Unexpected frame set")
for image in entries:
    if image.is_symlink() or not image.is_file() or not 24 <= image.stat().st_size <= 5_000_000:
        raise SystemExit("Invalid frame file")
    with image.open("rb") as stream:
        head = stream.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise SystemExit("Invalid PNG header")
    width, height = struct.unpack(">II", head[16:24])
    if not 300 <= width <= 2400 or not 400 <= height <= 3000:
        raise SystemExit("Unexpected PNG dimensions")
    print(f"{image.name}: {width}x{height}")
print("Exactly 12 synthetic PNGs verified; visual acceptance requires inspection.")
