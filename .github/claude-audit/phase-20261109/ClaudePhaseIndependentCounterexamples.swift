import Foundation
import XCTest
@testable import AITaskMonitor

// Independent proposed macOS CI cases. These are synthetic inputs, not real
// Claude sessions. They have not been compiled or executed on this Windows host.
final class ClaudePhaseIndependentCounterexamples: XCTestCase {
    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func record(_ at: Date, _ input: [String: Any]) -> [String: Any] {
        var payload = input
        if payload["session_id"] == nil { payload["session_id"] = "synthetic" }
        var output = ClaudeHook.makeRecord(from: payload)
        output["timestamp"] = stamp(at)
        return output
    }

    private func prompt(_ at: Date) -> [String: Any] {
        record(at, ["hook_event_name": "UserPromptSubmit"])
    }

    private func create(_ at: Date, call: String? = nil) -> [String: Any] {
        var input: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
            "tool_input": ["subject": "Old title"],
            "tool_response": ["task": ["id": "step-1", "subject": "Old title"]]]
        if let call { input["tool_use_id"] = call }
        return record(at, input)
    }

    private func encodeLines(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0a)
        }
        return data
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-phase-independent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testCombinedStatusAndTitleUpdateMustNotConfirmOldTitle() throws {
        try withDirectory { directory in
            let now = Date(), current = directory.appendingPathComponent("current.jsonl")
            let update = record(now.addingTimeInterval(-1), [
                "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": "step-1", "status": "completed", "subject": "New title"],
                "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status", "subject"],
                                  "statusChange": ["from": "pending", "to": "completed"]]
            ])
            try encodeLines([prompt(now.addingTimeInterval(-3)), create(now.addingTimeInterval(-2)), update]).write(to: current)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: current).readSnapshot(now: now).tasks.first)
            XCTAssertFalse(task.planConfirmed && task.steps.first?.title == "Old title",
                           "An observed rename must not leave old title under confirmed progress")
        }
    }

    func testRawToolUseIdentifierIsNotPersistedInEventFile() throws {
        let identifier = "SYNTHETIC_PRIVATE_TOOL_USE_123"
        let output = record(Date(), ["hook_event_name": "PreToolUse", "tool_name": "TaskUpdate",
            "tool_use_id": identifier, "tool_input": ["taskId": "step-1", "status": "completed"]])
        let text = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: output), encoding: .utf8))
        XCTAssertFalse(text.contains(identifier), "Raw tool-use identifiers were not among the event-log fields previously disclosed")
    }

    func testFalseResultDoesNotDisplaySuccessfulToolActivity() throws {
        try withDirectory { directory in
            let now = Date(), current = directory.appendingPathComponent("current.jsonl")
            let failed = record(now.addingTimeInterval(-1), [
                "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": "step-1", "status": "completed"],
                "tool_response": ["success": false, "taskId": "step-1", "updatedFields": []]
            ])
            try encodeLines([prompt(now.addingTimeInterval(-3)), create(now.addingTimeInterval(-2)), failed]).write(to: current)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: current).readSnapshot(now: now).tasks.first)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNotEqual(task.activity, "Completed: TaskUpdate")
            XCTAssertNotEqual(task.activity, "Завершено: TaskUpdate")
        }
    }

    // User accepted progress over observed stages with a caveat. Whether the
    // unlinked notice can be reconciled safely needs a versioned upstream
    // contract; this test expresses the requested recovery, not proof of it.
    func testMatchedCreateAfterNoticeCanRecoverObservedProgress() throws {
        try withDirectory { directory in
            let now = Date(), current = directory.appendingPathComponent("current.jsonl")
            let pre = record(now.addingTimeInterval(-3), ["hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
                "tool_use_id": "call-1", "tool_input": ["subject": "Old title"]])
            let notice = record(now.addingTimeInterval(-2), ["hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Old title"])
            let post = create(now.addingTimeInterval(-1), call: "call-1")
            try encodeLines([prompt(now.addingTimeInterval(-4)), pre, notice, post]).write(to: current)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: current).readSnapshot(now: now).tasks.first)
            XCTAssertTrue(task.planConfirmed, "A validated matching result should be usable if the notice is safely reconciled")
        }
    }

    func testKnownRotationDoesNotForgetUnresolvedAttempt() throws {
        try withDirectory { directory in
            let now = Date()
            let current = directory.appendingPathComponent("claude-events-v2.jsonl")
            let legacy = directory.appendingPathComponent("claude-events.jsonl")
            try encodeLines([prompt(now.addingTimeInterval(-5)), create(now.addingTimeInterval(-4))]).write(to: legacy)
            let pre = record(now.addingTimeInterval(-3), ["hook_event_name": "PreToolUse", "tool_name": "TaskUpdate",
                "tool_use_id": "call-pending", "tool_input": ["taskId": "step-1", "status": "completed"]])
            let filler: [String: Any] = ["timestamp": stamp(now.addingTimeInterval(-2)), "session_id": "other",
                                        "event": "PreToolUse", "tool_name": "Read", "active": true,
                                        "padding": String(repeating: "x", count: 160)]
            var original = try encodeLines([pre])
            let fillerLine = try encodeLines([filler])
            while original.count <= 1_000_100 { original.append(fillerLine) }
            try original.write(to: current)
            let reader = ClaudeTaskReader(eventFile: current, legacyFile: legacy)
            let before = try XCTUnwrap(reader.readSnapshot(now: now).tasks.first(where: { $0.id == "claude:synthetic" }))
            XCTAssertFalse(before.planConfirmed, "The known unfinished attempt initially suppresses progress")
            let result = ClaudeHook.process(["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "Read"],
                directory: directory, retentionPolicy: { ClaudeRetentionPolicy(days: 7, maximumMB: 1) }, sendLoop: { _, _ in })
            XCTAssertEqual(result, 0)
            XCTAssertLessThan(try Data(contentsOf: current).count, 1_000_000)
            let after = try XCTUnwrap(reader.readSnapshot(now: Date().addingTimeInterval(1)).tasks.first(where: { $0.id == "claude:synthetic" }))
            XCTAssertFalse(after.planConfirmed, "A detectable rotation must not silently forget the pending attempt")
        }
    }

    // Characterizes the current recovery delay; this intentionally does not
    // request reading any real event file or changing the candidate.
    func testInvalidMarkerPersistsUntilRetentionCutoff() throws {
        try withDirectory { directory in
            let now = Date(), current = directory.appendingPathComponent("claude-events-v2.jsonl")
            let marker = record(now, ["hook_event_name": "Unknown", "session_id": ""])
            let fresh = prompt(now.addingTimeInterval(86_409))
            try encodeLines([marker, fresh]).write(to: current)
            let reader = ClaudeTaskReader(eventFile: current)
            XCTAssertThrowsError(try reader.readSnapshot(now: now))
            let policy = ClaudeRetentionPolicy(days: 1, maximumMB: 1)
            try ClaudeRetention.clean(directory: directory, backups: directory.appendingPathComponent("backups"),
                                      now: now.addingTimeInterval(1), policy: policy)
            XCTAssertThrowsError(try reader.readSnapshot(now: now.addingTimeInterval(1)))
            try ClaudeRetention.clean(directory: directory, backups: directory.appendingPathComponent("backups"),
                                      now: now.addingTimeInterval(86_410), policy: policy)
            let recovered = try reader.readSnapshot(now: now.addingTimeInterval(86_410))
            XCTAssertEqual(recovered.tasks.count, 1)
        }
    }

    func testPartialAppendFollowedByAnotherRecordBlocksReaderAndRetention() throws {
        try withDirectory { directory in
            let now = Date(), current = directory.appendingPathComponent("claude-events-v2.jsonl")
            var bytes = Data("{\"session_id\":\"synthetic\"".utf8)
            bytes.append(try encodeLines([prompt(now)]))
            try bytes.write(to: current)
            XCTAssertThrowsError(try ClaudeTaskReader(eventFile: current).readSnapshot(now: now))
            XCTAssertThrowsError(try ClaudeRetention.clean(directory: directory,
                backups: directory.appendingPathComponent("backups"), now: now,
                policy: ClaudeRetentionPolicy(days: 7, maximumMB: 10)))
        }
    }
}
