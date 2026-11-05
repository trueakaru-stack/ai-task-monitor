import CryptoKit
import Foundation
import XCTest
@testable import AITaskMonitor

final class HermesIntegrationTests: XCTestCase {
    func testPinnedBridgePreparesAnIsolatedProfileWithoutChangingSettings() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["AITM_HERMES_SOURCE"], !sourcePath.isEmpty else {
            throw XCTSkip("Pinned Hermes source fixture is unavailable")
        }
        guard let pythonPath = ProcessInfo.processInfo.environment["AITM_HERMES_PYTHON"], !pythonPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("Hermes Python fixture with YAML support is unavailable")
        }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-pinned-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for directory in [home, project, assets] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let pinned = URL(fileURLWithPath: sourcePath, isDirectory: true)
        for name in ["hermes_cli/middleware.py", "hermes_cli/plugins.py", "hermes_cli/plugins_dispatch.py",
                     "hermes_cli/lifecycle.py", "agent/turn_api_request.py", "agent/turn_finalizer.py",
                     "tools/human_input_hooks.py", "agent/conversation_loop.py", "model_tools.py",
                     "hermes_cli/cli_shutdown.py", "hermes_cli/cli_session_mixin.py",
                     "hermes_cli/plugins_discovery.py", "hermes_cli/config.py", "hermes_cli/config_backend.py",
                     "hermes_cli/managed_scope.py", "hermes_yaml.py", "hermes_cli/env_loader.py",
                     "hermes_cli/config_defaults.py", "hermes_cli/profiles.py", "hermes_constants.py", "agent/tool_executor.py"] {
            let target = project.appendingPathComponent(name)
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: pinned.appendingPathComponent(name), to: target)
        }
        let integrations = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("integrations", isDirectory: true)
        for name in ["hermes-setup.py", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml",
                     "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py",
                     "ruamel.yaml-0.18.16-py3-none-any.whl"] {
            try manager.copyItem(at: integrations.appendingPathComponent(name), to: assets.appendingPathComponent(name))
        }
        let config = Data("plugins:\n  enabled: [foreign]\nprivate: PRIVATE_FIXTURE\n".utf8)
        try config.write(to: home.appendingPathComponent("config.yaml"))
        let context = HermesIntegration.Context(python: URL(fileURLWithPath: pythonPath), home: home,
                                                project: project, assets: assets)
        let before = try HermesIntegration.profiles(context)
        XCTAssertEqual(before.first?.state, "absent")
        try HermesIntegration.prepare(try XCTUnwrap(before.first), context: context)
        let after = try HermesIntegration.profiles(context)
        XCTAssertEqual(after.first?.state, "prepared")
        XCTAssertEqual(after.first?.enabled, false)
        XCTAssertTrue(DeepSeekIntegration.validScope(after.first?.scope))
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("config.yaml")), config)
        let enabledConfig = Data("plugins:\n  enabled: [foreign, ai-task-monitor]\nprivate: PRIVATE_FIXTURE\n".utf8)
        try enabledConfig.write(to: home.appendingPathComponent("config.yaml"))
        let enabled = try HermesIntegration.profiles(context)
        XCTAssertEqual(enabled.first?.state, "prepared")
        XCTAssertEqual(enabled.first?.enabled, true)
        XCTAssertEqual(enabled.first?.scope, after.first?.scope)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("config.yaml")), enabledConfig)
        var managedContext = context
        managedContext.managed = true
        XCTAssertThrowsError(try HermesIntegration.profiles(managedContext)) { error in
            XCTAssertEqual((error as? HermesIntegrationError)?.code, "managed-config-unconfirmed")
        }
    }

    func testDiscoveryUsesOnlyTheSelectedInstallationAndCommittedEnvironment() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-discover-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let hermes = home.appendingPathComponent(".hermes", isDirectory: true)
        let project = hermes.appendingPathComponent("hermes-agent", isDirectory: true)
        let assets = root.appendingPathComponent("resources/integrations", isDirectory: true)
        let legacy = project.appendingPathComponent("venv", isDirectory: true)
        try manager.createDirectory(at: project.appendingPathComponent("hermes_cli"), withIntermediateDirectories: true)
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        try manager.createDirectory(at: legacy.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: hermes.appendingPathComponent("config.yaml"))
        try Data().write(to: project.appendingPathComponent("hermes_cli/middleware.py"))
        try Data().write(to: assets.appendingPathComponent("hermes-setup.py"))
        try Data().write(to: assets.appendingPathComponent("hermes-manager.py"))
        try Data().write(to: assets.appendingPathComponent("provider_bundle.py"))
        try Data().write(to: legacy.appendingPathComponent("pyvenv.cfg"))
        try manager.createSymbolicLink(at: legacy.appendingPathComponent("bin/python3"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        let legacyContext = try XCTUnwrap(HermesIntegration.discover(home: home, environment: [:], resources: resources))
        XCTAssertEqual(legacyContext.home.path, hermes.path)
        XCTAssertEqual(legacyContext.project.path, project.path)
        XCTAssertEqual(legacyContext.python.path, legacy.appendingPathComponent("bin/python3").path)
        let child = hermes.appendingPathComponent("profiles/work", isDirectory: true)
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        XCTAssertEqual(HermesIntegration.discover(home: home, environment: ["HERMES_HOME": child.path], resources: resources)?.home.path, hermes.path)
        XCTAssertNil(HermesIntegration.discover(home: home, environment: ["HERMES_HOME": "relative"], resources: resources))

        let digest = SHA256.hash(data: Data(project.path.utf8))
        let key = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let install = hermes.appendingPathComponent("installs/\(key)", isDirectory: true)
        let generation = install.appendingPathComponent("environments/g1", isDirectory: true)
        try manager.createDirectory(at: generation.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data().write(to: generation.appendingPathComponent("pyvenv.cfg"))
        try manager.createSymbolicLink(at: generation.appendingPathComponent("bin/python3"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let facts = install.appendingPathComponent("facts.json")
        try JSONSerialization.data(withJSONObject: ["packages": ["venv": ["environment": generation.path]]]).write(to: facts)
        XCTAssertEqual(HermesIntegration.discover(home: home, environment: [:], resources: resources)?.python.path,
                       generation.appendingPathComponent("bin/python3").path)
        try JSONSerialization.data(withJSONObject: ["packages": ["venv": ["environment": legacy.path]]]).write(to: facts)
        XCTAssertNil(HermesIntegration.discover(home: home, environment: [:], resources: resources), "An uncommitted environment must not be selected")
    }

    func testProfilesAndCommandsRejectUntrustedNamesAndAmbiguousScopes() throws {
        let scope = String(repeating: "a", count: 32)
        let root = HermesProfile(id: "root", name: "default", state: "prepared", scope: scope, error: nil, enabled: true)
        let work = HermesProfile(id: "profile:work_1", name: "work_1", state: "absent", scope: nil, error: nil)
        XCTAssertTrue(HermesIntegration.validProfiles([root, work]))
        XCTAssertFalse(HermesIntegration.validProfiles([]))
        XCTAssertFalse(HermesIntegration.validProfiles([work]))
        XCTAssertFalse(HermesIntegration.validProfiles([root, root]))
        XCTAssertFalse(HermesIntegration.validProfiles([root, HermesProfile(id: "profile:work_1", name: "work_1", state: "prepared", scope: scope, error: nil, enabled: false)]))
        XCTAssertTrue(HermesIntegration.validProfiles([HermesProfile(id: "root", name: "default", state: "prepared", scope: scope, error: nil, enabled: false)]))
        XCTAssertFalse(HermesIntegration.validProfiles([HermesProfile(id: "root", name: "default", state: "prepared", scope: scope, error: nil)]), "Prepared state without enabled must be treated as an error")
        let attack = HermesProfile(id: "profile:work;touch", name: "work;touch", state: "absent", scope: nil, error: nil)
        XCTAssertFalse(HermesIntegration.validProfiles([attack]))
        XCTAssertFalse(HermesIntegration.validProfiles([HermesProfile(id: "profile:root", name: "root", state: "absent", scope: nil, error: nil)]))
        let path = URL(fileURLWithPath: "/Users/test/O'Brien/.hermes", isDirectory: true)
        let context = HermesIntegration.Context(python: URL(fileURLWithPath: "/usr/bin/python3"), home: path,
                                                project: path.appendingPathComponent("hermes-agent"),
                                                assets: URL(fileURLWithPath: "/Applications/AI Task Monitor.app/Contents/Resources/integrations"))
        XCTAssertNil(HermesIntegration.command(attack, context: context, enable: true))
        XCTAssertEqual(HermesIntegration.command(root, context: context, enable: true),
                       #"'/usr/bin/python3' -I -B '/Applications/AI Task Monitor.app/Contents/Resources/integrations/hermes-manager.py' '/Users/test/O'\''Brien/.hermes' '/Users/test/O'\''Brien/.hermes/hermes-agent' 'default' 'enable'"#)
        XCTAssertEqual(HermesIntegration.command(work, context: context, enable: false),
                       #"'/usr/bin/python3' -I -B '/Applications/AI Task Monitor.app/Contents/Resources/integrations/hermes-manager.py' '/Users/test/O'\''Brien/.hermes' '/Users/test/O'\''Brien/.hermes/hermes-agent' 'work_1' 'disable'"#)
    }

    func testManualCommandPreservesQuotedPathsInTheShell() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-O'Brien $(echo nope)-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let assets = root.appendingPathComponent("monitor's files", isDirectory: true)
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        let launcher = assets.appendingPathComponent("hermes-manager.py")
        try Data("import json, sys\nprint(json.dumps(sys.argv[1:]))\n".utf8).write(to: launcher)
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard manager.isExecutableFile(atPath: python.path) else { throw XCTSkip("Python fixture is unavailable") }
        let home = root.appendingPathComponent("профиль's home", isDirectory: true)
        let project = root.appendingPathComponent("project's source", isDirectory: true)
        let context = HermesIntegration.Context(python: python, home: home, project: project, assets: assets)
        let profile = HermesProfile(id: "profile:work_1", name: "work_1", state: "prepared",
                                    scope: String(repeating: "a", count: 32), error: nil, enabled: false)
        let command = try XCTUnwrap(HermesIntegration.command(profile, context: context, enable: true))
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), [home.path, project.path, "work_1", "enable"])
        let unsafeContext = HermesIntegration.Context(python: URL(fileURLWithPath: "/tmp/line\nbreak"), home: context.home,
                                                      project: context.project, assets: context.assets)
        XCTAssertNil(HermesIntegration.command(profile, context: unsafeContext, enable: true))
    }

    func testIsolatedBridgeRequestBoundsAndTimeout() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Python fixture is unavailable") }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-hermes-bridge-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        for directory in [home, project, assets] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let bridge = assets.appendingPathComponent("hermes-setup.py")
        let source = """
        import json, os, sys
        request = json.load(sys.stdin)
        assert set(request) <= {'action', 'home', 'project', 'assets', 'profile', 'managed'}
        assert request['managed'] is False
        assert sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode
        assert 'HOME' not in os.environ
        if request['action'] == 'list':
            print(json.dumps({'ok': True, 'result': [{'id':'root','name':'default','state':'absent'}]}))
        else:
            assert request['profile'] == 'root'
            print(json.dumps({'ok': True, 'result': 'prepared'}))
        """
        try Data(source.utf8).write(to: bridge)
        let context = HermesIntegration.Context(python: python, home: home, project: project, assets: assets)
        let profiles = try HermesIntegration.profiles(context)
        XCTAssertEqual(profiles.count, 1)
        try HermesIntegration.prepare(try XCTUnwrap(profiles.first), context: context)
        try Data("raise SystemExit(1)".utf8).write(to: bridge)
        XCTAssertThrowsError(try HermesIntegration.profiles(context))
        try Data("import time; time.sleep(5)".utf8).write(to: bridge)
        let start = Date()
        XCTAssertThrowsError(try HermesIntegration.profiles(context, timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        try Data("print('x' * 200000)".utf8).write(to: bridge)
        XCTAssertThrowsError(try HermesIntegration.profiles(context)) { error in
            XCTAssertEqual((error as? HermesIntegrationError)?.code, "invalid-response")
        }
        XCTAssertFalse(manager.fileExists(atPath: assets.appendingPathComponent("__pycache__").path))
    }
}
