import CryptoKit
import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalOpenCodeLegacyReconnectTests: XCTestCase {
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined() }

    func testLegacyOwnedBundleCanBeReconnectedWithoutChangingNeighbour() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("aitm-opencode-v2-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: home) }
        let source = home.appendingPathComponent(".config/opencode", isDirectory: true)
        let plugins = source.appendingPathComponent("plugins", isDirectory: true)
        let folder = source.appendingPathComponent("ai-task-monitor-data", isDirectory: true)
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs"]
        var hashes: [String: String] = [:]
        for name in names {
            let data = Data(("synthetic " + name).utf8); hashes[name] = digest(data)
            try data.write(to: folder.appendingPathComponent(name))
        }
        let shim = Data("synthetic legacy shim".utf8)
        try shim.write(to: plugins.appendingPathComponent("ai-task-monitor.js"))
        let marker: [String: Any] = ["owner": "AI Task Monitor OpenCode v1", "files": hashes, "shim": digest(shim)]
        try JSONSerialization.data(withJSONObject: marker).write(to: folder.appendingPathComponent("manifest.json"))
        let other = plugins.appendingPathComponent("another-plugin.js")
        try Data("KEEP".utf8).write(to: other)
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .connected)
        try OpenCodeIntegration.setConnected(false, home: home)
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .disconnected)
        let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations", isDirectory: true)
        try OpenCodeIntegration.setConnected(true, home: home, assets: assets, fixtureVersion: "2.2.5")
        XCTAssertEqual(try OpenCodeIntegration.state(home: home), .connected)
        XCTAssertTrue(manager.fileExists(atPath: folder.appendingPathComponent("provider-v2-sender.mjs").path))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "KEEP")
    }
}
