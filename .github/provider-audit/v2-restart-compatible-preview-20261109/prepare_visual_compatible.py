"""Add only test-only preview controls in the disposable CI checkout."""
from pathlib import Path
import sys

if len(sys.argv) != 3 or sys.argv[2] not in ("baseline", "candidate"):
    raise SystemExit("Expected macOS root and baseline/candidate mode")
root, mode = Path(sys.argv[1]), sys.argv[2]
settings = root / "Sources/AITaskMonitor/SettingsView.swift"
renderer = root / "Sources/AITaskMonitor/SnapshotRenderer.swift"

def replace_once(text: str, old: str, new: str, label: str) -> str:
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected visual fixture shape: {label}")
    return text.replace(old, new)

source = settings.read_text(encoding="utf-8")
source = replace_once(source, '                        if !store.openCodeMessage.isEmpty {',
    '                        .id("settings-opencode")\n                        if !store.openCodeMessage.isEmpty {', "OpenCode ID")
source = replace_once(source, '                        if !store.deepSeekMessage.isEmpty {',
    '                        .id("settings-deepseek")\n                        if !store.deepSeekMessage.isEmpty {', "DeepSeek ID")
source = replace_once(source,
    '                         if settingsPreviewEnd { scrollProxy.scrollTo("feedback-end", anchor: .bottom) }',
    '                         if let target = ProcessInfo.processInfo.environment["AITM_RESTART_VISUAL_TARGET"], ["opencode", "deepseek"].contains(target) { scrollProxy.scrollTo("settings-" + target, anchor: .top) }\n                         else if settingsPreviewEnd { scrollProxy.scrollTo("feedback-end", anchor: .bottom) }', "scroll target")
if mode == "candidate":
    for provider in ("openCode", "deepSeek"):
        source = replace_once(source, f'.disabled(!store.{provider}RestartAvailable)',
            f'.disabled(!(store.{provider}RestartAvailable || ProcessInfo.processInfo.environment["AITM_RESTART_FORCE_ENABLED"] == "1"))', provider + " forced visual state")
settings.write_bytes(source.encode("utf-8"))

source = renderer.read_text(encoding="utf-8")
marker = '            try render(name: "expanded-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory)'
addition = '''            if ProcessInfo.processInfo.environment["AITM_RESTART_VISUAL_ONLY"] == "1" {
                for language in [AppLanguage.ru, .en] {
                    AppLanguage.previewOverride = language
                    for mode in [AppearanceMode.dark, .light] {
                        try render(name: "restart-\\(language.rawValue)-\\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true)
                    }
                }
                return 0
            }
'''
source = replace_once(source, marker, addition + marker, "preview-only branch")
source = replace_once(source,
    '        if settingsSources { store.setPreviewDeepSeekProfiles(desktop: desktopProfile) }',
    '        if settingsSources {\n            store.setPreviewDeepSeekProfiles(desktop: desktopProfile)\n            if ProcessInfo.processInfo.environment["AITM_RESTART_PROFILE"] == "disconnected" { store.selectedDeepSeekProfile = "Profile One" }\n        }', "profile selection")
renderer.write_bytes(source.encode("utf-8"))
print("Prepared synthetic visual-only state controls:", mode)
