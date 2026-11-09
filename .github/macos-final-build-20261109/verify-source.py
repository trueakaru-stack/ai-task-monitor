"""Verify an exact source snapshot and its Git executable bits."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys


def read_manifests(checksums_path, modes_path):
    checksums = {}
    for line in checksums_path.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (macos/[A-Za-z0-9._/-]+)", line)
        if not match:
            raise ValueError("Invalid checksum manifest entry")
        digest, name = match.groups()
        parts = PurePosixPath(name).parts
        if name in checksums or any(part in (".", "..") for part in parts):
            raise ValueError("Unsafe or duplicate path")
        checksums[name] = digest
    def no_duplicate_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate mode path")
            result[key] = value
        return result
    modes = json.loads(modes_path.read_text(encoding="utf-8"), object_pairs_hook=no_duplicate_pairs)
    if len(checksums) != 224 or set(checksums) != set(modes):
        raise ValueError("Expected exactly 224 matching source paths")
    if any(mode not in ("100644", "100755") for mode in modes.values()):
        raise ValueError("Unsupported Git file mode")
    if modes.get("macos/scripts/build-app.sh") != "100755":
        raise ValueError("build-app.sh must be executable")
    return checksums, modes


def verify(root, checksums, modes, before):
    mac = root / "macos"
    if root.is_symlink() or mac.is_symlink() or not mac.is_dir():
        raise ValueError("Source directory is missing or is a symlink")
    if before:
        actual = set()
        for directory, dirs, files in os.walk(mac, followlinks=False):
            for name in dirs:
                path = Path(directory) / name
                if path.is_symlink():
                    raise ValueError("Symlink directory in source")
            for name in files:
                path = Path(directory) / name
                if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
                    raise ValueError("Non-regular source file")
                actual.add(path.relative_to(root).as_posix())
        if actual != set(checksums):
            raise ValueError("Source file set differs from manifest")
    for name, expected in checksums.items():
        path = root.joinpath(*PurePosixPath(name).parts)
        if any(parent.is_symlink() for parent in path.parents if parent != root.parent):
            raise ValueError("Symlink in source path")
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Non-regular source path: " + name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("Source hash differs: " + name)
        execution = stat.S_IMODE(info.st_mode) & 0o111
        if execution != (0o111 if modes[name] == "100755" else 0):
            raise ValueError("Git executable bits differ: " + name)
    print("Verified 224 file hashes and Git executable bits; exact source set:", before)


def main():
    if len(sys.argv) != 5 or sys.argv[4] not in ("before", "after"):
        raise SystemExit("Usage: verify-source.py ROOT SHA256 MODES before|after")
    root, checksums_path, modes_path = map(Path, sys.argv[1:4])
    checksums, modes = read_manifests(checksums_path, modes_path)
    verify(root, checksums, modes, sys.argv[4] == "before")


if __name__ == "__main__":
    main()
