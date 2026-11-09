"""Check application resources against a pinned, explicit manifest."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import sys

if len(sys.argv) != 4:
    raise SystemExit("Usage: verify-app-bundle.py APP_DIR MACOS_SOURCE RESOURCE_MANIFEST")
app, source, manifest = map(Path, sys.argv[1:])
def executable_allowed(mode, access):
    return stat.S_IMODE(mode) & 0o111 == 0o111 and access
expected_manifest = "43ecc4a14501423eaf91946bdef279474b1759fe9ac0c43ebaddb55be40d628f"
if hashlib.sha256(manifest.read_bytes()).hexdigest() != expected_manifest:
    raise SystemExit("Unexpected resource manifest")
expected = {}
for line in manifest.read_text(encoding="utf-8").splitlines():
    checksum, name = line.split("  ", 1)
    parts = PurePosixPath(name).parts
    if (len(parts) < 2 or parts[0] != "integrations" or ".." in parts or
        PurePosixPath(name).is_absolute() or name in expected):
        raise SystemExit("Invalid resource manifest path")
    expected[name] = checksum
if len(expected) != 27:
    raise SystemExit("Expected exactly 27 resources")
resources = app / "Contents/Resources"
integration_root = resources / "integrations"
if integration_root.is_symlink() or not integration_root.is_dir():
    raise SystemExit("Missing or linked integration directory")
for path in integration_root.rglob("*"):
    if path.is_symlink():
        raise SystemExit("Unexpected linked integration resource")
actual = {"integrations/" + path.relative_to(integration_root).as_posix()
          for path in integration_root.rglob("*") if path.is_file()}
if actual != set(expected):
    raise SystemExit("Integration file set differs from pinned manifest")
for name, checksum in sorted(expected.items()):
    packaged = resources / name
    original = source / name
    if hashlib.sha256(packaged.read_bytes()).hexdigest() != checksum:
        raise SystemExit("Incorrect packaged resource: " + name)
    if hashlib.sha256(original.read_bytes()).hexdigest() != checksum:
        raise SystemExit("Source resource differs from candidate: " + name)
plist_path = app / "Contents/Info.plist"
if plist_path.is_symlink() or plist_path.read_bytes() != (source / "Info.plist").read_bytes():
    raise SystemExit("Packaged Info.plist differs from test-version source")
plist = plistlib.loads(plist_path.read_bytes())
if (plist.get("AITaskMonitorReleaseVersion") != "0.3.8-ci.1" or
    plist.get("CFBundleShortVersionString") != "0.3.8" or
    plist.get("CFBundleVersion") != "11" or
    plist.get("CFBundleExecutable") != "AITaskMonitor"):
    raise SystemExit("Unexpected synthetic bundle version")
binary = app / "Contents/MacOS/AITaskMonitor"
icon = resources / "AppIcon.icns"
if binary.is_symlink() or not binary.is_file() or binary.stat().st_size == 0:
    raise SystemExit("Missing application executable")
binary_mode = binary.stat().st_mode
if not executable_allowed(binary_mode, os.access(binary, os.X_OK)):
    raise SystemExit("Application executable bits or execute access are missing")
if icon.is_symlink() or not icon.is_file() or icon.read_bytes()[:4] != b"icns":
    raise SystemExit("Missing or invalid application icon")
print(json.dumps({
    "integrationResourceCount": len(expected),
    "resourceManifestSha256": expected_manifest,
    "releaseVersion": plist["AITaskMonitorReleaseVersion"],
    "shortVersion": plist["CFBundleShortVersionString"],
    "buildNumber": plist["CFBundleVersion"],
    "binarySha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "binaryMode": oct(stat.S_IMODE(binary_mode)),
    "binaryExecutable": True,
    "iconSha256": hashlib.sha256(icon.read_bytes()).hexdigest()
}, sort_keys=True))
