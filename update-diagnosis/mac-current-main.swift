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

final class VirtualClock {
    var wall = Date(timeIntervalSince1970: 1_700_000_000)
    var monotonic: TimeInterval = 0
    func advance(_ value: TimeInterval) { wall.addTimeInterval(value); monotonic += value }
    var clock: ReleaseRetryClock { ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic }) }
}
let time = VirtualClock()
guard let defaults = UserDefaults(suiteName: "synthetic.ai-task-monitor." + UUID().uuidString) else { fatalError("Synthetic defaults unavailable") }
let schedule = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
check(schedule.beginIfDue(), "macOS 0.3.8 initially checks")
schedule.failed()
check(schedule.delay == 3600, "macOS 0.3.8 ordinary failure waits one hour")
time.advance(3599)
check(!schedule.isDue, "macOS 0.3.8 is not due at 59m59s")
time.advance(1)
check(schedule.beginIfDue(), "macOS 0.3.8 retries after one hour")
schedule.succeeded()
check(schedule.delay == 86400, "macOS 0.3.8 successful check waits 24 hours")
time.advance(86399)
check(!schedule.isDue, "macOS 0.3.8 successful check is not due at 23h59m59s")
time.advance(1)
check(schedule.beginIfDue(), "macOS 0.3.8 successful check is due after 24 hours")
schedule.failed(ReleaseHTTPResponse(status: 403))
check(schedule.delay == 3600, "macOS 0.3.8 first 403 waits one hour without extra server hints")
time.advance(3600)
check(schedule.beginIfDue(), "macOS 0.3.8 can retry the first 403 after one hour")
schedule.failed(ReleaseHTTPResponse(status: 403))
check(schedule.delay == 7200, "macOS 0.3.8 second 403 waits two hours without extra server hints")
print("Synthetic defaults and virtual time only; no installed application or live request was tested.")
