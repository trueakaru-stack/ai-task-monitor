import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic fixtures only. These cases require native macOS XCTest.
final class ClaudeRecoveryFix5Tests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-recovery-fix5-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func event(_ input: [String: Any], at date: Date) -> [String: Any] {
        var record = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        record["timestamp"] = formatter.string(from: date)
        return record
    }

    private func loss(_ date: Date) -> [String: Any] {
        event(["session_id": "", "hook_event_name": "AITMSourceUncertain"], at: date)
    }

    private func start(_ session: String, _ date: Date) -> [String: Any] {
        event(["session_id": session, "hook_event_name": "SessionStart", "source": "startup"], at: date)
    }

    private func observed(_ session: String, _ date: Date) -> [[String: Any]] {
        [event(["session_id": session, "hook_event_name": "UserPromptSubmit"], at: date),
         event(["session_id": session, "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                "tool_input": ["subject": "Synthetic step"],
                "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]], at: date.addingTimeInterval(0.2)),
         event(["session_id": session, "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": "step-1", "status": "completed"],
                "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                                  "statusChange": ["from": "pending", "to": "completed"]]], at: date.addingTimeInterval(0.4))]
    }

    private func write(_ events: [[String: Any]], to file: URL) throws {
        var data = Data()
        for record in events {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: file)
    }

    func testEqualStartupAndLossDoNotProveOrdering() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), file = dir.appendingPathComponent("claude-events-v2.jsonl")
        let tie = now.addingTimeInterval(-5)
        try write([loss(tie), start("same-time", tie)] + observed("same-time", now.addingTimeInterval(-3)), to: file)
        let snapshot = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now)
        let task = try XCTUnwrap(snapshot.tasks.first { $0.id == "claude:same-time" })
        XCTAssertTrue(snapshot.sourceUncertain)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testLaterLegacyLossBlocksOlderSessionAndUnprovenNeighbor() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), current = dir.appendingPathComponent("claude-events-v2.jsonl")
        let legacy = dir.appendingPathComponent("claude-events.jsonl")
        let records = [loss(now.addingTimeInterval(-9)), start("older", now.addingTimeInterval(-7))] +
            observed("older", now.addingTimeInterval(-6)) + [start("neighbor", now.addingTimeInterval(-2))] +
            observed("neighbor", now.addingTimeInterval(-1.8))
        try write(records, to: current)
        try write([loss(now.addingTimeInterval(-3))], to: legacy)
        let snapshot = try ClaudeTaskReader(eventFile: current, legacyFile: legacy).readSnapshot(now: now)
        let older = try XCTUnwrap(snapshot.tasks.first { $0.id == "claude:older" })
        let neighbor = try XCTUnwrap(snapshot.tasks.first { $0.id == "claude:neighbor" })
        XCTAssertTrue(snapshot.sourceUncertain)
        XCTAssertTrue(older.isUnconfirmed)
        XCTAssertFalse(older.planConfirmed)
        XCTAssertNil(older.progress)
        XCTAssertTrue(neighbor.isUnconfirmed)
        XCTAssertFalse(neighbor.planConfirmed)
        XCTAssertNil(neighbor.progress)
        XCTAssertNotNil(neighbor.planStatusNote)
    }

    func testMarkerIsCommittedBeforeOtherJournalLosesIdentity() throws {
        enum Interrupted: Error { case secondCommit }
        for markerInLegacy in [false, true] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let now = Date(), current = dir.appendingPathComponent("claude-events-v2.jsonl")
            let legacy = dir.appendingPathComponent("claude-events.jsonl")
            let markerFile = markerInLegacy ? legacy : current
            let oldFile = markerInLegacy ? current : legacy
            let old = event(["session_id": "old-identity", "hook_event_name": "UserPromptSubmit"],
                            at: now.addingTimeInterval(-3 * 86_400))
            try write([loss(now.addingTimeInterval(-5))], to: markerFile)
            try write([old], to: oldFile)
            var commits = 0
            XCTAssertThrowsError(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"),
                now: now, policy: ClaudeRetentionPolicy(days: 1, maximumMB: 1)) { action in
                    commits += 1
                    if commits == 2 { throw Interrupted.secondCommit }
                    try action()
                })
            XCTAssertEqual(commits, 2)
            XCTAssertTrue(String(decoding: try Data(contentsOf: markerFile), as: UTF8.self).contains("\"scope_incomplete\":true"))
            XCTAssertTrue(String(decoding: try Data(contentsOf: oldFile), as: UTF8.self).contains("old-identity"))
        }
    }

    func testReaderRetriesWhenWriterHoldsJournalLock() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), file = dir.appendingPathComponent("claude-events-v2.jsonl")
        try write(observed("ordinary", now.addingTimeInterval(-2)), to: file)
        let path = dir.appendingPathComponent("claude-events.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let reader = ClaudeTaskReader(eventFile: file)
        XCTAssertThrowsError(try reader.readSnapshot(now: now)) { error in
            guard let readError = error as? ClaudeReadError, case .journalBusy = readError else {
                return XCTFail("Expected journalBusy, got \(error)")
            }
        }
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let snapshot = try reader.readSnapshot(now: now)
        let task = try XCTUnwrap(snapshot.tasks.first { $0.id == "claude:ordinary" })
        XCTAssertFalse(snapshot.sourceUncertain)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
    }

    @MainActor
    func testBusyJournalPreservesLivePhaseChannel() throws {
        let dir = try directory()
        let now = Date(), file = dir.appendingPathComponent("claude-events-v2.jsonl")
        try write(observed("neighbor", now.addingTimeInterval(-2)), to: file)
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
        func channel(_ store: TaskStore) -> ClaudeLoopChannel? {
            guard let child = Mirror(reflecting: store).children.first(where: { $0.label == "claudeLoopChannel" }) else { return nil }
            return Mirror(reflecting: child.value).children.first?.value as? ClaudeLoopChannel
        }
        let before = try XCTUnwrap(store.flatMap { channel($0) })
        let path = dir.appendingPathComponent("claude-events.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        store?.refresh()
        let during = try XCTUnwrap(store.flatMap { channel($0) })
        XCTAssertTrue(before === during, "A transient busy journal must not replace the channel or its phase key")
        XCTAssertTrue(store?.unavailableSources.contains(.claude) == true)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        store?.refresh()
        let after = try XCTUnwrap(store.flatMap { channel($0) })
        XCTAssertTrue(before === after)
    }

    func testReadLockTimingOnSyntheticJournal() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(), file = dir.appendingPathComponent("claude-events-v2.jsonl")
        let value = event(["session_id": "timing-synthetic", "hook_event_name": "UserPromptSubmit"],
                          at: now.addingTimeInterval(-2))
        try write(Array(repeating: value, count: 1600), to: file)
        let size = try Data(contentsOf: file).count
        var samples: [UInt64] = []
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { samples.append($0) })
        for _ in 0..<3 { XCTAssertFalse(try reader.readSnapshot(now: now).tasks.isEmpty) }
        XCTAssertGreaterThan(size, 100_000)
        XCTAssertEqual(samples.count, 3)
        print("AITM_FIX5_LOCK_TIMING bytes=\(size) nanoseconds=\(samples)")
    }
}
