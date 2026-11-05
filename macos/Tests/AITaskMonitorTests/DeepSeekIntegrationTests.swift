import Foundation
import XCTest
@testable import AITaskMonitor

final class DeepSeekIntegrationTests: XCTestCase {
    func testScopeValidation() {
        XCTAssertTrue(DeepSeekIntegration.validScope(String(repeating: "a", count: 32)))
        XCTAssertFalse(DeepSeekIntegration.validScope(String(repeating: "A", count: 32)))
        XCTAssertFalse(DeepSeekIntegration.validScope("a"))
    }

    func testDiscoversOnlyAnExistingLocalPackageAndAbsoluteHome() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("aitm-discovery-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let dsh = root.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib", isDirectory: true)
        let pnpm = root.appendingPathComponent("node_modules/pnpm/bin", isDirectory: true)
        for directory in [bin, assets, dsh, pnpm] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        for file in [bin.appendingPathComponent("node"), dsh.appendingPathComponent("bin.js"), pnpm.appendingPathComponent("pnpm.mjs")] {
            try Data("fixture".utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try Data("{}".utf8).write(to: dsh.deletingLastPathComponent().appendingPathComponent("package.json"))
        try Data("".utf8).write(to: assets.appendingPathComponent("deepseek-setup.mjs"))
        try manager.createSymbolicLink(at: bin.appendingPathComponent("dsh"), withDestinationURL: dsh.appendingPathComponent("bin.js"))
        try manager.createSymbolicLink(at: bin.appendingPathComponent("pnpm"), withDestinationURL: pnpm.appendingPathComponent("pnpm.mjs"))
        let customHome = root.appendingPathComponent("chosen-home", isDirectory: true).path
        let context = try XCTUnwrap(DeepSeekIntegration.discover(home: root, environment: ["PATH": bin.path, "DSH_HOME": customHome], assets: assets))
        XCTAssertEqual(context.home.standardizedFileURL.path, URL(fileURLWithPath: customHome, isDirectory: true).standardizedFileURL.path)
        XCTAssertEqual(context.installAnchor.lastPathComponent, "package.json")
        XCTAssertEqual(context.pnpmScript.lastPathComponent, "pnpm.mjs")
        XCTAssertNil(DeepSeekIntegration.discover(home: root, environment: ["PATH": bin.path, "DSH_HOME": "relative"], assets: assets))
    }

    func testIsolatedUpstreamConnectionBridge() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let anchorPath = environment["AITM_DSH_ANCHOR"], let pnpmPath = environment["AITM_PNPM_SCRIPT"],
              let nodePath = environment["AITM_NODE"] else { throw XCTSkip("Isolated upstream DeepSeek fixture is unavailable.") }
        let manager = FileManager.default
        let temp = URL(fileURLWithPath: environment["RUNNER_TEMP"] ?? manager.temporaryDirectory.path,
                       isDirectory: true).resolvingSymlinksInPath()
        let root = temp.appendingPathComponent("aitm-swift-dsh-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign", isDirectory: true)
        let tools = root.appendingPathComponent("bin", isDirectory: true)
        let dshHome = root.appendingPathComponent("dsh-home", isDirectory: true)
        try manager.createDirectory(at: foreign, withIntermediateDirectories: false)
        try manager.createDirectory(at: tools, withIntermediateDirectories: false)
        try manager.createSymbolicLink(at: tools.appendingPathComponent("pnpm"), withDestinationURL: URL(fileURLWithPath: pnpmPath))
        try Data("".utf8).write(to: root.appendingPathComponent("npmrc"))
        let manifest = #"{"name":"aitm-foreign-fixture","version":"1.0.0","type":"module","main":"index.js","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}"#
        try Data(manifest.utf8).write(to: foreign.appendingPathComponent("package.json"))
        try Data("export function apply() {}".utf8).write(to: foreign.appendingPathComponent("index.js"))
        try Data("- insert:\n    - id: foreign-fixture\n      name: aitm-foreign-fixture\n".utf8).write(to: foreign.appendingPathComponent("cordis.patch.yml"))
        let fixtureEnvironment = [
            "HOME": root.path, "USERPROFILE": root.path, "DSH_HOME": dshHome.path,
            "PATH": tools.path + ":" + URL(fileURLWithPath: nodePath).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "PNPM_CONFIG_STORE_DIR": root.appendingPathComponent("store").path,
            "PNPM_CONFIG_OFFLINE": "true", "PNPM_CONFIG_IGNORE_SCRIPTS": "true", "PNPM_CONFIG_IGNORE_PNPMFILE": "true",
            "NPM_CONFIG_USERCONFIG": root.appendingPathComponent("npmrc").path,
        ]
        let anchor = URL(fileURLWithPath: anchorPath).resolvingSymlinksInPath().standardizedFileURL
        let node = URL(fileURLWithPath: nodePath)
        let initializer = Process()
        initializer.executableURL = node
        initializer.arguments = [anchor.deletingLastPathComponent().appendingPathComponent("lib/bin.js").path,
                                 "plugin", "--profile", "тестовый-профиль", "add", "--offline", "--ignore-scripts", foreign.path]
        initializer.environment = fixtureEnvironment
        initializer.standardOutput = FileHandle.nullDevice
        initializer.standardError = FileHandle.nullDevice
        try initializer.run()
        initializer.waitUntilExit()
        XCTAssertEqual(initializer.terminationStatus, 0)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let context = DeepSeekIntegration.Context(node: node, home: dshHome, assets: project.appendingPathComponent("integrations"),
            installAnchor: anchor, pnpmScript: URL(fileURLWithPath: pnpmPath).resolvingSymlinksInPath().standardizedFileURL, environment: fixtureEnvironment)
        let first = try DeepSeekIntegration.profiles(context)
        XCTAssertEqual(first.map(\.name), ["тестовый-профиль"])
        XCTAssertEqual(first.first?.state, "disconnected")
        try DeepSeekIntegration.setConnected(true, profile: "тестовый-профиль", context: context)
        let connected = try XCTUnwrap(DeepSeekIntegration.profiles(context).first)
        XCTAssertEqual(connected.state, "connected", "Fixture profile error: \(connected.error ?? "none")")
        XCTAssertTrue(DeepSeekIntegration.validScope(connected.scope))
        try DeepSeekIntegration.setConnected(false, profile: "тестовый-профиль", context: context)
        XCTAssertEqual(try DeepSeekIntegration.profiles(context).first?.state, "disconnected")
        let profileManifest = try Data(contentsOf: dshHome.appendingPathComponent("profiles/тестовый-профиль/package.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: profileManifest) as? [String: Any])
        let dependencies = try XCTUnwrap(json["dependencies"] as? [String: String])
        XCTAssertNotNil(dependencies["aitm-foreign-fixture"])
        XCTAssertNil(dependencies["ai-task-monitor-dsh-observer"])
    }
}
