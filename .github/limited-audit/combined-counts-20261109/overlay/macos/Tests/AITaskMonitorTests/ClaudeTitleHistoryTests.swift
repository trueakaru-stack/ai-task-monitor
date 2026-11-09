import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic events are read once, with no previous TaskStore snapshot.
final class ClaudeTitleHistoryTests: XCTestCase {
    private func record(_ input: [String: Any], time: Date) -> [String: Any] {
        var result = ClaudeHook.makeRecord(from: input)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = f.string(from: time)
        return result
    }
    private func prompt(_ time: Date) -> [String: Any] {
        record(["session_id": "case", "hook_event_name": "UserPromptSubmit"], time: time)
    }
    private func created(_ title: String, time: Date) -> [String: Any] {
        record(["session_id": "case", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                "tool_input": ["subject": title], "tool_response": ["task": ["id": "one", "subject": title]]], time: time)
    }
    private func completed(_ time: Date) -> [String: Any] {
        record(["session_id": "case", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": "one", "status": "completed"],
                "tool_response": ["success": true, "taskId": "one", "updatedFields": ["status"],
                                  "statusChange": ["from": "pending", "to": "completed"]]], time: time)
    }
    private func snapshot(_ records: [[String: Any]], evidence: ClaudePhaseEvidence? = nil) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-title-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        var data = Data()
        for row in records {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10)
        }
        try data.write(to: file)
        return try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date(), phaseEvidence: evidence)
    }
    func testOldAndNewTitleSameIDBeforeFirstPollSurviveKnownLoss() throws {
        let t = Date().addingTimeInterval(-20)
        let marker = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: t.addingTimeInterval(2))
        let result = try snapshot([prompt(t), created("Old title", time: t.addingTimeInterval(1)), marker,
                                   prompt(t.addingTimeInterval(3)), created("New title", time: t.addingTimeInterval(4)),
                                   completed(t.addingTimeInterval(5))])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"], "Both observed titles must survive one read")
    }
    func testConflictingTitleWithoutKnownLossKeepsLatestAndUnconfirmed() throws {
        let t = Date().addingTimeInterval(-20)
        let result = try snapshot([prompt(t), created("Old", time: t.addingTimeInterval(1)),
                                   created("New", time: t.addingTimeInterval(2)), completed(t.addingTimeInterval(3))])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.map(\.title), ["New"])
    }
    func testGeneratedPlaceholderIsNotRetainedAsAnObservedTitle() throws {
        let t = Date().addingTimeInterval(-20)
        let update = completed(t.addingTimeInterval(1))
        let marker = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: t.addingTimeInterval(-1))
        let result = try snapshot([marker, prompt(t), update, created("Actual title", time: t.addingTimeInterval(2))])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(task.steps.map(\.title), ["Actual title"])
        XCTAssertFalse(task.planConfirmed)
    }
    func testObservedTitleHistoryIsBoundedAndSignalsLoss() throws {
        let t = Date().addingTimeInterval(-20)
        let marker = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: t.addingTimeInterval(-1))
        var rows = [marker, prompt(t)]
        for index in 0..<4100 { rows.append(created("Title \(index)", time: t.addingTimeInterval(Double(index + 1) / 1000))) }
        let result = try snapshot(rows)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.count, 4097)
        XCTAssertEqual(task.steps.last?.title, "Title 4099")
    }

    func testConflictingTitlesDoNotUnconfirmNeighbor() throws {
        let t = Date().addingTimeInterval(-20)
        let own = [prompt(t), created("Old", time: t.addingTimeInterval(1)),
                   created("New", time: t.addingTimeInterval(2)), completed(t.addingTimeInterval(3))]
        let neighbor = [prompt(t), created("Neighbor", time: t.addingTimeInterval(1)),
                        completed(t.addingTimeInterval(2))].map { row -> [String: Any] in
            var copy = row; copy["session_id"] = "neighbor"; return copy
        }
        let result = try snapshot(own + neighbor)
        let first = try XCTUnwrap(result.tasks.first(where: { $0.id == "claude:case" }))
        let other = try XCTUnwrap(result.tasks.first(where: { $0.id == "claude:neighbor" }))
        XCTAssertFalse(first.planConfirmed)
        XCTAssertEqual(first.steps.map(\.title), ["New"])
        XCTAssertTrue(other.planConfirmed)
        XCTAssertEqual(other.progress, 100)
    }


    func testPhaseEvidenceGapRetainsObservedNamesWithoutConfirming() throws {
        let t = Date().addingTimeInterval(-20)
        var evidence = ClaudePhaseEvidence()
        evidence.invalidate()
        let result = try snapshot([prompt(t), created("Old", time: t.addingTimeInterval(1)),
                                   created("New", time: t.addingTimeInterval(2)), completed(t.addingTimeInterval(3))], evidence: evidence)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertFalse(result.sourceUncertain)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.map(\.title), ["Old", "New"])
    }

}
