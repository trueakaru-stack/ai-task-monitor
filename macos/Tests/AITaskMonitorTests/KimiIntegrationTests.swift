import Foundation
import XCTest
@testable import AITaskMonitor

final class KimiIntegrationTests: XCTestCase {
    func testReadOnlyConnectionDetectionAndBoundedBridge() throws {
        guard let node = ProcessInfo.processInfo.environment["AITM_NODE"], !node.isEmpty else { throw XCTSkip("Isolated Node fixture is unavailable") }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-kimi-swift-" + UUID().uuidString, isDirectory: true)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let integrations = resources.appendingPathComponent("integrations", isDirectory: true)
        let package = root.appendingPathComponent("node_modules/@moonshot-ai/kimi-code", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: integrations, withIntermediateDirectories: true)
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations", isDirectory: true)
        for name in ["kimi-integration.mjs", "kimi-setup.mjs", "kimi-plugin"] {
            try manager.copyItem(at: source.appendingPathComponent(name), to: integrations.appendingPathComponent(name))
        }
        let anchor = package.appendingPathComponent("package.json")
        try Data(#"{"name":"@moonshot-ai/kimi-code","version":"2.5.0"}"#.utf8).write(to: anchor)
        let assets = try XCTUnwrap(KimiIntegration.pluginDirectory(resources: resources))
        let context = KimiIntegration.Context(node: URL(fileURLWithPath: node), home: home, assets: assets, installAnchor: anchor,
                                              environment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "TMPDIR": root.path])
        XCTAssertEqual(try KimiIntegration.inspect(context).state, "disconnected")
        let plugins = home.appendingPathComponent("plugins", isDirectory: true)
        let managed = plugins.appendingPathComponent("managed/ai-task-monitor", isDirectory: true)
        try manager.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: assets, to: managed)
        let registry = plugins.appendingPathComponent("installed.json")
        func save(enabled: Bool) throws -> Data {
            let value: [String: Any] = ["version": 1, "plugins": [
                ["id": "foreign", "root": "SECRET_PATH", "enabled": true],
                ["id": "ai-task-monitor", "root": managed.path, "enabled": enabled]
            ]]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            try data.write(to: registry)
            return data
        }
        let original = try save(enabled: true)
        let connected = try KimiIntegration.inspect(context)
        XCTAssertEqual(connected.state, "connected")
        XCTAssertTrue(DeepSeekIntegration.validScope(connected.scope))
        XCTAssertEqual(try Data(contentsOf: registry), original)
        let foreign = managed.appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: foreign)
        XCTAssertThrowsError(try KimiIntegration.inspect(context)) { error in
            XCTAssertEqual((error as? KimiIntegrationError)?.code, "modified-bundle")
        }
        XCTAssertEqual(try String(contentsOf: foreign, encoding: .utf8), "keep")
        try manager.removeItem(at: foreign)
        _ = try save(enabled: false)
        XCTAssertEqual(try KimiIntegration.inspect(context).state, "disabled")
        try Data("setTimeout(() => {}, 5000)".utf8).write(to: context.bridge)
        let start = Date()
        XCTAssertThrowsError(try KimiIntegration.inspect(context, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try Data("process.stdout.write('x'.repeat(200000))".utf8).write(to: context.bridge)
        XCTAssertThrowsError(try KimiIntegration.inspect(context)) { error in
            XCTAssertEqual((error as? KimiIntegrationError)?.code, "invalid-response")
        }
    }
}
