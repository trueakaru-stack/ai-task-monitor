import Foundation
import XCTest
@testable import AITaskMonitor

/// Synthetic timings only: payloads contain no user data and no requests are made.
@MainActor
final class UpdaterParseTimingTests: XCTestCase {
    private func milliseconds(_ value: Duration) -> Double {
        let parts = value.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }

    private func repeated(_ record: String, maximumBytes: Int, prefix: String, suffix: String) -> Data {
        let overhead = prefix.utf8.count + suffix.utf8.count
        let count = max(1, (maximumBytes - overhead + 1) / (record.utf8.count + 1))
        return Data((prefix + Array(repeating: record, count: count).joined(separator: ",") + suffix).utf8)
    }

    func testSyntheticMainActorParseAndQueueDelay() throws {
        let release = #"{"tag_name":"v9.0.0","draft":false,"assets":[]}"#
        let asset = #"{"name":"app.dmg","browser_download_url":"not-a-url"}"#
        let representativeRelease = #"{"tag_name":"v9.0.0","draft":false,"assets":[{"name":"app.dmg","browser_download_url":"not-a-url"}]}"#
        let representative = Data(("[" + Array(repeating: representativeRelease, count: 100).joined(separator: ",") + "]").utf8)
        let profiles: [(String, Data)] = [
            ("representative-100", representative),
            ("release-dense-1m", repeated(release, maximumBytes: ReleaseSelector.maximumBytes, prefix: "[", suffix: "]")),
            ("asset-dense-1m", repeated(asset, maximumBytes: ReleaseSelector.maximumBytes,
                                        prefix: #"[{"tag_name":"v9.0.0","draft":false,"assets":["#,
                                        suffix: "]}]"))
        ]
        let store = TaskStore.preview()
        let clock = ContinuousClock()
        for (name, data) in profiles {
            XCTAssertLessThanOrEqual(data.count, ReleaseSelector.maximumBytes)
            XCTAssertGreaterThan(data.count, name == "representative-100" ? 8_000 : 1_000_000)
            XCTAssertTrue(store.acceptReleaseData(data)) // Warm the decoder outside measured samples.
            var parseTimes: [Double] = []
            var queueLateness: [Double] = []
            for _ in 0..<5 {
                let timer = expectation(description: "main queue timer")
                let scheduled = clock.now
                var observed = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(5)) {
                    observed = self.milliseconds(scheduled.duration(to: clock.now))
                    timer.fulfill()
                }
                let started = clock.now
                let valid = store.acceptReleaseData(data)
                let elapsed = milliseconds(started.duration(to: clock.now))
                XCTAssertTrue(valid)
                wait(for: [timer], timeout: 10)
                parseTimes.append(elapsed)
                queueLateness.append(max(0, observed - 5))
            }
            parseTimes.sort()
            print(String(format: "UPDATER_PARSE_BENCH name=%@ bytes=%d samples=%d median_ms=%.3f max_ms=%.3f queue_late_max_ms=%.3f",
                         name, data.count, parseTimes.count, parseTimes[parseTimes.count / 2],
                         parseTimes.last!, queueLateness.max()!))
        }
    }
}
