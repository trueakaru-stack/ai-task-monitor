import Foundation
import XCTest
@testable import AITaskMonitor

final class OpenCodeIntegrationTests: XCTestCase {
    private var assets: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations", isDirectory: true)
    }

    func testOnlyKnownCompatibleStableVersionsAreAccepted() {
        for version in ["1.18.29", "v1.20.1", "2.0.0", "OpenCode 2.2.1"] {
            XCTAssertTrue(OpenCodeIntegration.supports(version: version), version)
        }
        for version in ["1.18.28", "3.0.0", "2.0.0-beta", "unknown", "1.18", ""] {
            XCTAssertFalse(OpenCodeIntegration.supports(version: version), version)
        }
    }

    func testInstallRemoveAndPreserveUnrelatedFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-opencode-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let plugins = home.appendingPathComponent(".config/opencode/plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let unrelated = plugins.appendingPathComponent("another-plugin.js")
        try Data("UNCHANGED".utf8).write(to: unrelated)
        XCTAssertThrowsError(try OpenCodeIntegration.setConnected(true, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("ai-task-monitor.js").path))
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .disconnected)
        XCTAssertThrowsError(try OpenCodeIntegration.setConnected(true, home: home, assets: assets, fixtureVersion: "1.18.28"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plugins.appendingPathComponent("ai-task-monitor.js").path))
        try OpenCodeIntegration.setConnected(true, home: home, assets: assets)
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .connected)
        try OpenCodeIntegration.setConnected(true, home: home, assets: assets)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "UNCHANGED")

        let module = home.appendingPathComponent(".config/opencode/ai-task-monitor-data/provider-events.mjs")
        let original = try Data(contentsOf: module)
        try Data("USER CHANGE".utf8).write(to: module)
        XCTAssertThrowsError(try OpenCodeIntegration.setConnected(false, home: home, assets: assets))
        XCTAssertTrue(FileManager.default.fileExists(atPath: module.path))
        try original.write(to: module)
        let extra = home.appendingPathComponent(".config/opencode/ai-task-monitor-data/user-file.txt")
        try Data("KEEP".utf8).write(to: extra)
        XCTAssertThrowsError(try OpenCodeIntegration.setConnected(false, home: home, assets: assets))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        try FileManager.default.removeItem(at: extra)
        try OpenCodeIntegration.setConnected(false, home: home, assets: assets)
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .disconnected)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "UNCHANGED")
    }

    func testSymlinkIsNotFollowed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-opencode-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let destination = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("KEEP".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".config"), withDestinationURL: destination)
        XCTAssertThrowsError(try OpenCodeIntegration.setConnected(true, home: home, assets: assets))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "KEEP")
    }
}
