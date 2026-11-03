import XCTest
@testable import AITaskMonitor

final class ReleaseUpdatesTests: XCTestCase {
    func testReleaseVersionMatchesBundleAndDoesNotOfferItself() throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistData = try Data(contentsOf: packageRoot.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let version = try XCTUnwrap(plist["AITaskMonitorReleaseVersion"] as? String)
        XCTAssertEqual(version, AppVersion.sourceVersion)
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, version.components(separatedBy: "-").first)
        let data = """
        [{"tag_name":"v\(version)","draft":false,"assets":[{"name":"app.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v\(version)/app.dmg"}]}]
        """.data(using: .utf8)!
        XCTAssertNil(ReleaseSelector.select(data: data, currentVersion: version))
    }
    @MainActor func testUpdateIsDeferredInCompactModeAndDismissedForSession() {
        let store = TaskStore.preview()
        store.isCompact = true
        store.setPreviewUpdate()
        XCTAssertNil(store.visibleUpdate)
        store.isCompact = false
        XCTAssertEqual(store.visibleUpdate?.version, "0.4.0-alpha")
        store.dismissUpdate()
        XCTAssertNil(store.visibleUpdate)
        store.isCompact = true
        store.isCompact = false
        XCTAssertNil(store.visibleUpdate)
    }
    func testSemanticOrderingAndRejections() throws {
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("v0.3.0-alpha.2")), try XCTUnwrap(ReleaseVersion("0.3.0-alpha.10")))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.3.0-alpha")), try XCTUnwrap(ReleaseVersion("0.3.0")))
        XCTAssertNil(ReleaseVersion("0.3.0-alpha.01"))
        XCTAssertNil(ReleaseVersion("1.0"))
    }

    func testPlatformDraftAndTrustedUrl() throws {
        let json = """
        [{"tag_name":"v0.4.0-alpha","draft":false,"assets":[{"name":"app.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.4.0-alpha/app.dmg"}]},
         {"tag_name":"v0.3.0-alpha","draft":false,"assets":[{"name":"app.exe","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.3.0-alpha/app.exe"}]},
         {"tag_name":"v0.9.0","draft":true,"assets":[{"name":"app.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.9.0/app.dmg"}]},
         {"tag_name":"v0.8.0","draft":false,"assets":[{"name":"app.dmg","browser_download_url":"https://evil.example/app.dmg"}]}]
        """.data(using: .utf8)!
        XCTAssertEqual(ReleaseSelector.select(data: json, currentVersion: "0.2.0-alpha")?.version, "0.4.0-alpha")
        XCTAssertEqual(ReleaseSelector.select(data: json, currentVersion: "0.2.0-alpha", platform: "windows")?.version, "0.3.0-alpha")
        XCTAssertNil(ReleaseSelector.select(data: json, currentVersion: "0.4.0-alpha"))
        XCTAssertNil(ReleaseSelector.select(data: Data(repeating: 0, count: ReleaseSelector.maximumBytes + 1), currentVersion: "0.1.0"))
        XCTAssertNil(ReleaseSelector.trustedURL("https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v1.0.0/app.dmg?x=1", tag: "v1.0.0", asset: "app.dmg", platform: "macos"))
    }
}
