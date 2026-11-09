"""Compare the app in the read-only mounted synthetic DMG with the built app."""
import hashlib
import json
import os
import stat
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("Usage: verify-dmg-contents.py BUILT_APP MOUNTPOINT")
built = Path(sys.argv[1])
mount = Path(sys.argv[2])
entries_at_root = []
for item in sorted(mount.iterdir(), key=lambda path: path.name):
    kind = "symlink" if item.is_symlink() else "directory" if item.is_dir() else "file" if item.is_file() else "other"
    entries_at_root.append({"name": item.name, "type": kind})
print(json.dumps({"dmgRootEntries": entries_at_root}, ensure_ascii=True, sort_keys=True))
copied = mount / "AI Task Monitor.app"
link = mount / "Applications"
if not link.is_symlink() or os.readlink(link) != "/Applications":
    raise SystemExit("DMG Applications link differs from the expected target")
def entries(root):
    if root.is_symlink() or not root.is_dir():
        raise SystemExit("Missing app directory")
    result = {}
    for path in root.rglob("*"):
        if path.is_symlink():
            raise SystemExit("Unexpected link inside app")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result
original, image = entries(built), entries(copied)
if not original or original != image:
    raise SystemExit("DMG app files differ from built app")
built_binary = built / "Contents/MacOS/AITaskMonitor"
image_binary = copied / "Contents/MacOS/AITaskMonitor"
built_exec = stat.S_IMODE(built_binary.stat().st_mode) & 0o111
image_exec = stat.S_IMODE(image_binary.stat().st_mode) & 0o111
if (built_exec != 0o111 or image_exec != built_exec or
    not os.access(built_binary, os.X_OK) or not os.access(image_binary, os.X_OK)):
    raise SystemExit("Executable permissions differ or execution access is unavailable")
print(json.dumps({"builtExecBits": oct(built_exec), "mountedExecBits": oct(image_exec)}, sort_keys=True))
print("Verified", len(original), "identical app files in mounted read-only image")
