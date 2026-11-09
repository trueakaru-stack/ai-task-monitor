import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic settings only. Prepared for isolated macOS CI; not run on Windows.
final class ClaudeIntegrationPreservationIndependentTests: XCTestCase {
    private let executable = "/tmp/aitm-synthetic-executable"

    private func withSettings(_ data: Data, _ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-settings-preserve-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try data.write(to: url)
        try body(url)
    }

    private func groupInput(command: String) throws -> Data {
        let group: [String: Any] = ["matcher": "Bash", "plugin": ["foreign": "synthetic-keep"],
                                    "hooks": [["type": "command", "command": command]]]
        return try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [group]]], options: [.sortedKeys])
    }

    private func checkGroupSurvivesOrOperationIsRejected(command: String, connect: Bool) throws {
        let original = try groupInput(command: command)
        try withSettings(original) { url in
            do {
                try ClaudeIntegration.setConnected(connect, settingsURL: url, executable: executable)
            } catch {
                XCTAssertEqual(try Data(contentsOf: url), original, "Refusal must not change the original settings")
                return
            }
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            let hooks = value?["hooks"] as? [String: Any]
            let groups = hooks?["PreToolUse"] as? [[String: Any]] ?? []
            XCTAssertTrue(groups.contains { group in
                group["matcher"] as? String == "Bash" &&
                    (group["plugin"] as? [String: String])?["foreign"] == "synthetic-keep"
            }, "A group's foreign metadata must not silently disappear")
        }
    }

    func testReconnectLegacyGroupRetainsForeignMetadataOrRejects() throws {
        let legacy = "\"\(executable)\" --claude-hook"
        try checkGroupSurvivesOrOperationIsRejected(command: legacy, connect: true)
    }

    func testDisconnectCurrentGroupRetainsForeignMetadataOrRejects() throws {
        try checkGroupSurvivesOrOperationIsRejected(command: ClaudeIntegration.hookCommand(for: executable), connect: false)
    }

    private func threshold(in data: Data) throws -> Decimal {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let pattern = "\\\"threshold\\\"\\s*:\\s*([-+0-9.eE]+)"
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let range = try XCTUnwrap(Range(match.range(at: 1), in: text))
        return try XCTUnwrap(Decimal(string: String(text[range]), locale: Locale(identifier: "en_US_POSIX")))
    }

    func testHighPrecisionForeignNumberSurvivesConnectAndDisconnect() throws {
        let number = "0.12345678901234567890123456789"
        let original = Data("{\"unrelated\":{\"threshold\":\(number)},\"hooks\":{}}".utf8)
        let expected = try XCTUnwrap(Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")))
        try withSettings(original) { url in
            try ClaudeIntegration.setConnected(true, settingsURL: url, executable: executable)
            XCTAssertEqual(try threshold(in: Data(contentsOf: url)), expected, "Connect must preserve the exact foreign numeric value")
            try ClaudeIntegration.setConnected(false, settingsURL: url, executable: executable)
            XCTAssertEqual(try threshold(in: Data(contentsOf: url)), expected, "Disconnect must preserve the exact foreign numeric value")
        }
    }

    func testDuplicateForeignKeysAreNotSilentlyCollapsed() throws {
        let original = Data("{\"unrelated\":{\"duplicate\":1,\"duplicate\":2},\"hooks\":{}}".utf8)
        try withSettings(original) { url in
            do {
                try ClaudeIntegration.setConnected(true, settingsURL: url, executable: executable)
            } catch {
                XCTAssertEqual(try Data(contentsOf: url), original)
                return
            }
            let text = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
            let count = text.components(separatedBy: "\"duplicate\"").count - 1
            XCTAssertEqual(count, 2, "Ambiguous foreign members should be preserved verbatim or the write rejected")
        }
    }
}
