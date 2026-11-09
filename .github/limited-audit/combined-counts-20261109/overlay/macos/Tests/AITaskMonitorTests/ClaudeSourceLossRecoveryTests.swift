import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic files only. These tests have not been run on macOS.
final class ClaudeSourceLossRecoveryTests: XCTestCase {
    private func record(_ input: [String: Any], at date: Date) -> [String: Any] {
        var value = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value["timestamp"] = formatter.string(from: date)
        return value
    }

    private func marker(at date: Date) -> [String: Any] {
        record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], at: date)
    }

    private func observed(at now: Date, session: String = "synthetic") -> [[String: Any]] {
        [
            record(["session_id": session, "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-2)),
            record(["session_id": session, "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                    "tool_input": ["subject": "Synthetic step"],
                    "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]], at: now.addingTimeInterval(-1.5)),
            record(["session_id": session, "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                    "tool_input": ["taskId": "step-1", "status": "completed"],
                    "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                                      "statusChange": ["from": "pending", "to": "completed"]]], at: now.addingTimeInterval(-1))
        ]
    }

    private func encode(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for value in records { data.append(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])); data.append(0x0a) }
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-source-loss-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testSeenLossRemainsLatchedWhenMarkerDisappearsDuringRun() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        try encode([marker(at: now.addingTimeInterval(-4))] + observed(at: now)).write(to: file)
        let reader = ClaudeTaskReader(eventFile: file)
        XCTAssertTrue(try reader.readSnapshot(now: now).sourceUncertain)
        // Simulate an external cleanup or older process removing the marker.
        try encode(observed(at: now)).write(to: file)
        let after = try reader.readSnapshot(now: now)
        XCTAssertTrue(after.sourceUncertain)
        XCTAssertTrue(after.tasks.first?.isUnconfirmed == true)
        XCTAssertFalse(after.tasks.first?.planConfirmed == true)
    }

    func testMarkerBeforeMalformedRecordIsLatchedEvenWhenReadThrows() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        try (encode([marker(at: now.addingTimeInterval(-4))]) + Data("not-json\n".utf8)).write(to: file)
        let reader = ClaudeTaskReader(eventFile: file)
        XCTAssertThrowsError(try reader.readSnapshot(now: now))
        try encode(observed(at: now)).write(to: file)
        let after = try reader.readSnapshot(now: now)
        XCTAssertTrue(after.sourceUncertain)
        XCTAssertFalse(after.tasks.first?.planConfirmed == true)
    }

    func testAgeAndSizeCleanupKeepOneMinimalMarkerInEachFile() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("claude-events-v2.jsonl")
        let legacy = dir.appendingPathComponent("claude-events.jsonl")
        let now = Date()
        var old = marker(at: now.addingTimeInterval(-3 * 86_400))
        old["event"] = "Unknown"; old["plan_version"] = 1; old["plan_signal"] = "uncertain"
        old["unrelated"] = "SYNTHETIC_PRIVATE_PAYLOAD"
        var partial = marker(at: now.addingTimeInterval(-2 * 86_400))
        partial["event"] = "AITMPartialTail"
        partial["unrelated"] = "SYNTHETIC_PRIVATE_PAYLOAD"
        try encode([old]).write(to: legacy)
        var data = try encode([partial])
        let filler = record(["session_id": "other", "hook_event_name": "PreToolUse", "tool_name": "Read"], at: now)
        var enlarged = filler
        enlarged["padding"] = String(repeating: "x", count: 700)
        let line = try encode([enlarged])
        for _ in 0..<1600 { data.append(line) }
        try data.write(to: current)
        try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: now,
                                  policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1))
        let currentBytes = try Data(contentsOf: current), legacyBytes = try Data(contentsOf: legacy)
        XCTAssertLessThanOrEqual(currentBytes.count + legacyBytes.count, 1_000_000)
        let newText = String(decoding: currentBytes, as: UTF8.self)
        let oldText = String(decoding: legacyBytes, as: UTF8.self)
        XCTAssertTrue(newText.contains("AITMPartialTail"))
        XCTAssertTrue(oldText.contains("AITMSourceUncertain"))
        XCTAssertTrue(newText.contains("\"scope_incomplete\":true"))
        XCTAssertTrue(oldText.contains("\"scope_incomplete\":true"))
        XCTAssertFalse(newText.contains("SYNTHETIC_PRIVATE_PAYLOAD"))
        XCTAssertFalse(oldText.contains("SYNTHETIC_PRIVATE_PAYLOAD"))
        XCTAssertTrue(newText.contains(String(repeating: "x", count: 100)))
        let restarted = try ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now, observedSince: now.addingTimeInterval(-1))
        XCTAssertTrue(restarted.sourceUncertain)
        XCTAssertFalse(restarted.tasks.first?.planConfirmed == true)
    }

    func testInvalidEmptySessionCannotBePrunedAsAnOrdinaryOldEvent() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        var invalid = marker(at: now.addingTimeInterval(-3 * 86_400))
        invalid["plan_version"] = true
        let original = try encode([invalid])
        try original.write(to: file)
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: now,
            policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1)))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testFailedSecondRetentionCommitDoesNotEraseLossMarkers() throws {
        enum SyntheticError: Error { case interrupted }
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("claude-events-v2.jsonl")
        let legacy = dir.appendingPathComponent("claude-events.jsonl")
        let now = Date()
        var old = marker(at: now.addingTimeInterval(-3 * 86_400))
        old["extra"] = "synthetic-private"
        try encode([old]).write(to: legacy)
        try encode([old]).write(to: current)
        var commits = 0
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: now,
            policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1)) { action in
                commits += 1
                if commits == 2 { throw SyntheticError.interrupted }
                try action()
            })
        XCTAssertEqual(commits, 2)
        XCTAssertTrue(String(decoding: try Data(contentsOf: legacy), as: UTF8.self).contains("AITMSourceUncertain"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: current), as: UTF8.self).contains("AITMSourceUncertain"))
        XCTAssertTrue(try ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now).sourceUncertain)
    }

    func testKnownLossDoesNotDisappearWhenOnlyMonitorRestarts() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        try encode([marker(at: now.addingTimeInterval(-4))] + observed(at: now)).write(to: file)
        let restarted = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now, observedSince: now.addingTimeInterval(-3))
        XCTAssertTrue(restarted.sourceUncertain)
        XCTAssertTrue(restarted.tasks.first?.isUnconfirmed == true)
        XCTAssertFalse(restarted.tasks.first?.planConfirmed == true)
        XCTAssertNil(restarted.tasks.first?.progress)
    }

    func testStartupAfterKnownLossDoesNotProveFreshProgress() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let old = record(["session_id": "old-session", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-5))
        let start = record(["session_id": "new-session", "hook_event_name": "SessionStart", "source": "startup"],
                           at: now.addingTimeInterval(-3))
        try encode([old, marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "new-session")).write(to: file)
        let snapshot = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now, observedSince: now.addingTimeInterval(-6))
        XCTAssertTrue(snapshot.sourceUncertain, "The old source loss remains visible")
        let oldTask = try XCTUnwrap(snapshot.tasks.first(where: { $0.id == "claude:old-session" }))
        XCTAssertTrue(oldTask.isUnconfirmed)
        let newTask = try XCTUnwrap(snapshot.tasks.first(where: { $0.id == "claude:new-session" }))
        XCTAssertTrue(newTask.isUnconfirmed, "Startup after loss does not prove a fresh scope")
        XCTAssertFalse(newTask.planConfirmed)
        XCTAssertNil(newTask.progress)
        XCTAssertNotNil(newTask.planStatusNote)
    }

    func testOnlyPreviouslyUnseenStartupCanOpenNewSessionBoundary() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        for source in ["resume", "clear", "compact", "fork", "unknown"] {
            let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": source],
                               at: now.addingTimeInterval(-3))
            try encode([marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "candidate")).write(to: file)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
            XCTAssertTrue(task.isUnconfirmed, source)
            XCTAssertFalse(task.planConfirmed, source)
            XCTAssertNil(task.progress, source)
        }
        let prior = record(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-5))
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"],
                           at: now.addingTimeInterval(-3))
        try encode([prior, marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "candidate")).write(to: file)
        let reused = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
        XCTAssertTrue(reused.isUnconfirmed)
        XCTAssertFalse(reused.planConfirmed)
    }

    func testLegacySessionIdentityCannotUseNewStartupToClearLoss() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("claude-events-v2.jsonl"), legacy = dir.appendingPathComponent("claude-events.jsonl"), now = Date()
        let prior = record(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-5))
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        try encode([prior]).write(to: legacy)
        try encode([marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "candidate")).write(to: current)
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now).tasks.first)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
    }

    func testPreviouslyAffectedSessionStaysBlockedAfterCleanupDuringRun() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let old = record(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-3 * 86_400))
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        try encode([old, marker(at: now.addingTimeInterval(-2 * 86_400)), start] + observed(at: now, session: "candidate")).write(to: file)
        let reader = ClaudeTaskReader(eventFile: file)
        XCTAssertFalse(try XCTUnwrap(reader.readSnapshot(now: now).tasks.first).planConfirmed)
        try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: now,
                                  policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1))
        let after = try XCTUnwrap(reader.readSnapshot(now: now).tasks.first)
        XCTAssertTrue(after.isUnconfirmed)
        XCTAssertFalse(after.planConfirmed)
    }

    func testPreviouslyAffectedSessionStaysBlockedAfterCleanupAndRestart() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let old = record(["session_id": "candidate", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-3 * 86_400))
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        try encode([old, marker(at: now.addingTimeInterval(-2 * 86_400)), start] + observed(at: now, session: "candidate")).write(to: file)
        let reader = ClaudeTaskReader(eventFile: file)
        XCTAssertFalse(try XCTUnwrap(reader.readSnapshot(now: now).tasks.first).planConfirmed)
        try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: now,
                                  policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1))
        let restarted = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
        XCTAssertTrue(restarted.isUnconfirmed, "Losing an old identity must not turn it into a new session")
        XCTAssertFalse(restarted.planConfirmed)
    }

    func testIncompleteIdentityScopeBlocksEvenAnUnseenStartup() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        var loss = marker(at: now.addingTimeInterval(-4))
        loss["scope_incomplete"] = true
        let start = record(["session_id": "new-session", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        try encode([loss, start] + observed(at: now, session: "new-session")).write(to: file)
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testTruncatedHistoryCannotProveFreshSessionIdentity() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        var data = Data(repeating: 0x61, count: 4_194_304)
        data.append(0x0a)
        data.append(try encode([marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "candidate")))
        try data.write(to: file)
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
    }

    func testLaterLossOrRepeatedSessionStartRevokesFreshBoundary() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let first = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup"], at: now.addingTimeInterval(-3))
        let duplicate = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "resume"], at: now.addingTimeInterval(-2.5))
        let firstLoss = marker(at: now.addingTimeInterval(-4))
        let laterLoss = marker(at: now.addingTimeInterval(-2.5))
        for records in [[firstLoss, first, duplicate], [firstLoss, first, laterLoss]] {
            try encode(records + observed(at: now, session: "candidate")).write(to: file)
            let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: now).tasks.first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.planConfirmed)
        }
    }

    func testSessionStartAloneDoesNotInventAnActiveTask() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let start = record(["session_id": "candidate", "hook_event_name": "SessionStart", "source": "startup",
                            "cwd": "/synthetic/private", "session_title": "synthetic-private"], at: now.addingTimeInterval(-1))
        let encoded = try encode([marker(at: now.addingTimeInterval(-2)), start])
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-private"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("/synthetic/private"))
        try encoded.write(to: file)
        let snapshot = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now)
        XCTAssertTrue(snapshot.sourceUncertain)
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testLateTerminalForOldSessionDoesNotCloseItOrHideFreshSession() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        let old = record(["session_id": "old-session", "hook_event_name": "UserPromptSubmit"], at: now.addingTimeInterval(-5))
        let start = record(["session_id": "new-session", "hook_event_name": "SessionStart", "source": "startup"],
                           at: now.addingTimeInterval(-3))
        let lateStop = record(["session_id": "old-session", "hook_event_name": "Stop", "background_tasks": [], "session_crons": []],
                              at: now.addingTimeInterval(-0.5))
        try encode([old, marker(at: now.addingTimeInterval(-4)), start] + observed(at: now, session: "new-session") + [lateStop]).write(to: file)
        let state = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now)
        XCTAssertTrue(state.sourceUncertain)
        XCTAssertFalse(state.terminalIDs.contains("claude:old-session"))
        XCTAssertFalse(state.neutralEndedIDs.contains("claude:old-session"))
        XCTAssertTrue(state.tasks.first(where: { $0.id == "claude:old-session" })?.isUnconfirmed == true)
        let task = try XCTUnwrap(state.tasks.first(where: { $0.id == "claude:new-session" }))
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    @MainActor
    func testNewSessionAfterLossReachesTaskStoreThroughActualHookAndSocket() throws {
        let dir = try temporaryDirectory()
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        try encode([marker(at: now.addingTimeInterval(-4))]).write(to: file)
        let journal = DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics"))
        var store: TaskStore? = TaskStore(codexReader: CodexTaskReader(codexHome: dir.appendingPathComponent("codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: file), journal: journal, claudeLoopProfile: dir)
        let socketDirectory = try ClaudeLoopSocket.directory(profile: dir, create: false)
        defer {
            store = nil
            if let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory),
               socketDirectory.hasPrefix("/private/tmp/aitm-loop-"), Set(names).isSubset(of: ["owner.lock"]) {
                _ = (socketDirectory + "/owner.lock").withCString { unlink($0) }
                _ = socketDirectory.withCString { rmdir($0) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        let inputs: [[String: Any]] = [
            ["session_id": "new-session", "hook_event_name": "SessionStart", "source": "startup"],
            ["session_id": "new-session", "hook_event_name": "UserPromptSubmit"],
            ["session_id": "new-session", "hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "create-private", "tool_input": ["subject": "Synthetic step"]],
            ["session_id": "new-session", "hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Synthetic step"],
            ["session_id": "new-session", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "create-private", "tool_input": ["subject": "Synthetic step"],
             "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]],
            ["session_id": "new-session", "hook_event_name": "PreToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "update-private", "tool_input": ["taskId": "step-1", "status": "completed"]],
            ["session_id": "new-session", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "update-private", "tool_input": ["taskId": "step-1", "status": "completed"],
             "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                               "statusChange": ["from": "pending", "to": "completed"]]]
        ]
        for input in inputs {
            XCTAssertEqual(ClaudeHook.process(input, directory: dir, retentionPolicy: { nil }), 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            store?.refresh()
            if store?.tasks.first(where: { $0.id == "claude:new-session" }) != nil { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let task = try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:new-session" }))
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertNotNil(task.planStatusNote)
        XCTAssertTrue(store?.unavailableSources.contains(.claude) == true)
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("create-private"))
        XCTAssertFalse(saved.contains("update-private"))
    }
}
