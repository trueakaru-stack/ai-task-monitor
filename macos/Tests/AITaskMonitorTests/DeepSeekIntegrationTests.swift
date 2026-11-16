import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

final class DeepSeekIntegrationTests: XCTestCase {
    @MainActor
    func testDesktopProfileIsExplainedAndUnavailable() {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let store = TaskStore.preview()
        store.setPreviewDeepSeekProfiles(desktop: true)
        XCTAssertEqual(store.deepSeekStatusMessage, "The DeepSeek Desktop profile is not supported yet.")
        XCTAssertFalse(store.deepSeekCanChange)
    }

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
        // This integration launches upstream tools. Never run it outside the
        // disposable CI sandbox or fall back to the current user's profile.
        guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS",
              environment["AITM_MACOS_TEST_SANDBOX"] == "1",
              environment["HOME"] == nil, environment["CODEX_HOME"] == nil,
              let tempPath = environment["AITM_MACOS_TEST_ROOT"], tempPath.hasPrefix("/Users/"),
              let markerPath = environment["AITM_CI_DENIED_FILE"], markerPath.hasPrefix("/Users/"),
              let nodeRootPath = environment["AITM_TEST_NODE_ROOT"], nodeRootPath.hasPrefix("/Users/") else {
            XCTFail("A disposable profile sandbox is required for the DeepSeek integration fixture.")
            return
        }
        let manager = FileManager.default
        let temp = URL(fileURLWithPath: tempPath, isDirectory: true).standardizedFileURL
        let marker = URL(fileURLWithPath: markerPath).standardizedFileURL
        let taskRoot = temp.deletingLastPathComponent()
        let rootName = taskRoot.lastPathComponent
        guard temp.lastPathComponent == "temp",
              rootName.range(of: #"^aitm-macos-tests\.[A-Za-z0-9]{8}$"#, options: .regularExpression) != nil,
              marker.lastPathComponent.range(of: #"^aitm-profile-deny\.[A-Za-z0-9]{8}$"#, options: .regularExpression) != nil,
              marker.deletingLastPathComponent().path == taskRoot.deletingLastPathComponent().path,
              temp.resolvingSymlinksInPath().path == temp.path,
              marker.resolvingSymlinksInPath().path == marker.path else {
            XCTFail("The synthetic DeepSeek test paths are invalid.")
            return
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: temp.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            XCTFail("The synthetic DeepSeek test directory is missing.")
            return
        }
        let markerDescriptor = marker.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        if markerDescriptor >= 0 {
            _ = Darwin.close(markerDescriptor)
            XCTFail("The runner profile sandbox did not block the marker.")
            return
        }
        guard errno == EACCES || errno == EPERM else {
            XCTFail("The runner profile sandbox marker could not be verified.")
            return
        }
        let node = URL(fileURLWithPath: nodePath).resolvingSymlinksInPath().standardizedFileURL
        let nodeRoot = URL(fileURLWithPath: nodeRootPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let anchor = URL(fileURLWithPath: anchorPath).resolvingSymlinksInPath().standardizedFileURL
        let pnpm = URL(fileURLWithPath: pnpmPath).resolvingSymlinksInPath().standardizedFileURL
        let packages = taskRoot.appendingPathComponent("dsh/node_modules", isDirectory: true).path + "/"
        guard node.path.hasPrefix(nodeRoot.path + "/"), anchor.path.hasPrefix(packages), pnpm.path.hasPrefix(packages) else {
            XCTFail("DeepSeek test dependencies must come from the disposable fixture.")
            return
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let nodeGuard = project.appendingPathComponent("integration-tests/DeepSeekSyntheticHomeGuard.cjs").path
        guard !nodeGuard.contains("\""), !nodeGuard.contains("\\"), manager.fileExists(atPath: nodeGuard) else {
            XCTFail("The synthetic Node guard is missing or has an unsupported path.")
            return
        }
        let root = temp.appendingPathComponent("aitm-swift-dsh-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        guard root.resolvingSymlinksInPath().path == root.path else {
            XCTFail("The synthetic DeepSeek fixture was redirected.")
            return
        }
        // Leave fixture cleanup to the disposable runner, never recursively delete
        // a path supplied by a process environment.
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
            "CI": "true", "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS",
            "AITM_MACOS_TEST_SANDBOX": "1", "AITM_CI_DENIED_FILE": marker.path,
            "AITM_MACOS_TEST_ROOT": temp.path, "AITM_FIXTURE_ROOT": root.path,
            "NODE_OPTIONS": "--require=\"\(nodeGuard)\"", "USERPROFILE": root.path, "DSH_HOME": dshHome.path,
            "PATH": tools.path + ":" + URL(fileURLWithPath: nodePath).deletingLastPathComponent().path + ":/usr/bin:/bin",
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_CACHE_HOME": root.appendingPathComponent("cache").path,
            "PNPM_CONFIG_STORE_DIR": root.appendingPathComponent("store").path,
            "PNPM_CONFIG_OFFLINE": "true", "PNPM_CONFIG_IGNORE_SCRIPTS": "true", "PNPM_CONFIG_IGNORE_PNPMFILE": "true",
            "NPM_CONFIG_USERCONFIG": root.appendingPathComponent("npmrc").path,
        ]
        let initializer = Process()
        initializer.executableURL = node
        initializer.arguments = [anchor.deletingLastPathComponent().appendingPathComponent("lib/bin.js").path,
                                 "plugin", "--profile", "тестовый-профиль", "add", "--offline", "--ignore-scripts", foreign.path]
        initializer.environment = fixtureEnvironment
        initializer.standardOutput = FileHandle.nullDevice
        let initializerLog = root.appendingPathComponent("initializer-stderr.log")
        let logDescriptor = initializerLog.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard logDescriptor >= 0 else {
            XCTFail("The synthetic initializer log could not be created.")
            return
        }
        let initializerError = FileHandle(fileDescriptor: logDescriptor, closeOnDealloc: true)
        initializer.standardError = initializerError
        try initializer.run()
        initializer.waitUntilExit()
        try initializerError.close()
        guard initializer.terminationStatus == 0 else {
            let detail = ((try? String(contentsOf: initializerLog, encoding: .utf8)) ?? "").suffix(2048)
            XCTFail("The synthetic upstream DeepSeek initializer failed: exit \(initializer.terminationStatus); \(detail)")
            return
        }
        let context = DeepSeekIntegration.Context(node: node, home: dshHome, assets: project.appendingPathComponent("integrations"),
            installAnchor: anchor, pnpmScript: pnpm, environment: fixtureEnvironment)
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
        let trace = try String(contentsOf: root.appendingPathComponent("node-guard-trace"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertGreaterThanOrEqual(trace.filter { $0 == "node" }.count, 4, "Expected real Node fixture processes.")
        XCTAssertGreaterThanOrEqual(trace.filter { $0 == "spawn" }.count, 3, "Expected observed upstream package-manager launches.")
    }
}
