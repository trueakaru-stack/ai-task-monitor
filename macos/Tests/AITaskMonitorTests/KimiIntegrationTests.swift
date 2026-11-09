import Foundation
import XCTest
@testable import AITaskMonitor

final class KimiIntegrationTests: XCTestCase {
    func testNvmDiscoveryWithoutCurrentSymlinkUsesOnlyUnambiguousInstallation() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-kimi-nvm-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let integrations = resources.appendingPathComponent("integrations", isDirectory: true)
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createDirectory(at: integrations.appendingPathComponent("kimi-plugin"), withIntermediateDirectories: true)
        try Data().write(to: integrations.appendingPathComponent("kimi-setup.mjs"))

        func makeInstallation(root: URL, version: String) throws -> (bin: URL, anchor: URL) {
            let versionRoot = root.appendingPathComponent("versions/node/\(version)", isDirectory: true)
            let bin = versionRoot.appendingPathComponent("bin", isDirectory: true)
            let package = versionRoot.appendingPathComponent("lib/node_modules/@moonshot-ai/kimi-code", isDirectory: true)
            let dist = package.appendingPathComponent("dist", isDirectory: true)
            try manager.createDirectory(at: bin, withIntermediateDirectories: true)
            try manager.createDirectory(at: dist, withIntermediateDirectories: true)
            let anchor = package.appendingPathComponent("package.json")
            try Data(#"{"name":"@moonshot-ai/kimi-code","version":"2.5.0"}"#.utf8).write(to: anchor)
            let main = dist.appendingPathComponent("main.mjs"), node = bin.appendingPathComponent("node")
            try Data("#!/usr/bin/env node\n".utf8).write(to: main)
            try Data("fixture".utf8).write(to: node)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
            try manager.createSymbolicLink(at: bin.appendingPathComponent("kimi"), withDestinationURL: main)
            return (bin, anchor)
        }

        let nvm = home.appendingPathComponent(".nvm", isDirectory: true)
        let first = try makeInstallation(root: nvm, version: "v22.19.0")
        let discovered = try XCTUnwrap(KimiIntegration.discover(home: home, environment: ["PATH": ""],
                                                                 resources: resources, systemPaths: []))
        XCTAssertEqual(discovered.node.path, first.bin.appendingPathComponent("node").path)
        XCTAssertEqual(discovered.installAnchor.path, first.anchor.path)
        XCTAssertFalse(manager.fileExists(atPath: nvm.appendingPathComponent("current").path))

        let second = try makeInstallation(root: nvm, version: "v24.0.0")
        XCTAssertNil(KimiIntegration.discover(home: home, environment: ["PATH": ""], resources: resources, systemPaths: []))
        let fromPath = try XCTUnwrap(KimiIntegration.discover(home: home, environment: ["PATH": second.bin.path],
                                                              resources: resources, systemPaths: []))
        XCTAssertEqual(fromPath.installAnchor.path, second.anchor.path)

        let custom = root.appendingPathComponent("custom-nvm", isDirectory: true)
        let customInstall = try makeInstallation(root: custom, version: "v22.20.0")
        let fromCustom = try XCTUnwrap(KimiIntegration.discover(home: home,
            environment: ["PATH": "", "NVM_DIR": custom.path], resources: resources, systemPaths: []))
        XCTAssertEqual(fromCustom.installAnchor.path, customInstall.anchor.path)
        XCTAssertNil(KimiIntegration.discover(home: home, environment: ["PATH": "", "NVM_DIR": "relative"],
                                              resources: resources, systemPaths: []))
    }

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
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let dist = package.appendingPathComponent("dist", isDirectory: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createDirectory(at: dist, withIntermediateDirectories: true)
        let executable = dist.appendingPathComponent("main.mjs")
        try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try manager.createSymbolicLink(at: bin.appendingPathComponent("kimi"), withDestinationURL: executable)
        try manager.createSymbolicLink(at: bin.appendingPathComponent("node"), withDestinationURL: URL(fileURLWithPath: node))
        let linkedHome = home.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        let discovered = try XCTUnwrap(KimiIntegration.discover(home: root,
            environment: ["PATH": bin.path, "KIMI_CODE_HOME": linkedHome], resources: resources))
        XCTAssertEqual(discovered.home.path, home.path)
        XCTAssertEqual(discovered.installAnchor.path, anchor.path)
        XCTAssertEqual(discovered.assets.path, assets.path)
        XCTAssertNil(KimiIntegration.discover(home: root, environment: ["PATH": bin.path, "KIMI_CODE_HOME": "relative"], resources: resources))
        let context = KimiIntegration.Context(node: URL(fileURLWithPath: node), home: home, assets: assets, installAnchor: anchor,
                                              environment: ["PATH": "/usr/bin:/bin", "TMPDIR": root.path])
        XCTAssertTrue(assets.path.hasPrefix("/private/tmp/"), "The plugin path must resolve macOS's /tmp link")
        XCTAssertEqual(try KimiIntegration.inspect(context).state, "disconnected")
        let nvmBin = root.appendingPathComponent(".nvm/versions/node/v22.19.0/bin", isDirectory: true)
        try manager.createDirectory(at: nvmBin, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: nvmBin.appendingPathComponent("node"), withDestinationURL: URL(fileURLWithPath: node))
        try manager.createSymbolicLink(at: nvmBin.appendingPathComponent("kimi"), withDestinationURL: executable)
        var nvmContext = try XCTUnwrap(KimiIntegration.discover(home: root,
            environment: ["PATH": "", "KIMI_CODE_HOME": linkedHome], resources: resources, systemPaths: []))
        nvmContext.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path]
        XCTAssertEqual(try KimiIntegration.inspect(nvmContext).state, "disconnected")
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
        XCTAssertEqual(try KimiIntegration.inspect(nvmContext), connected)
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
