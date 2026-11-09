import Foundation
import XCTest
@testable import AITaskMonitor

// Protective synthetic cases only. This file has not been compiled or run.
final class ClaudeIdentityInvalidUTF8Tests: XCTestCase {
    func testInvalidUTF8InSessionIdentityCannotCloseAnotherSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        func line(_ badByte: UInt8, _ event: String, _ active: Bool, _ second: Int) -> Data {
            let head = #"{"timestamp":"2026-01-01T00:00:0\#(second)Z","session_id":"synthetic-"#
            let tail = #"","event":"\#(event)","active":\#(active)}"# + "\n"
            return Data(head.utf8) + Data([badByte]) + Data(tail.utf8)
        }
        try (line(0xff, "UserPromptSubmit", true, 0) + line(0xfe, "Stop", false, 1)).write(to: file)
        XCTAssertThrowsError(try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000)),
                             "Malformed UTF-8 must fail the source, not create a shared terminal identity")
    }

    func testLegacySessionDoesNotJoinCanonicallyEquivalentCurrentSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("current.jsonl")
        let legacy = directory.appendingPathComponent("legacy.jsonl")
        func write(_ object: [String: Any], _ file: URL) throws {
            let value = try JSONSerialization.data(withJSONObject: object) + Data([0x0a])
            try value.write(to: file)
        }
        try write(["timestamp":"2026-01-01T00:00:00Z", "session_id":"e\u{301}",
                   "event":"UserPromptSubmit", "active":true], current)
        try write(["timestamp":"2026-01-01T00:00:01Z", "session_id":"\u{e9}",
                   "event":"Stop", "active":false], legacy)
        let result = try ClaudeTaskReader(eventFile: current, legacyFile: legacy)
            .readSnapshot(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.tasks.count, 1)
        let sessionKey = try XCTUnwrap(claudeSessionKey("e\u{301}"))
        XCTAssertEqual(result.tasks.first?.id, "claude:" + sessionKey)
        XCTAssertTrue(result.terminalIDs.isEmpty)
    }

    func testAllSelectedLoopIDFormsRemainUnchanged() {
        for id in ["a", "abc-123_X", String(repeating: "A", count: 128), "_", "-"] {
            XCTAssertTrue(ClaudeLoopInput.validID(id))
            XCTAssertEqual(claudeSessionKey(id), id)
        }
    }

    // A passing reproducer still means integration is BLOCKED: it demonstrates
    // that the current downstream global-ID contract aliases two providers.
    func testKnownPublicIDCollisionBlocksIntegration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codexID = "claude:~c3a9"
        try Data((#"{"id":"claude:~c3a9","thread_name":"Synthetic"}"# + "\n").utf8)
            .write(to: root.appendingPathComponent("session_index.jsonl"))
        try Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"synthetic"}}"# + "\n").utf8)
            .write(to: sessions.appendingPathComponent("rollout-\(codexID).jsonl"))
        let claudeFile = root.appendingPathComponent("claude-events.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let event: [String: Any] = ["timestamp":timestamp, "session_id":"\u{e9}",
                                    "event":"UserPromptSubmit", "active":true]
        try (JSONSerialization.data(withJSONObject: event) + Data([0x0a])).write(to: claudeFile)
        let codex = try XCTUnwrap(CodexTaskReader(codexHome: root).readTasks().first)
        let claude = try XCTUnwrap(ClaudeTaskReader(eventFile: claudeFile).readTasks().first)
        XCTAssertEqual(codex.provider, .codex)
        XCTAssertEqual(claude.provider, .claude)
        XCTAssertEqual(codex.id, claude.id, "Collision reproducer must remain visible until provider-scoped IDs are implemented")
    }
}
