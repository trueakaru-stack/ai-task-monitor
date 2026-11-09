import Foundation
import XCTest
@testable import AITaskMonitor

enum ClaudeScopedOverflowFixture {
    static func make() throws -> ClaudeTaskSnapshot {
        var evidence = ClaudePhaseEvidence()
        evidence.start(key: Data(repeating: 11, count: 32))
        for index in 0...8192 {
            let owner = index == 0 ? "case" : "filler"
            evidence.observe(session: owner, toolID: "call", fingerprint: String(format: "%064d", index))
        }
        XCTAssertTrue(evidence.isSessionUncertain("case"))
        XCTAssertFalse(evidence.isSessionUncertain("neighbor"))
        XCTAssertFalse(evidence.poisoned)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-scoped-overflow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let time = Date().addingTimeInterval(-20)
        func record(_ input: [String: Any], seconds: TimeInterval) -> [String: Any] {
            var value = ClaudeHook.makeRecord(from: input)
            value["timestamp"] = formatter.string(from: time.addingTimeInterval(seconds))
            return value
        }
        var rows: [[String: Any]] = [record(["session_id": "case", "hook_event_name": "UserPromptSubmit"], seconds: 0)]
        for index in 0..<4100 {
            let title = "Title \(index)"
            rows.append(record(["session_id": "case", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                                "tool_input": ["subject": title], "tool_response": ["task": ["id": "one", "subject": title]]],
                               seconds: Double(index + 1) / 1000))
        }
        rows.append(record(["session_id": "neighbor", "hook_event_name": "UserPromptSubmit"], seconds: 5))
        rows.append(record(["session_id": "neighbor", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                            "tool_input": ["subject": "Neighbor"], "tool_response": ["task": ["id": "step", "subject": "Neighbor"]]], seconds: 5.1))
        rows.append(record(["session_id": "neighbor", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                            "tool_input": ["taskId": "step", "status": "completed"],
                            "tool_response": ["success": true, "taskId": "step", "updatedFields": ["status"],
                                              "statusChange": ["from": "pending", "to": "completed"]]], seconds: 5.2))
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10) }
        try data.write(to: file)
        let result = try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date(), phaseEvidence: evidence)
        return result
    }
}

final class ClaudeScopedOverflowBaseTests: XCTestCase {
    func testOneSessionOverflowDoesNotInventGlobalLoss() throws {
        let result = try ClaudeScopedOverflowFixture.make()
        let affected = try XCTUnwrap(result.tasks.first(where: { $0.id == "claude:case" }))
        let neighbor = try XCTUnwrap(result.tasks.first(where: { $0.id == "claude:neighbor" }))
        XCTAssertFalse(result.sourceUncertain, "A session-local overflow must not invent source-wide loss")
        XCTAssertFalse(affected.planConfirmed)
        XCTAssertNil(affected.progress)
        XCTAssertEqual(affected.steps.count, 4097)
        XCTAssertTrue(neighbor.planConfirmed)
        XCTAssertEqual(neighbor.progress, 100)
    }
}
