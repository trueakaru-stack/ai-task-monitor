"""Enable a synthetic Hermes command preview in the disposable runner."""
from pathlib import Path
import sys
source = Path(sys.argv[1]) / "Sources/AITaskMonitor/SnapshotRenderer.swift"
lines = source.read_text(encoding="utf-8").splitlines(keepends=True)
count = 0
for index, line in enumerate(lines):
    if 'try render(name: "restart-' in line and 'settingsSources: true)' in line:
        lines[index] = line.replace('settingsSources: true)', 'settingsSources: true, hermesPreview: ProcessInfo.processInfo.environment["AITM_RESTART_PROFILE"] == "commands" ? .prepared : nil)')
        count += 1
if count != 2:
    raise SystemExit("Unexpected Hermes preview fixture")
source.write_bytes("".join(lines).encode("utf-8"))
print("Prepared synthetic Hermes command preview")
