import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic-only regression cases; not executed on macOS during review.
final class ClaudeRecoveryBoundaryIndependentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-independent-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func event(_ input: [String: Any], at date: Date) -> [String: Any] {
        var result = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = formatter.string(from: date)
        return result
    }

    private func loss(at date: Date) -> [String: Any] {
        event(["session_id": "", "hook_event_name": "AITMSourceUncertain"], at: date)
    }

    private func start(at date: Date) -> [String: Any] {
        event(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: date)
    }

    private func observed(at now: Date) -> [[String: Any]] {
        [event(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-2)),
         event(["session_id": "candidate", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                "tool_input": ["subject": "Synthetic step"],
                "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]],
               at: now.addingTimeInterval(-1.5)),
         event(["session_id": "candidate", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": "step-1", "status": "completed"],
                "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                                  "statusChange": ["from": "pending", "to": "completed"]]],
               at: now.addingTimeInterval(-1))]
    }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        var data = Data()
        for item in records {
            data.append(try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try data.write(to: url)
    }

    private func assertUnconfirmed(_ snapshot: ClaudeTaskSnapshot, file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        XCTAssertTrue(snapshot.sourceUncertain, file: file, line: line)
        let task = try XCTUnwrap(snapshot.tasks.first(where: { $0.id == "claude:candidate" }), file: file, line: line)
        XCTAssertTrue(task.isUnconfirmed, file: file, line: line)
        XCTAssertFalse(task.planConfirmed, file: file, line: line)
        XCTAssertNil(task.progress, file: file, line: line)
    }

    func testEarlierStartupWrittenAfterLossIsNotFresh() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), current = dir.appendingPathComponent("claude-events-v2.jsonl")
        // Hook timestamps are captured before its shared file lock. These
        // physical writes model a delayed startup arriving after a later loss.
        try write([loss(at: now.addingTimeInterval(-3)), start(at: now.addingTimeInterval(-4))] + observed(at: now), to: current)
        let snapshot = try ClaudeTaskReader(eventFile: current).readSnapshot(now: now)
        try assertUnconfirmed(snapshot)
    }

    func testLossInLegacyAfterCurrentStartupAffectsSession() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), current = dir.appendingPathComponent("claude-events-v2.jsonl")
        let legacy = dir.appendingPathComponent("claude-events.jsonl")
        try write([loss(at: now.addingTimeInterval(-5)), start(at: now.addingTimeInterval(-3))] + observed(at: now), to: current)
        try write([loss(at: now.addingTimeInterval(-2.5))], to: legacy)
        let snapshot = try ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now)
        try assertUnconfirmed(snapshot)
    }

    func testInterruptedTwoFileCleanupCannotLoseIdentityBeforePersistingScope() throws {
        enum Interrupted: Error { case secondCommit }
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), current = dir.appendingPathComponent("claude-events-v2.jsonl")
        let legacy = dir.appendingPathComponent("claude-events.jsonl")
        let old = event(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"],
                        at: now.addingTimeInterval(-3 * 86_400))
        try write([old], to: legacy)
        try write([loss(at: now.addingTimeInterval(-4)), start(at: now.addingTimeInterval(-3))] + observed(at: now), to: current)

        // The legacy identity blocks the false fresh-start classification.
        try assertUnconfirmed(ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now))
        var commits = 0
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"),
            now: now, policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1)) { action in
                commits += 1
                if commits == 2 { throw Interrupted.secondCommit }
                try action()
            })
        XCTAssertEqual(commits, 2)
        // A new reader models a monitor restart, including loss of the latch.
        let snapshot = try ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now)
        try assertUnconfirmed(snapshot)
    }
}
