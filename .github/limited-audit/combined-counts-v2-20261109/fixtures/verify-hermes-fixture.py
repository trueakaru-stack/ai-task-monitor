"""Verify the pinned, repacked Hermes fixture before any extraction."""
import hashlib
from pathlib import Path, PurePosixPath
import sys
import tarfile

archive_path, manifest_path, license_path = map(Path, sys.argv[1:])
prefix = "hermes-agent-b200f5bc60e31588ba2cb60e288029c4a54ba5fa/"
expected_archive = "45d1bede19566e032696d41570c9c5b0669fa32bc9e1e6c99cba7f7b8f0b1bf6"
if hashlib.sha256(archive_path.read_bytes()).hexdigest() != expected_archive:
    raise SystemExit("Hermes archive digest mismatch")
expected = {}
for line in manifest_path.read_text(encoding="ascii").splitlines():
    checksum, name = line.split("  ", 1)
    parts = PurePosixPath(name).parts
    if (not name or PurePosixPath(name).is_absolute() or
        any(part in ("", ".", "..", ".git") for part in parts) or
        len(checksum) != 64 or any(c not in "0123456789abcdef" for c in checksum) or
        name in expected or name == "LICENSE"):
        raise SystemExit("Invalid Hermes source manifest")
    expected[name] = checksum
if len(expected) != 70:
    raise SystemExit("Expected exactly 70 Hermes source files")
expected_names = {prefix + name for name in expected} | {prefix + "LICENSE"}
with tarfile.open(archive_path, "r:gz") as archive:
    members = archive.getmembers()
    if len(members) != len(expected_names) or {m.name for m in members} != expected_names:
        raise SystemExit("Hermes archive contains extra, missing, or duplicate entries")
    for member in members:
        if not member.isfile() or member.size > 2_000_000:
            raise SystemExit("Unsafe Hermes archive member")
        stream = archive.extractfile(member)
        if stream is None:
            raise SystemExit("Unreadable Hermes archive member")
        data = stream.read()
        name = member.name[len(prefix):]
        if name == "LICENSE":
            if data != license_path.read_bytes():
                raise SystemExit("Hermes MIT license mismatch")
        elif hashlib.sha256(data).hexdigest() != expected[name]:
            raise SystemExit("Hermes source digest mismatch: " + name)
print("Verified 70 pinned Hermes source files and original MIT license")
