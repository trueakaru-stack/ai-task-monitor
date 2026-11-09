import Foundation
import XCTest
@testable import AITaskMonitor

// Protective assertions: pre-decision and failure hooks must not be treated
// as a successful observed result, regardless of status-shaped input.
final class ClaudeHookPhaseBlockingTests: XCTestCase {
    func testIntentFailureOrBlockedCompletionDoesNotProveDone() throws {
        let start = ISO8601DateFormatter().date(from: "2026-11-05T15:09:00Z")!
        let formatter = ISO8601DateFormatter()
        let cases: [(String, String, String)] = [
            ("PreToolUse", "TaskUpdate", "completed"),
            ("PostToolUseFailure", "TaskUpdate", "completed"),
            ("PostToolUse", "Read", "completed"),
            ("TaskCompleted", "", "")
        ]
        for (event, tool, status) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-claude-phase-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("events.jsonl")
            func record(_ seconds: TimeInterval, _ event: String, task: Bool = false,
                        tool: String = "", status: String = "") throws -> String {
                var value: [String: Any] = ["session_id": "synthetic", "timestamp": formatter.string(from: start.addingTimeInterval(seconds)),
                                            "event": event, "active": true]
                if task { value["task_id"] = "x"; value["task_subject"] = "Synthetic step" }
                if !tool.isEmpty { value["tool_name"] = tool }
                if !status.isEmpty { value["task_status"] = status }
                return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
            }
            let lines = [
                try record(0, "UserPromptSubmit"),
                try record(1, "TaskCreated", task: true, status: "pending"),
                try record(2, event, task: true, tool: tool, status: status)
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readTasks(now: start.addingTimeInterval(3)).first)
            let falselyConfirmed = task.planConfirmed && task.steps.first?.status == .done
            XCTAssertFalse(falselyConfirmed, "\(event) / \(tool): intent or a blockable hook is not a committed result")
            XCTAssertFalse(task.planConfirmed && task.progress == 100)
        }
    }
}
