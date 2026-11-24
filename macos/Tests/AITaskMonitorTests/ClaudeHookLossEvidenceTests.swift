import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeHookLossEvidenceTests: XCTestCase {
    private func record(_ session: String, at date: Date) throws -> Data {
        var value = ClaudeHook.makeRecord(from: ["session_id": session, "hook_event_name": "UserPromptSubmit"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value["timestamp"] = formatter.string(from: date)
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(10)
        return data
    }

    func testFailedHookMarksOnlyItsSessionAcrossReaderRestart() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude-events-v2.jsonl"), now = Date()
        var data = try record("first", at: now.addingTimeInterval(-3))
        data.append(try record("neighbor", at: now.addingTimeInterval(-2)))
        try data.write(to: file)
        let lockPath = root.appendingPathComponent("claude-events.lock").path
        let descriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR)) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        let started = Date()
        var sentGap = false
        let result = ClaudeHook.process(["hook_event_name": "Stop", "session_id": "first",
                                         "background_tasks": [], "session_crons": []],
                                        directory: root, retentionPolicy: { nil }, sendLoop: { _, _ in },
                                        sendGap: { _ in sentGap = true })
        XCTAssertEqual(result, 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.6)
        XCTAssertFalse(sentGap, "A persisted scoped marker is enough; it must not poison unrelated sessions")
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        let hash = try XCTUnwrap(ClaudeHookLossEvidence.hash(session: "first"))
        let marker = root.appendingPathComponent("claude-loss-v1-" + hash + ".flag")
        XCTAssertEqual(try Data(contentsOf: marker).count, 0)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("\"event\":\"Stop\""))
        let scope = try ClaudeHookLossEvidence.inspect(directory: root)
        XCTAssertEqual(scope.hashes, [hash])
        XCTAssertFalse(scope.global)

        let reader = ClaudeTaskReader(eventFile: file)
        let snapshot = try reader.readSnapshot(observedSince: now.addingTimeInterval(-60))
        XCTAssertTrue(snapshot.hookLossPresent)
        XCTAssertEqual(snapshot.hookLossSessionIDs, ["claude:first"])
        XCTAssertFalse(snapshot.sourceUncertain)
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "claude:first" && $0.isUnconfirmed && !$0.isActive })
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "claude:neighbor" && $0.isActive && !$0.isUnconfirmed })

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: record("new-session", at: Date())); try handle.close()
        let restarted = try ClaudeTaskReader(eventFile: file).readSnapshot(observedSince: now.addingTimeInterval(-60))
        XCTAssertTrue(restarted.tasks.contains { $0.id == "claude:first" && $0.isUnconfirmed })
        XCTAssertTrue(restarted.tasks.contains { $0.id == "claude:new-session" && $0.isActive && !$0.isUnconfirmed })
    }

    func testFailureAfterLockIsGlobalAndDoesNotFollowJournalSymlink() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("synthetic-target")
        try Data("unchanged".utf8).write(to: target)
        let eventFile = root.appendingPathComponent("claude-events-v2.jsonl")
        try FileManager.default.createSymbolicLink(at: eventFile, withDestinationURL: target)
        let status = ClaudeHook.process(["hook_event_name": "UserPromptSubmit", "session_id": "first"],
                                        directory: root, retentionPolicy: { nil }, sendLoop: { _, _ in }, sendGap: { _ in })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        XCTAssertTrue(try ClaudeHookLossEvidence.inspect(directory: root).global)
        try FileManager.default.removeItem(at: eventFile)
        var records = try record("first", at: Date().addingTimeInterval(-3))
        records.append(try record("neighbor", at: Date().addingTimeInterval(-2)))
        try records.write(to: eventFile)
        let snapshot = try ClaudeTaskReader(eventFile: eventFile).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(snapshot.sourceUncertain)
        XCTAssertEqual(snapshot.tasks.count, 2)
        XCTAssertTrue(snapshot.tasks.allSatisfy { $0.isUnconfirmed && !$0.isActive })
    }

    func testExistingMarkerSymlinkIsNotModified() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("synthetic-target")
        try Data("unchanged".utf8).write(to: target)
        let hash = try XCTUnwrap(ClaudeHookLossEvidence.hash(session: "first"))
        let marker = root.appendingPathComponent("claude-loss-v1-" + hash + ".flag")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        XCTAssertTrue(ClaudeHookLossEvidence.record(directory: root, session: "first", global: false))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
        XCTAssertTrue(try ClaudeHookLossEvidence.inspect(directory: root).hashes.contains(hash))
    }

    func testUnknownIdentityCreatesGlobalMarkerAndBoundsAreConservative() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(ClaudeHookLossEvidence.record(directory: root, session: "", global: false))
        XCTAssertTrue(try ClaudeHookLossEvidence.inspect(directory: root).global)
        XCTAssertThrowsError(try ClaudeHookLossEvidence.inspect(directory: root.appendingPathComponent("absent")))
    }

    func testUnicodeTildeAndCaseSensitiveIDsUseTheSameDigest() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = ["é", "e\u{301}", "~leading", "Upper", "upper"]
        var data = Data()
        for session in sessions {
            let key = try XCTUnwrap(claudeSessionKey(session))
            XCTAssertEqual(ClaudeHookLossEvidence.hash(session: session), ClaudeHookLossEvidence.hash(sessionKey: key))
            data.append(try record(session, at: Date().addingTimeInterval(-2)))
        }
        XCTAssertNotEqual(ClaudeHookLossEvidence.hash(session: "Upper"), ClaudeHookLossEvidence.hash(session: "upper"))
        XCTAssertNotEqual(ClaudeHookLossEvidence.hash(session: "é"), ClaudeHookLossEvidence.hash(session: "e\u{301}"))
        XCTAssertTrue(ClaudeHookLossEvidence.record(directory: root, session: "é", global: false))
        XCTAssertTrue(ClaudeHookLossEvidence.record(directory: root, session: "~leading", global: false))
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        try data.write(to: file)
        let snapshot = try ClaudeTaskReader(eventFile: file).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        let affected = try Set(["é", "~leading"].map { "claude:" + (try XCTUnwrap(claudeSessionKey($0))) })
        XCTAssertEqual(snapshot.hookLossSessionIDs, affected)
        XCTAssertTrue(snapshot.tasks.filter { affected.contains($0.id) }.allSatisfy(\.isUnconfirmed))
        XCTAssertTrue(snapshot.tasks.filter { !affected.contains($0.id) }.allSatisfy { $0.isActive && !$0.isUnconfirmed })
        XCTAssertEqual(snapshot.tasks.count, sessions.count)
    }

    func testMarkerCapacityCreatesGlobalEvidenceWithoutRemovingEarlierMarkers() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-hook-loss-")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(directory) }
        for index in 0..<4_096 {
            let name = "claude-loss-v1-" + String(format: "%064x", index) + ".flag"
            let descriptor = name.withCString {
                openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            }
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            Darwin.close(descriptor)
        }
        let before = try ClaudeHookLossEvidence.inspect(directory: root)
        XCTAssertFalse(before.global)
        XCTAssertEqual(before.hashes.count, 4_096)
        XCTAssertTrue(ClaudeHookLossEvidence.record(directory: root, session: "additional-session", global: false))
        let after = try ClaudeHookLossEvidence.inspect(directory: root)
        XCTAssertTrue(after.global)
        XCTAssertEqual(after.hashes.count, 4_096)
    }
}
