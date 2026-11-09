"""Prepare an explicitly non-release version only inside a disposable CI copy."""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import sys

if len(sys.argv) != 3 or sys.argv[1] not in ("--check-only", "--apply-ci"):
    raise SystemExit("Usage: prepare-test-version.py --check-only|--apply-ci MACOS_DIR")
mode = sys.argv[1]
mac = Path(sys.argv[2]).resolve(strict=True)
plist_path = mac / "Info.plist"
swift_path = mac / "Sources/AITaskMonitor/AppVersion.swift"
before = {
    plist_path: "e9f9d9b99ab1b7ff13552ad3e6f65b29847dfb72ee134c344a2e8939d139ffe2",
    swift_path: "9c3e5cb2ed15abc5fdcb96da6f220e648592a5da9a3b49e218b1af011d78c91c",
}
for path, checksum in before.items():
    if hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
        raise SystemExit("Unexpected candidate version input")
def replace_once(data, old, new):
    if data.count(old) != 1:
        raise SystemExit("Unexpected version anchor")
    return data.replace(old, new)
plist = plist_path.read_bytes()
plist = replace_once(plist, b'<key>CFBundleShortVersionString</key><string>0.3.7</string>',
                     b'<key>CFBundleShortVersionString</key><string>0.3.8</string>')
plist = replace_once(plist, b'<key>CFBundleVersion</key><string>10</string>',
                     b'<key>CFBundleVersion</key><string>11</string>')
plist = replace_once(plist, b'<key>AITaskMonitorReleaseVersion</key><string>0.3.7-alpha</string>',
                     b'<key>AITaskMonitorReleaseVersion</key><string>0.3.8-ci.1</string>')
swift = replace_once(swift_path.read_bytes(), b'static let sourceVersion = "0.3.7-alpha"',
                     b'static let sourceVersion = "0.3.8-ci.1"')
parsed = plistlib.loads(plist)
if (parsed.get("AITaskMonitorReleaseVersion") != "0.3.8-ci.1" or
    parsed.get("CFBundleShortVersionString") != "0.3.8" or
    parsed.get("CFBundleVersion") != "11"):
    raise SystemExit("Test version mismatch")
for name, data in (("macos/Info.plist", plist), ("macos/Sources/AITaskMonitor/AppVersion.swift", swift)):
    print(hashlib.sha256(data).hexdigest() + "  " + name)
if mode == "--apply-ci":
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
        os.environ.get("RUNNER_OS") != "macOS"):
        raise SystemExit("Version changes require a disposable hosted macOS runner")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    expected = temp / "aitm-package-candidate-v1" / "macos"
    if mac != expected or not mac.is_relative_to(temp):
        raise SystemExit("Refusing to modify a non-synthetic source tree")
    plist_path.write_bytes(plist)
    swift_path.write_bytes(swift)
    print("Applied test-only version 0.3.8-ci.1 in isolated CI copy")
else:
    print("Read-only check; no files modified")
