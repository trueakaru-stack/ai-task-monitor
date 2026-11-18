import XCTest
@testable import AITaskMonitor

final class ReleaseUpdate0310Tests: XCTestCase {
    func testPublished039Offers0310And0310DoesNotOfferItself() throws {
        let data = """
        [{"tag_name":"v0.3.10","draft":false,"prerelease":false,"assets":[{"name":"AITaskMonitor-macOS-0.3.10.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.10/AITaskMonitor-macOS-0.3.10.dmg"}]}]
        """.data(using: .utf8)!
        let update = try XCTUnwrap(ReleaseSelector.select(data: data, currentVersion: "0.3.9", platform: "macos"))
        XCTAssertEqual(update.version, "0.3.10")
        XCTAssertEqual(update.url.absoluteString, "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.10/AITaskMonitor-macOS-0.3.10.dmg")
        XCTAssertNil(ReleaseSelector.select(data: data, currentVersion: "0.3.10", platform: "macos"))
    }
}
