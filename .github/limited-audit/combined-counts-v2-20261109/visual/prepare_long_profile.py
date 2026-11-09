"""Prepare an isolated long-profile preview; never touches real profiles."""
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = root / "Sources/AITaskMonitor/TaskStore.swift"
text = source.read_text(encoding="utf-8")

def once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit("Unexpected long-profile preview fixture")
    text = text.replace(old, new)

once('    func setPreviewDeepSeekProfiles(desktop: Bool = false) {\n        deepSeekInstallationAvailable = true',
     '    func setPreviewDeepSeekProfiles(desktop: Bool = false) {\n        let previewConnectedName = ProcessInfo.processInfo.environment["AITM_RESTART_PROFILE"] == "long" ? "Long profile name 123456789012345678901234567890123456" : "Profile Two"\n        deepSeekInstallationAvailable = true')
once('DeepSeekProfile(name: "Profile Two", state: "connected"', 'DeepSeekProfile(name: previewConnectedName, state: "connected"')
once('selectedDeepSeekProfile = desktop ? "desktop" : "Profile Two"', 'selectedDeepSeekProfile = desktop ? "desktop" : previewConnectedName')
source.write_bytes(text.encode("utf-8"))
print("Prepared test-only long profile")
