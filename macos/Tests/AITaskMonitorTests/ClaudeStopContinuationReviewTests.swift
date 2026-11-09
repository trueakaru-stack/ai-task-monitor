import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic events only. This file is not part of any currently running CI.
final class ClaudeStopContinuationReviewTests: XCTestCase {
    private func record(_ kind: String, time: Date, extra: [String: Any] = [:]) -> [String: Any] {
        var input = extra
        input["session_id"] = "case"
        input["hook_event_name"] = kind
        var result = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = formatter.string(from: time)
        return result
    }
    private func snapshot(_ records: [[String: Any]]) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-stop-review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); data.append(10)
        }
        try data.write(to: file)
        return try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date())
    }
    func testUnknownStopThenObservedToolWorkOrNewPromptStaysUnconfirmed() throws {
        let t = Date().addingTimeInterval(-10)
        let start = record("UserPromptSubmit", time: t)
        let uncertainStop = record("Stop", time: t.addingTimeInterval(1))
        let variants: [[[String: Any]]] = [
            [record("PreToolUse", time: t.addingTimeInterval(2), extra: ["tool_name": "Read"]),
             record("PostToolUseFailure", time: t.addingTimeInterval(3), extra: ["tool_name": "Read"])],
            [record("UserPromptSubmit", time: t.addingTimeInterval(2)),
             record("PreToolUse", time: t.addingTimeInterval(3), extra: ["tool_name": "Read"])]
        ]
        for continuation in variants {
            let task = try XCTUnwrap(snapshot([start, uncertainStop] + continuation).tasks.first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.isActive)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
        }
    }
    func testAfterClearStopNewToolEventCanAppearActiveWithoutKnownLoss() throws {
        let t = Date().addingTimeInterval(-10)
        let result = try snapshot([record("UserPromptSubmit", time: t), record("Stop", time: t.addingTimeInterval(1)),
            record("Stop", time: t.addingTimeInterval(2), extra: ["background_tasks": [], "session_crons": []]),
            record("PreToolUse", time: t.addingTimeInterval(3), extra: ["tool_name": "Read"])])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertFalse(task.isUnconfirmed)
        XCTAssertTrue(task.isActive)
    }
}
