import XCTest
@testable import AITaskMonitor

final class ReleaseUpdate039Tests: XCTestCase {
    func testAlphaOffersStable039AndStableDoesNotOfferItself() throws {
        let data = """
        [{"tag_name":"v0.3.9","draft":false,"prerelease":false,"assets":[{"name":"AITaskMonitor-macOS-0.3.9.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.9/AITaskMonitor-macOS-0.3.9.dmg"}]}]
        """.data(using: .utf8)!
        let update = try XCTUnwrap(ReleaseSelector.select(data: data, currentVersion: "0.3.9-alpha", platform: "macos"))
        XCTAssertEqual(update.version, "0.3.9")
        XCTAssertEqual(update.url.absoluteString, "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.9/AITaskMonitor-macOS-0.3.9.dmg")
        XCTAssertNil(ReleaseSelector.select(data: data, currentVersion: "0.3.9", platform: "macos"))
    }
}
