import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudePrefixTitleTests: XCTestCase {
    private func record(_ input: [String: Any], time: Date) -> [String: Any] {
        var value = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value["timestamp"] = formatter.string(from: time)
        return value
    }
    private func prompt(_ id: String, time: Date) -> [String: Any] {
        record(["session_id": id, "hook_event_name": "UserPromptSubmit"], time: time)
    }
    private func created(_ id: String, title: String, time: Date) -> [String: Any] {
        record(["session_id": id, "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                "tool_input": ["subject": title], "tool_response": ["task": ["id": "one", "subject": title]]], time: time)
    }
    private func marker(_ time: Date) -> [String: Any] {
        var value = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: time)
        value["event"] = "AITMPartialTail"; value["scope_incomplete"] = true
        return value
    }
    private func encode(_ rows: [[String: Any]]) throws -> Data {
        var bytes = Data()
        for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); bytes.append(10) }
        return bytes
    }
    private func snapshot(_ bytes: Data) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-prefix-titles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        try bytes.write(to: file)
        return try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date())
    }
    func testValidPrefixTitleBeforePartialBoundarySurvivesFirstRead() throws {
        let t = Date().addingTimeInterval(-20)
        let rows = [prompt("case", time: t), created("case", title: "Old title", time: t.addingTimeInterval(1)),
                    marker(t.addingTimeInterval(2)), prompt("case", time: t.addingTimeInterval(3)),
                    created("case", title: "New title", time: t.addingTimeInterval(4))]
        let result = try snapshot(encode(rows))
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"], "Valid prefix title must be retained without trusting its status")
    }
    func testMalformedPrefixDoesNotHideOtherValidTitlesOrBecomeContent() throws {
        let t = Date().addingTimeInterval(-20)
        let before = try encode([prompt("case", time: t), created("case", title: "Old title", time: t.addingTimeInterval(1))])
        let after = try encode([marker(t.addingTimeInterval(2)), prompt("case", time: t.addingTimeInterval(3)),
                                created("case", title: "New title", time: t.addingTimeInterval(4))])
        let result = try snapshot(before + Data("{invalid:SYNTHETIC_PRIVATE}\n".utf8) + after)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"])
        XCTAssertFalse(task.steps.map(\.title).joined().contains("SYNTHETIC_PRIVATE"))
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }
    func testPrefixForAnotherSessionDoesNotCreateOrContaminateCard() throws {
        let t = Date().addingTimeInterval(-20)
        let rows = [prompt("other", time: t), created("other", title: "Other private title", time: t.addingTimeInterval(1)),
                    marker(t.addingTimeInterval(2)), prompt("case", time: t.addingTimeInterval(3)),
                    created("case", title: "Own title", time: t.addingTimeInterval(4))]
        let result = try snapshot(encode(rows))
        XCTAssertEqual(result.tasks.map(\.id), ["claude:case"])
        XCTAssertEqual(result.tasks.first?.steps.map(\.title), ["Own title"])
        XCTAssertFalse(result.tasks.first?.planConfirmed == true)
    }
    func testPrefixTitleHasNoConfirmedStatus() throws {
        let t = Date().addingTimeInterval(-20)
        let rows = [prompt("case", time: t), created("case", title: "Old title", time: t.addingTimeInterval(1)),
                    marker(t.addingTimeInterval(2)), prompt("case", time: t.addingTimeInterval(3)),
                    created("case", title: "New title", time: t.addingTimeInterval(4))]
        let task = try XCTUnwrap(snapshot(encode(rows)).tasks.first)
        XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"])
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertNil(task.progressLabel)
        XCTAssertNotNil(task.planStatusNote)
    }

    func testUnrelatedPrefixPayloadCannotBecomeTitle() throws {
        let t = Date().addingTimeInterval(-20)
        let formatter = ISO8601DateFormatter()
        let unrelated: [String: Any] = ["timestamp": formatter.string(from: t), "session_id": "case", "event": "Notice",
                                        "task_id": "one", "task_subject": "SYNTHETIC_PRIVATE"]
        var unrelatedTool = unrelated
        unrelatedTool["event"] = "PostToolUse"; unrelatedTool["tool_name"] = "Read"
        let rows = [unrelated, unrelatedTool, marker(t.addingTimeInterval(1)), prompt("case", time: t.addingTimeInterval(2)),
                    created("case", title: "Own title", time: t.addingTimeInterval(3))]
        let result = try snapshot(encode(rows))
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(task.steps.map(\.title), ["Own title"])
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

}
