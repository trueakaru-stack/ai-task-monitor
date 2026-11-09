import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic inputs only. The AF_UNIX test requires an isolated macOS runner.
final class ClaudePhaseChannelTests: XCTestCase {
    private let base = ISO8601DateFormatter().date(from: "2026-11-05T15:09:00Z")!
    private let key = Data(repeating: 0x7a, count: 32)

    private func record(_ seconds: TimeInterval, _ input: [String: Any]) -> [String: Any] {
        var payload = input
        if payload["session_id"] == nil { payload["session_id"] = "synthetic" }
        var result = ClaudeHook.makeRecord(from: payload)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = formatter.string(from: base.addingTimeInterval(seconds))
        return result
    }

    private func sequence() -> [[String: Any]] {
        [
            record(0, ["hook_event_name": "UserPromptSubmit"]),
            record(1, ["hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
                       "tool_use_id": "create-id", "tool_input": ["subject": "Synthetic step"]]),
            record(2, ["hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Synthetic step"]),
            record(3, ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate", "tool_use_id": "create-id",
                       "tool_input": ["subject": "Synthetic step"],
                       "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]]),
            record(4, ["hook_event_name": "PreToolUse", "tool_name": "TaskUpdate", "tool_use_id": "update-id",
                       "tool_input": ["taskId": "step-1", "status": "completed"]]),
            record(5, ["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "update-id",
                       "tool_input": ["taskId": "step-1", "status": "completed"],
                       "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                                         "statusChange": ["from": "pending", "to": "completed"]]])
        ]
    }

    private func evidence(_ records: [[String: Any]], mapping: [(Int, String)], session: String = "synthetic") -> ClaudePhaseEvidence {
        var evidence = ClaudePhaseEvidence()
        evidence.start(key: key)
        for (index, id) in mapping {
            let fingerprint = evidence.fingerprint(records[index])!
            evidence.observe(session: session, toolID: id, fingerprint: fingerprint)
        }
        return evidence
    }

    private func snapshot(_ records: [[String: Any]], evidence: ClaudePhaseEvidence, overlap: Bool = false) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-phase-channel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl"), legacy = dir.appendingPathComponent("legacy.jsonl")
        var data = Data()
        for item in records { data.append(try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])); data.append(0x0a) }
        try data.write(to: file)
        if overlap { try data.write(to: legacy) }
        return try ClaudeTaskReader(eventFile: file, legacyFile: overlap ? legacy : nil)
            .readSnapshot(now: base.addingTimeInterval(10), observedSince: base, phaseEvidence: evidence)
    }

    private var matches: [(Int, String)] { [(1, "create-id"), (3, "create-id"), (4, "update-id"), (5, "update-id")] }

    func testMatchingPreAndPostPermitObservedProgressWithCaveat() throws {
        let records = sequence()
        let result = try snapshot(records, evidence: evidence(records, mapping: matches))
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
        XCTAssertEqual(task.steps.first?.title, "Synthetic step")
        XCTAssertEqual(task.steps.first?.status, .done)
        XCTAssertNotNil(task.planStatusNote)
    }

    func testCrossFileCopiesOfSameEventsAreNotDoubleCounted() throws {
        let records = sequence()
        let result = try snapshot(records, evidence: evidence(records, mapping: matches), overlap: true)
        XCTAssertEqual(result.tasks.first?.progress, 100)
        XCTAssertTrue(result.tasks.first?.planConfirmed == true)
    }

    func testDifferentIDsWithSameFieldsDoNotCorrelate() throws {
        let records = sequence()
        let mismatched = [(1, "create-id"), (3, "different-id"), (4, "update-id"), (5, "update-id")]
        let task = try XCTUnwrap(snapshot(records, evidence: evidence(records, mapping: mismatched)).tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testMissingPreOrPostChannelFrameKeepsPlanUnconfirmed() throws {
        let records = sequence()
        for mapping in [[(3, "create-id"), (4, "update-id"), (5, "update-id")],
                        [(1, "create-id"), (4, "update-id"), (5, "update-id")]] {
            let task = try XCTUnwrap(snapshot(records, evidence: evidence(records, mapping: mapping)).tasks.first)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
        }
    }

    func testDifferentSessionCannotSupplyCorrelation() throws {
        let records = sequence()
        let task = try XCTUnwrap(snapshot(records, evidence: evidence(records, mapping: matches, session: "other")).tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testDuplicateFrameAndDuplicateRecordCannotConfirm() throws {
        let records = sequence()
        var duplicate = evidence(records, mapping: matches)
        let fingerprint = try XCTUnwrap(duplicate.fingerprint(records[1]))
        duplicate.observe(session: "synthetic", toolID: "create-id", fingerprint: fingerprint)
        XCTAssertFalse(try XCTUnwrap(snapshot(records, evidence: duplicate).tasks.first).planConfirmed)
        var repeated = records
        repeated.insert(records[1], at: 2)
        XCTAssertFalse(try XCTUnwrap(snapshot(repeated, evidence: evidence(records, mapping: matches)).tasks.first).planConfirmed)
    }

    func testGapPoisonsEvidenceEvenAfterNewKey() throws {
        let records = sequence()
        var current = evidence(records, mapping: matches)
        current.invalidate()
        current.start(key: Data(repeating: 0x55, count: 32))
        XCTAssertTrue(current.poisoned)
        let task = try XCTUnwrap(snapshot(records, evidence: current).tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testBoundedEvidenceOverflowIsFailClosed() throws {
        var current = ClaudePhaseEvidence()
        current.start(key: key)
        for index in 0...8192 {
            current.observe(session: "synthetic", toolID: "call", fingerprint: String(format: "%064d", index))
        }
        XCTAssertTrue(current.poisoned)
        let task = try XCTUnwrap(snapshot(sequence(), evidence: current).tasks.first)
        XCTAssertFalse(task.planConfirmed)
    }

    func testOnlySessionToolAndKeyedFingerprintAreSent() throws {
        let input: [String: Any] = ["session_id": "synthetic", "tool_use_id": "private-call",
                                    "prompt": "synthetic-prompt", "cwd": "/synthetic/path"]
        let record = sequence()[1]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let payload = try XCTUnwrap(ClaudeLoopClient.phasePayload(input, record: bytes, key: key))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["session", "tool", "kind", "fingerprint"])
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("synthetic-prompt"))
        XCTAssertFalse(text.contains("/synthetic/path"))
        XCTAssertFalse(text.contains("Synthetic step"))
        let persisted = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(persisted.contains("private-call"))
        XCTAssertFalse(persisted.contains("tool_use_id"))
        XCTAssertFalse(persisted.contains(object["fingerprint"] as? String ?? "MISSING"))
    }

    func testMalformedPhaseFramesAreRejected() throws {
        let invalid: [[String: Any]] = [
            ["session": "synthetic", "tool": "call", "kind": "phase", "fingerprint": "short"],
            ["session": "synthetic", "tool": "", "kind": "phase", "fingerprint": String(repeating: "a", count: 64)],
            ["session": "synthetic", "tool": "call", "kind": "phase", "fingerprint": String(repeating: "a", count: 64), "exitCode": 1],
            ["session": "synthetic", "tool": "call", "kind": "phase", "fingerprint": String(repeating: "a", count: 64), "prompt": "private"]
        ]
        for value in invalid {
            let data = try JSONSerialization.data(withJSONObject: value)
            XCTAssertNil(ClaudeLoopPayload.parse(data))
        }
        let repeated = #"{"session":"synthetic","session":"other","tool":"call","kind":"phase","fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        XCTAssertNil(ClaudeLoopPayload.parse(Data(repeated.utf8)))
    }

    @MainActor
    func testLatePhaseFrameClearsOnlyClaudeProgress() throws {
        let records = sequence()
        let claude = try XCTUnwrap(snapshot(records, evidence: evidence(records, mapping: matches)).tasks.first)
        var codex = claude
        codex.provider = .codex
        let tasks = TaskStore.clearClaudePlanConfirmations([claude, codex])
        XCTAssertFalse(tasks[0].planConfirmed)
        XCTAssertNil(tasks[0].progress)
        XCTAssertEqual(tasks[0].progressKind, .none)
        XCTAssertEqual(tasks[1], codex)
    }

    @MainActor
    func testRealHookChannelAndTaskStoreShowObservedProgress() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-store-phase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let events = dir.appendingPathComponent("claude-events-v2.jsonl")
        try Data().write(to: events)
        let journal = DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics"))
        var store: TaskStore? = TaskStore(codexReader: CodexTaskReader(codexHome: dir.appendingPathComponent("codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: events), journal: journal,
                                          claudeLoopProfile: dir)
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
            ["session_id": "synthetic", "hook_event_name": "UserPromptSubmit"],
            ["session_id": "synthetic", "hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "private-create-id", "tool_input": ["subject": "Synthetic step"]],
            ["session_id": "synthetic", "hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Synthetic step"],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "private-create-id", "tool_input": ["subject": "Synthetic step"],
             "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]],
            ["session_id": "synthetic", "hook_event_name": "PreToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "private-update-id", "tool_input": ["taskId": "step-1", "status": "completed"]],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "private-update-id", "tool_input": ["taskId": "step-1", "status": "completed"],
             "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                               "statusChange": ["from": "pending", "to": "completed"]]]
        ]
        for input in inputs {
            XCTAssertEqual(ClaudeHook.process(input, directory: dir, retentionPolicy: { nil }), 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let limit = Date().addingTimeInterval(3)
        while Date() < limit {
            store?.refresh()
            if store?.tasks.first(where: { $0.id == "claude:synthetic" })?.planConfirmed == true { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let task = try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:synthetic" }))
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
        XCTAssertNotNil(task.planStatusNote)
        let saved = try String(contentsOf: events, encoding: .utf8)
        XCTAssertFalse(saved.contains("private-create-id"))
        XCTAssertFalse(saved.contains("private-update-id"))
    }

    func testActualHookSocketAndReaderMatchWithoutPersistingToolIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-live-phase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let channel = try ClaudeLoopChannel(profile: dir)
        let socketDirectory = try ClaudeLoopSocket.directory(profile: dir, create: false)
        defer {
            _ = channel.stop()
            if let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory),
               socketDirectory.hasPrefix("/private/tmp/aitm-loop-"), Set(names).isSubset(of: ["owner.lock"]) {
                _ = (socketDirectory + "/owner.lock").withCString { unlink($0) }
                _ = socketDirectory.withCString { rmdir($0) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        var evidence = ClaudePhaseEvidence()
        evidence.start(key: try XCTUnwrap(channel.phaseKey()))
        let inputs: [[String: Any]] = [
            ["session_id": "synthetic", "hook_event_name": "UserPromptSubmit"],
            ["session_id": "synthetic", "hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "private-create-id", "tool_input": ["subject": "Synthetic step"]],
            ["session_id": "synthetic", "hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Synthetic step"],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
             "tool_use_id": "private-create-id", "tool_input": ["subject": "Synthetic step"],
             "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]],
            ["session_id": "synthetic", "hook_event_name": "PreToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "private-update-id", "tool_input": ["taskId": "step-1", "status": "completed"]],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
             "tool_use_id": "private-update-id", "tool_input": ["taskId": "step-1", "status": "completed"],
             "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                               "statusChange": ["from": "pending", "to": "completed"]]]
        ]
        let since = Date().addingTimeInterval(-1)
        for input in inputs {
            XCTAssertEqual(ClaudeHook.process(input, directory: dir, retentionPolicy: { nil }), 0)
            Thread.sleep(forTimeInterval: 0.005)
        }
        let limit = Date().addingTimeInterval(3)
        var received = 0
        while received < 4 && Date() < limit {
            let batch = channel.drain()
            XCTAssertFalse(batch.gap)
            if batch.gap { evidence.invalidate(); break }
            for event in batch.events where event.kind == .phase {
                evidence.observe(session: event.sessionID, toolID: event.toolID, fingerprint: try XCTUnwrap(event.fingerprint))
                received += 1
            }
            if received < 4 { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(received, 4)
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("private-create-id"))
        XCTAssertFalse(text.contains("private-update-id"))
        XCTAssertFalse(text.contains("tool_use_id"))
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file)
            .readSnapshot(now: Date().addingTimeInterval(1), observedSince: since, phaseEvidence: evidence).tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
        XCTAssertNotNil(task.planStatusNote)
    }
}
