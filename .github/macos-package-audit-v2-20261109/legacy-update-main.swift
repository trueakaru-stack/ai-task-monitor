import Foundation

// Synthetic metadata only. No URLSession or network request is started here.
let current = "0.3.7-alpha"
let tag = "v0.3.8-ci.1"
let name = "AITaskMonitor-macOS-0.3.8-ci.1.dmg"
let expectedURL = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/\(tag)/\(name)"

func data(_ items: [[String: Any]]) -> Data {
    do { return try JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]) }
    catch { fatalError("Could not encode synthetic release metadata") }
}
func item(_ tag: String, _ draft: Bool, _ name: String, _ url: String) -> [String: Any] {
    ["tag_name": tag, "draft": draft, "assets": [["name": name, "browser_download_url": url]]]
}
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAILED: " + label + "\n").utf8))
        exit(1)
    }
    print("PASS: " + label)
}

let candidate = item(tag, false, name, expectedURL)
let selected = ReleaseSelector.select(data: data([candidate]), currentVersion: current, platform: "macos")
check(selected?.version == "0.3.8-ci.1", "newer synthetic DMG is offered")
check(selected?.url.absoluteString == expectedURL, "download URL matches the candidate asset")
check(ReleaseSelector.select(data: data([candidate]), currentVersion: "0.3.8-ci.1", platform: "macos") == nil,
      "the same version is not offered")
check(ReleaseSelector.select(data: data([item(tag, true, name, expectedURL)]), currentVersion: current) == nil,
      "draft releases are ignored")
check(ReleaseSelector.select(data: data([item(tag, false, name, "https://invalid.example/file.dmg")]), currentVersion: current) == nil,
      "untrusted download host is rejected")
let windowsName = "AITaskMonitorSetup-0.3.8-ci.1.exe"
let windowsURL = "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/\(tag)/\(windowsName)"
check(ReleaseSelector.select(data: data([item(tag, false, windowsName, windowsURL)]), currentVersion: current, platform: "macos") == nil,
      "Windows-only release is not offered on macOS")
print("Legacy selector synthetic checks passed; actual installed updater and notification are not tested")
