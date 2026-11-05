import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeIntegrationSafetyTests: XCTestCase {
    private let executable = "/tmp/AI user's $(sample)/AI Task Monitor"

    func testProfileAloneDoesNotProveClaudeInstallation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(ClaudeIntegration.installationState(home: home, searchPath: "", includeStandardPaths: false), .notFound)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeIntegration.installationState(home: home, searchPath: "", includeStandardPaths: false), .unconfirmed)
        let bin = home.appendingPathComponent("custom-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let command = bin.appendingPathComponent("claude")
        try Data("synthetic".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        XCTAssertEqual(ClaudeIntegration.installationState(home: home, searchPath: bin.path, includeStandardPaths: false), .available)
    }

    func testConnectionControlsAllowUnconfirmedProfileWithoutClaimingInstallation() {
        XCTAssertTrue(ClaudeIntegration.canChangeConnection(installation: .unconfirmed, connection: .disconnected, sourceUnavailable: false))
        XCTAssertFalse(ClaudeIntegration.canChangeConnection(installation: .notFound, connection: .disconnected, sourceUnavailable: false))
        XCTAssertFalse(ClaudeIntegration.canChangeConnection(installation: .unconfirmed, connection: .disconnected, sourceUnavailable: true))
        XCTAssertFalse(ClaudeIntegration.canChangeConnection(installation: .unconfirmed, connection: nil, sourceUnavailable: false))
        XCTAssertTrue(ClaudeIntegration.canChangeConnection(installation: .notFound, connection: .connected, sourceUnavailable: true))
        XCTAssertTrue(ClaudeIntegration.canChangeConnection(installation: .notFound, connection: .partial, sourceUnavailable: true))
    }

    func testGeneratedHookCommandRunsExecutableAndUpdatesReader() throws {
        guard let binary = ProcessInfo.processInfo.environment["AITM_CLAUDE_TEST_EXECUTABLE"], !binary.isEmpty else {
            throw XCTSkip("Set AITM_CLAUDE_TEST_EXECUTABLE to the built monitor executable for the end-to-end fixture")
        }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binaryDirectory = directory.appendingPathComponent("AI user's $(synthetic)", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let copiedBinary = binaryDirectory.appendingPathComponent("AI Task Monitor")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: binary), to: copiedBinary)
        let settings = directory.appendingPathComponent("profile/.claude/settings.json")
        let support = directory.appendingPathComponent("monitor data", isDirectory: true)
        try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: copiedBinary.path)
        let hooks = try XCTUnwrap(try readObject(settings)["hooks"] as? [String: Any])

        func invoke(_ event: String) throws {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            let commands = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(commands.first?["command"] as? String)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOME": directory.path, "PATH": "/usr/bin:/bin",
                                   "AI_TASK_MONITOR_SUPPORT_DIR": support.path, "AI_TASK_MONITOR_AUDIT": "1"]
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let payload: [String: Any] = ["hook_event_name": event, "session_id": "synthetic-session",
                                          "prompt": "SYNTHETIC_PROMPT_SECRET", "cwd": "/synthetic/private/path"]
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        }

        let since = Date().addingTimeInterval(-1)
        try invoke("UserPromptSubmit")
        let eventFile = support.appendingPathComponent("claude-events-v2.jsonl")
        let reader = ClaudeTaskReader(eventFile: eventFile)
        let active = try reader.readSnapshot(observedSince: since)
        XCTAssertEqual(active.tasks.map(\.id), ["claude:synthetic-session"])
        XCTAssertEqual(active.tasks.first?.isActive, true)
        try invoke("Stop")
        let stopped = try reader.readSnapshot(observedSince: since)
        XCTAssertTrue(stopped.tasks.isEmpty)
        XCTAssertTrue(stopped.terminalIDs.contains("claude:synthetic-session"))
        let saved = try String(contentsOf: eventFile, encoding: .utf8)
        XCTAssertFalse(saved.contains("SYNTHETIC_PROMPT_SECRET"))
        XCTAssertFalse(saved.contains("/synthetic/private/path"))
    }

    func testConnectAndDisconnectPreserveUnrelatedSettingsAndPermissions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let other: [String: Any] = ["type": "command", "command": "/usr/bin/other-tool"]
        let root: [String: Any] = [
            "environment": ["custom": "preserve"],
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [other]]],
                "Notification": [["matcher": "notice", "hooks": [other]]]
            ]
        ]
        let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try original.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)

        try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable)
        let connected = try readObject(settings)
        XCTAssertEqual((connected["environment"] as? [String: String])?["custom"], "preserve")
        let hooks = try XCTUnwrap(connected["hooks"] as? [String: Any])
        let preGroups = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preGroups.first?["matcher"] as? String, "Bash")
        XCTAssertEqual(((preGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String), "/usr/bin/other-tool")
        XCTAssertEqual((hooks["Notification"] as? [[String: Any]])?.first?["matcher"] as? String, "notice")
        XCTAssertTrue(preGroups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                ClaudeIntegration.isOwnedHook($0, executable: executable)
            } == true
        })
        XCTAssertEqual(try mode(settings), 0o600)
        let firstBackups = try backups(in: directory)
        XCTAssertEqual(firstBackups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(firstBackups.first)), original)
        XCTAssertEqual(try mode(XCTUnwrap(firstBackups.first)), 0o600)

        let unchanged = try Data(contentsOf: settings)
        try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable)
        XCTAssertEqual(try Data(contentsOf: settings), unchanged)
        XCTAssertEqual(try backups(in: directory).count, 1)

        try ClaudeIntegration.setConnected(false, settingsURL: settings, executable: executable)
        let disconnected = try readObject(settings)
        let remaining = try XCTUnwrap(disconnected["hooks"] as? [String: Any])
        let remainingPre = try XCTUnwrap(remaining["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(remainingPre.count, 1)
        XCTAssertEqual(remainingPre.first?["matcher"] as? String, "Bash")
        XCTAssertEqual((remaining["Notification"] as? [[String: Any]])?.first?["matcher"] as? String, "notice")
        XCTAssertEqual((disconnected["environment"] as? [String: String])?["custom"], "preserve")
        XCTAssertEqual(try mode(settings), 0o600)
        XCTAssertEqual(try backups(in: directory).count, 2)
    }

    func testUnsupportedHooksAreNotOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let cases: [[String: Any]] = [
            ["hooks": "unexpected"],
            ["hooks": ["PreToolUse": "unexpected"]],
            ["hooks": ["PreToolUse": [["hooks": "unexpected"]]]]
        ]
        for root in cases {
            let original = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try original.write(to: settings)
            XCTAssertThrowsError(try ClaudeIntegration.connectionState(settingsURL: settings))
            XCTAssertThrowsError(try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable))
            XCTAssertThrowsError(try ClaudeIntegration.setConnected(false, settingsURL: settings, executable: executable))
            XCTAssertEqual(try Data(contentsOf: settings), original)
        }
        XCTAssertTrue(try backups(in: directory).isEmpty)
    }

    func testConcurrentSettingsChangeIsNotOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        let original = Data("{\"example\":\"before\"}".utf8)
        let concurrent = Data("{\"example\":\"changed elsewhere\"}".utf8)
        try original.write(to: settings)
        XCTAssertThrowsError(try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable) {
            try concurrent.write(to: settings)
        })
        XCTAssertEqual(try Data(contentsOf: settings), concurrent)
        XCTAssertTrue(try backups(in: directory).isEmpty)
    }

    func testSettingsSymbolicLinksAndBackupContentsArePreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["absolute", "relative", "chain"] {
            let profile = directory.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("\(kind)-target.json")
            let settings = profile.appendingPathComponent("settings.json")
            let original = Data("{\"unrelated\":\"keep\"}".utf8)
            try original.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let relativeTarget = "../\(kind)-target.json"
            var intermediate: URL?
            let destination: String
            if kind == "chain" {
                let link = profile.appendingPathComponent("intermediate.json")
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: relativeTarget)
                intermediate = link
                destination = "intermediate.json"
            } else {
                destination = kind == "absolute" ? target.path : relativeTarget
            }
            try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: destination)

            try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), destination)
            if let intermediate {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: intermediate.path), relativeTarget)
            }
            let connected = try readObject(target)
            XCTAssertEqual(connected["unrelated"] as? String, "keep")
            XCTAssertNotNil(connected["hooks"])
            let backup = try XCTUnwrap(backups(in: profile).first)
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try mode(backup), 0o600)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType, .typeRegular)

            try ClaudeIntegration.setConnected(false, settingsURL: settings, executable: executable)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), destination)
            XCTAssertEqual(try readObject(target)["unrelated"] as? String, "keep")
            XCTAssertEqual(try backups(in: profile).count, 2)
        }
    }

    func testRetargetedSettingsLinkIsNotOverwrittenEvenWhenBytesMatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        let settings = directory.appendingPathComponent("settings.json")
        let original = Data("{\"unrelated\":\"keep\"}".utf8)
        try original.write(to: first)
        try original.write(to: second)
        try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: first.path)
        XCTAssertThrowsError(try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable) {
            try FileManager.default.removeItem(at: settings)
            try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: second.path)
        })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), second.path)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertTrue(try backups(in: directory).isEmpty)
    }

    func testBrokenAndCyclicSettingsLinksAreLeftUnchanged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["dangling", "cycle"] {
            let profile = directory.appendingPathComponent(kind, isDirectory: true)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let settings = profile.appendingPathComponent("settings.json")
            let other = profile.appendingPathComponent("other.json")
            if kind == "cycle" {
                try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: "settings.json")
            }
            try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: "other.json")
            XCTAssertThrowsError(try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path), "other.json")
            if kind == "cycle" {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: other.path), "settings.json")
            }
            XCTAssertTrue(try backups(in: profile).isEmpty)
        }
    }

    func testDisconnectMissingSettingsDoesNotCreateDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("not-created", isDirectory: true)
        try ClaudeIntegration.setConnected(false, settingsURL: missing.appendingPathComponent("settings.json"), executable: executable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func backups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.ai-task-monitor-backup-") }
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }
}
