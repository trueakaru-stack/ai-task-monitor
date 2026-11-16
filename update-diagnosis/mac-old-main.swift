import Foundation

let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    print("PASS: \(label)")
}
let update = ReleaseSelector.select(data: data, currentVersion: "0.3.7-alpha", platform: "macos")
check(update?.version == "0.3.8-alpha", "macOS 0.3.7 selects the 0.3.8 release")
check(update?.url.absoluteString == "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.8-alpha/AITaskMonitor-macOS-0.3.8-alpha.dmg", "macOS selector returns the platform DMG")
check(ReleaseSelector.select(data: data, currentVersion: "0.3.8-alpha", platform: "macos") == nil, "macOS 0.3.8 does not offer itself or the Windows release")
let windows = ReleaseSelector.select(data: data, currentVersion: "0.2.6-alpha", platform: "windows")
check(windows?.version == "0.2.7-alpha", "mixed metadata also selects the Windows package")

print("Legacy selector executed against a synthetic snapshot of public release fields.")
