import Foundation
import XCTest
@testable import AITaskMonitor

// These are synthetic hook inputs, not captured Claude responses. No real
// profile, network, service or agent is used.
final class ClaudePhaseIntegrationTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-05T15:09:00Z")!
    private let formatter = ISO8601DateFormatter()

    private func record(_ time: TimeInterval, _ payload: [String: Any]) -> [String: Any] {
        var input = payload
        if input["session_id"] == nil { input["session_id"] = "synthetic" }
        var result = ClaudeHook.makeRecord(from: input)
        result["timestamp"] = formatter.string(from: start.addingTimeInterval(time))
        return result
    }

    private func prompt(_ time: TimeInterval = 0) -> [String: Any] {
        record(time, ["hook_event_name": "UserPromptSubmit"])
    }

    private func created(_ time: TimeInterval = 1, call: String? = nil) -> [String: Any] {
        var input: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                                    "tool_input": ["subject": "Synthetic step"],
                                    "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]]
        if let call { input["tool_use_id"] = call }
        return record(time, input)
    }

    private func update(_ time: TimeInterval, call: String? = nil, event: String = "PostToolUse",
                        target: String = "step-1", returned: String = "step-1",
                        from: String = "pending", to: String = "completed",
                        success: Any = true, includeResponse: Bool = true) -> [String: Any] {
        var input: [String: Any] = ["hook_event_name": event, "tool_name": "TaskUpdate",
                                    "tool_input": ["taskId": target, "status": to]]
        if let call { input["tool_use_id"] = call }
        if includeResponse {
            input["tool_response"] = ["success": success, "taskId": returned, "updatedFields": ["status"],
                                       "statusChange": ["from": from, "to": to]]
        }
        return record(time, input)
    }

    private func snapshot(_ records: [[String: Any]], legacy: [[String: Any]]? = nil,
                          since: TimeInterval? = 0) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-phase-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("current.jsonl")
        let old = dir.appendingPathComponent("legacy.jsonl")
        func write(_ entries: [[String: Any]], to url: URL) throws {
            var bytes = Data()
            for entry in entries { bytes.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])); bytes.append(0x0a) }
            try bytes.write(to: url)
        }
        try write(records, to: current)
        if let legacy { try write(legacy, to: old) }
        return try ClaudeTaskReader(eventFile: current, legacyFile: legacy == nil ? nil : old)
            .readSnapshot(now: start.addingTimeInterval(20), observedSince: since.map { start.addingTimeInterval($0) })
    }

    private func assertUnconfirmed(_ result: ClaudeTaskSnapshot, file: StaticString = #filePath, line: UInt = #line) throws {
        let task = try XCTUnwrap(result.tasks.first, file: file, line: line)
        XCTAssertTrue(task.isActive, file: file, line: line)
        XCTAssertFalse(task.planConfirmed, file: file, line: line)
        XCTAssertNil(task.progress, file: file, line: line)
        XCTAssertEqual(task.progressKind, .none, file: file, line: line)
        XCTAssertTrue(result.terminalIDs.isEmpty, file: file, line: line)
    }

    func testValidObservedCreateAndMatchingUpdateShowObservedProgress() throws {
        let post = update(3, call: "call-1")
        let task = try XCTUnwrap(snapshot([prompt(), created(), post]).tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.steps.map(\.title), ["Synthetic step"])
        XCTAssertEqual(task.steps.first?.status, .done)
        XCTAssertEqual(task.progress, 100)
        XCTAssertEqual(task.progressKind, .approximate)
        XCTAssertNotNil(task.planStatusNote)
    }

    func testPendingOrFailedAttemptCannotLeaveConfirmedProgress() throws {
        let done = update(2)
        let pre = update(3, call: "call-2", event: "PreToolUse", from: "completed", to: "pending", includeResponse: false)
        try assertUnconfirmed(snapshot([prompt(), created(), done, pre]))
        let failure = update(4, call: "call-2", event: "PostToolUseFailure", from: "completed", to: "pending", includeResponse: false)
        try assertUnconfirmed(snapshot([prompt(), created(), done, pre, failure]))
    }

    func testMatchingFieldsCannotProveAttemptIdentityWithoutPersistedCallID() throws {
        let pre = update(2, call: "call-1", event: "PreToolUse", includeResponse: false)
        let unrelatedPost = update(3, call: "call-2")
        try assertUnconfirmed(snapshot([prompt(), created(), pre, unrelatedPost]))
        let matching = update(4, call: "call-1")
        try assertUnconfirmed(snapshot([prompt(), created(), pre, matching]))
    }

    func testSameCallWithDifferentIntentRemainsUnconfirmed() throws {
        let pre = update(2, call: "call-1", event: "PreToolUse", from: "completed", to: "pending", includeResponse: false)
        let post = update(3, call: "call-1", from: "pending", to: "completed")
        try assertUnconfirmed(snapshot([prompt(), created(), pre, post]))
        let createPre = record(1, ["hook_event_name": "PreToolUse", "tool_name": "TaskCreate", "tool_use_id": "create-call",
                                   "tool_input": ["subject": "Original title"]])
        let different = created(2, call: "create-call")
        try assertUnconfirmed(snapshot([prompt(), createPre, different]))
    }

    func testUnlinkedLifecycleHooksCannotProveCompletion() throws {
        for name in ["TaskCreated", "TaskCompleted"] {
            let hook = record(3, ["hook_event_name": name, "task_id": "step-1", "task_subject": "Synthetic step"])
            let result = try snapshot([prompt(), created(), hook])
            try assertUnconfirmed(result)
            XCTAssertNotEqual(result.tasks.first?.steps.first?.status, .done)
            XCTAssertEqual(result.tasks.first?.steps.first?.title, "Synthetic step")
        }
    }

    func testLaterValidCreateCanResolveIsolatedCreatedNotice() throws {
        let notice = record(1, ["hook_event_name": "TaskCreated", "task_id": "step-1", "task_subject": "Synthetic step"])
        let result = try snapshot([prompt(), notice, created(2)])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.steps.first?.title, "Synthetic step")
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertEqual(task.progress, 0)
    }

    func testLaterValidUpdateCanResolveIsolatedCompletedNotice() throws {
        let notice = record(2, ["hook_event_name": "TaskCompleted", "task_id": "step-1", "task_subject": "Synthetic step"])
        let result = try snapshot([prompt(), created(), notice, update(3)])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.steps.first?.status, .done)
        XCTAssertEqual(task.progress, 100)
    }

    func testUnsupportedOrContradictoryResponseDoesNotProveDone() throws {
        let cases = [update(2, includeResponse: false), update(2, returned: "other"),
                     update(2, success: false), update(2, success: 1)]
        for caseRecord in cases {
            let result = try snapshot([prompt(), created(), caseRecord])
            try assertUnconfirmed(result)
            XCTAssertNotEqual(result.tasks.first?.steps.first?.status, .done)
        }
    }

    func testConflictingTransitionsAndLegacyInputRemainUnconfirmed() throws {
        let first = update(2, from: "pending", to: "in_progress")
        let conflict = update(3, from: "pending", to: "completed")
        try assertUnconfirmed(snapshot([prompt(), created(), first, conflict]))
        var legacy = update(2)
        legacy.removeValue(forKey: "plan_version")
        legacy.removeValue(forKey: "plan_signal")
        try assertUnconfirmed(snapshot([prompt(), created(), legacy]))
        let sameTimeA = update(4, call: "call-a")
        let sameTimeB = update(4, call: "call-b")
        try assertUnconfirmed(snapshot([prompt(), created(), sameTimeA, sameTimeB]))
    }

    func testUnrelatedToolCannotUseStatusShapedInput() throws {
        let other = record(2, ["hook_event_name": "PostToolUse", "tool_name": "Read",
                               "tool_input": ["taskId": "step-1", "status": "completed"],
                               "tool_response": ["success": true, "taskId": "step-1"]])
        let task = try XCTUnwrap(snapshot([prompt(), created(), other]).tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertEqual(task.progress, 0)
    }

    func testOutOfOrderPreAndPostAndEqualTimeConflictAreUncertain() throws {
        let pre = update(3, call: "call-1", event: "PreToolUse", includeResponse: false)
        let post = update(2, call: "call-1")
        try assertUnconfirmed(snapshot([prompt(), created(), pre, post]))
        let completed = update(4, call: "one")
        let pending = update(4, call: "two", from: "completed", to: "pending")
        try assertUnconfirmed(snapshot([prompt(), created(), pending], legacy: [completed]))
    }

    func testIdenticalOverlapIsNotAContradiction() throws {
        let post = update(3, call: "same")
        let events = [prompt(), created(), post]
        let task = try XCTUnwrap(snapshot(events, legacy: events).tasks.first)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
    }

    func testMinimalRecordDoesNotPersistInputsOrResponse() throws {
        let input: [String: Any] = ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
            "tool_use_id": "call-1", "prompt": "synthetic-prompt-secret", "cwd": "/synthetic/path",
            "api_key": "synthetic-api-key", "tool_input": ["taskId": "step-1", "status": "completed", "description": "synthetic-private"],
            "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                              "statusChange": ["from": "pending", "to": "completed"], "private": "synthetic-response-secret"]]
        let result = ClaudeHook.makeRecord(from: input)
        XCTAssertEqual(result["plan_signal"] as? String, "observed_update")
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        for secret in ["synthetic-prompt-secret", "/synthetic/path", "synthetic-api-key", "synthetic-private", "synthetic-response-secret", "call-1", "plan_call_id", "tool_use_id"] {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testMixedTitleAndStatusUpdateIsNotConfirmed() throws {
        let mixed = record(2, ["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "private-call",
            "tool_input": ["taskId": "step-1", "status": "completed", "subject": "New title"],
            "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status", "subject"],
                              "statusChange": ["from": "pending", "to": "completed"]]])
        let result = try snapshot([prompt(), created(), mixed])
        try assertUnconfirmed(result)
        XCTAssertNotEqual(result.tasks.first?.steps.first?.status, .done)
        XCTAssertEqual(result.tasks.first?.steps.first?.title, "Synthetic step")
    }

    func testStoredStatusUpdateWithUnexpectedTitleCannotConfirm() throws {
        var invalid = update(2)
        invalid["task_subject"] = "Unexpected rename"
        let result = try snapshot([prompt(), created(), invalid])
        try assertUnconfirmed(result)
        XCTAssertNotEqual(result.tasks.first?.steps.first?.status, .done)
    }

    func testPartialFinalRecordIsRepairedAndHistoryMarkedUncertain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-partial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        try Data("{\"session_id\":\"synthetic\"".utf8).write(to: file)
        XCTAssertThrowsError(try ClaudeTaskReader(eventFile: file).readSnapshot())
        XCTAssertEqual(ClaudeHook.process(["session_id": "synthetic", "hook_event_name": "UserPromptSubmit"],
                                         directory: dir, retentionPolicy: { nil }, sendLoop: { _, _ in }), 0)
        let result = try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date().addingTimeInterval(1),
                                                                        observedSince: Date().addingTimeInterval(-2))
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertTrue(result.tasks.first?.isUnconfirmed == true)
        XCTAssertFalse(result.tasks.first?.planConfirmed == true)
        XCTAssertNoThrow(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: Date(),
                                                   policy: ClaudeRetentionPolicy(days: 7, maximumMB: 10)))
    }

    func testDamagedLastRecordFollowedByBlankLinesIsRepaired() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-blank-tail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        try Data("{\"session_id\":\"synthetic\"\n\n".utf8).write(to: file)
        XCTAssertThrowsError(try ClaudeTaskReader(eventFile: file).readSnapshot())
        XCTAssertEqual(ClaudeHook.process(["session_id": "synthetic", "hook_event_name": "UserPromptSubmit"],
                                         directory: dir, retentionPolicy: { nil }, sendLoop: { _, _ in }), 0)
        let result = try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date().addingTimeInterval(1),
                                                                        observedSince: Date().addingTimeInterval(-2))
        XCTAssertTrue(result.sourceUncertain)
        XCTAssertTrue(result.tasks.first?.isUnconfirmed == true)
        XCTAssertFalse(result.tasks.first?.planConfirmed == true)
        XCTAssertNoThrow(try ClaudeRetention.clean(directory: dir, backups: dir.appendingPathComponent("backups"), now: Date(),
                                                   policy: ClaudeRetentionPolicy(days: 7, maximumMB: 10)))
    }

    func testProcessWritesMinimalRecordsThatReaderConsumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs: [[String: Any]] = [
            ["session_id": "synthetic", "hook_event_name": "UserPromptSubmit", "prompt": "synthetic-prompt"],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
             "tool_input": ["subject": "Synthetic step"],
             "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"], "secret": "synthetic-response"]],
            ["session_id": "synthetic", "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
             "tool_input": ["taskId": "step-1", "status": "completed", "cwd": "/synthetic/path"],
             "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                               "statusChange": ["from": "pending", "to": "completed"]]]
        ]
        for input in inputs {
            XCTAssertEqual(ClaudeHook.process(input, directory: root, retentionPolicy: { nil }, sendLoop: { _, _ in }), 0)
        }
        let events = root.appendingPathComponent("claude-events-v2.jsonl")
        let text = try String(contentsOf: events, encoding: .utf8)
        for privateValue in ["synthetic-prompt", "synthetic-response", "/synthetic/path"] { XCTAssertFalse(text.contains(privateValue)) }
        let result = try ClaudeTaskReader(eventFile: events).readSnapshot(now: Date().addingTimeInterval(1))
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(task.steps.first?.title, "Synthetic step")
        XCTAssertEqual(task.steps.first?.status, .done)
        XCTAssertEqual(task.progress, 100)
        XCTAssertTrue(task.planConfirmed)
    }

    func testDuplicateKeysAndInvalidEscapesAreRejectedBeforeNormalization() {
        let invalid: [String] = [
            #"{"session_id":"one","session_id":"two"}"#,
            #"{"tool_response":{"success":false,"success":true}}"#,
            #"{"session_id":"one","\u0073ession_id":"two"}"#,
            #"{"session_id":"\uD800"}"#,
            #"{"session_id":"\uDC00"}"#,
            #"{"session_id":"unterminated}"#
        ]
        for text in invalid { XCTAssertNil(ClaudeJSONValidation.object(Data(text.utf8)), text) }
        let valid = #"{"session_id":"synthetic","subject":"\uD83D\uDE80", "nested":{"id":"a"}, "other":{"id":"b"}}"#
        XCTAssertNotNil(ClaudeJSONValidation.object(Data(valid.utf8)))
        let tooDeep = "{\"x\":" + String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33) + "}"
        XCTAssertNil(ClaudeJSONValidation.object(Data(tooDeep.utf8)))
    }

    func testRotationKeepsOriginalBytesAndRefusesPartialTail() {
        let tail = Data([0x61, 0x0a, 0xff, 0x0a, 0xfe, 0x0a])
        XCTAssertEqual(ClaudeHook.preservedTailBytes(tail, beginsMidFile: true), Data([0xff, 0x0a, 0xfe, 0x0a]))
        XCTAssertEqual(ClaudeHook.preservedTailBytes(tail, beginsMidFile: false), tail)
        XCTAssertNil(ClaudeHook.preservedTailBytes(Data([0x61, 0x0a, 0xff]), beginsMidFile: true))
        XCTAssertNil(ClaudeHook.preservedTailBytes(Data([0x61, 0x62, 0x63]), beginsMidFile: true))
    }

    func testStrictIdentityLengthInvalidBytesAndPartialTail() throws {
        XCTAssertNotNil(claudeSessionKey(String(repeating: "é", count: 128)))
        XCTAssertNil(claudeSessionKey(String(repeating: "é", count: 129)))
        XCTAssertNotNil(claudeSessionKey(String(repeating: "a", count: 256)))
        XCTAssertNil(claudeSessionKey(String(repeating: "a", count: 257)))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-phase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl")
        let valid = try JSONSerialization.data(withJSONObject: prompt()) + Data([0x0a])
        try (valid + Data([0xff, 0x0a])).write(to: file)
        XCTAssertThrowsError(try ClaudeTaskReader(eventFile: file).readSnapshot(now: start.addingTimeInterval(2)))
        let partial = try JSONSerialization.data(withJSONObject: created())
        try (valid + partial).write(to: file)
        XCTAssertThrowsError(try ClaudeTaskReader(eventFile: file).readSnapshot(now: start.addingTimeInterval(2)))
        try (valid + partial + Data([0x0a])).write(to: file)
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: start.addingTimeInterval(2)).tasks.first)
        XCTAssertTrue(task.planConfirmed)
    }

    func testKnownTruncationCannotProduceTerminalOrConfirmedPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-phase-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl")
        var data = Data(repeating: 0x61, count: 4_194_304)
        data.append(0x0a)
        for entry in [prompt(), created(), record(3, ["hook_event_name": "Stop"])] {
            data.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try data.write(to: file)
        let result = try ClaudeTaskReader(eventFile: file).readSnapshot(now: start.addingTimeInterval(20))
        XCTAssertTrue(result.terminalIDs.isEmpty)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testStopWithBackgroundOrMissingInformationRetainsUnconfirmedCard() throws {
        let payloads: [[String: Any]] = [
            ["hook_event_name": "Stop", "background_tasks": [["description": "synthetic-private"]]],
            ["hook_event_name": "Stop", "session_crons": [["description": "synthetic-private"]]],
            ["hook_event_name": "Stop"],
            ["hook_event_name": "Stop", "background_tasks": []]
        ]
        for payload in payloads {
            let stop = record(2, payload)
            let encoded = try JSONSerialization.data(withJSONObject: stop)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-private"))
            let result = try snapshot([prompt(), created(), stop])
            XCTAssertTrue(result.terminalIDs.isEmpty)
            XCTAssertTrue(result.neutralEndedIDs.isEmpty)
            let task = try XCTUnwrap(result.tasks.first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
        }
    }

    func testLegacyStopWithoutBackgroundInformationIsUnconfirmed() throws {
        var stop = record(2, ["hook_event_name": "Stop", "background_tasks": [], "session_crons": []])
        stop.removeValue(forKey: "plan_version")
        stop.removeValue(forKey: "stop_background")
        let result = try snapshot([prompt(), created(), stop])
        XCTAssertTrue(result.terminalIDs.isEmpty)
        XCTAssertTrue(result.neutralEndedIDs.isEmpty)
        XCTAssertTrue(result.tasks.first?.isUnconfirmed == true)
        XCTAssertFalse(result.tasks.first?.planConfirmed == true)
    }

    func testClearStopIsNeutralAndDoesNotClaimSuccess() throws {
        let stop = record(2, ["hook_event_name": "Stop", "background_tasks": [], "session_crons": []])
        let result = try snapshot([prompt(), created(), stop])
        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertTrue(result.terminalIDs.isEmpty)
        XCTAssertTrue(result.interruptedIDs.isEmpty)
        XCTAssertEqual(result.neutralEndedIDs, ["claude:synthetic"])
    }

    func testSessionEndDoesNotEraseKnownBackgroundUncertainty() throws {
        let stop = record(2, ["hook_event_name": "Stop", "background_tasks": [["id": "synthetic"]]])
        let end = record(3, ["hook_event_name": "SessionEnd"])
        let result = try snapshot([prompt(), created(), stop, end])
        XCTAssertTrue(result.terminalIDs.isEmpty)
        XCTAssertTrue(result.neutralEndedIDs.isEmpty)
        XCTAssertTrue(result.tasks.first?.isUnconfirmed == true)
    }

    @MainActor
    func testRetainedCardAfterReadErrorClearsOnlyClaudePlan() throws {
        let valid = try XCTUnwrap(snapshot([prompt(), created(), update(2)]).tasks.first)
        XCTAssertTrue(valid.planConfirmed)
        XCTAssertEqual(valid.progress, 100)
        let retained = TaskSnapshotMerger.merge(previous: [valid], current: [], terminalIDs: [])
        var otherProvider = retained[0]
        otherProvider.provider = .codex
        let clean = TaskStore.clearUnconfirmedClaudePlans(retained + [otherProvider])
        XCTAssertTrue(clean[0].isUnconfirmed)
        XCTAssertFalse(clean[0].planConfirmed)
        XCTAssertNil(clean[0].progress)
        XCTAssertEqual(clean[0].progressKind, .none)
        XCTAssertEqual(clean[1], otherProvider)
    }
}
