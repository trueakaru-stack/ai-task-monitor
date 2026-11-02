import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeIntegrationSafetyTests: XCTestCase {
    private let executable = "/tmp/AI user's $(sample)/AI Task Monitor"

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
