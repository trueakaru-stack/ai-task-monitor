import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeLoopDetectionTests: XCTestCase {
    private let command = "SYNTHETIC_SECRET_COMMAND_42"
    private let directory = "/SYNTHETIC_PRIVATE_PROJECT"
    private let output = "SYNTHETIC_SECRET_OUTPUT_57"

    func testHookPayloadContainsOnlyEphemeralFingerprintAndMetadata() throws {
        let key = Data(repeating: 1, count: 32)
        let start = try XCTUnwrap(ClaudeLoopInput.classify(input(event: "PreToolUse", toolID: "tool-1")))
        let failed = try XCTUnwrap(ClaudeLoopInput.classify(input(event: "PostToolUseFailure", toolID: "tool-1")))
        let startData = try XCTUnwrap(start.payload(key: key))
        let failedData = try XCTUnwrap(failed.payload(key: key))
        let startEvent = try XCTUnwrap(ClaudeLoopPayload.parse(startData))
        let failedEvent = try XCTUnwrap(ClaudeLoopPayload.parse(failedData))
        XCTAssertEqual(startEvent.fingerprint, failedEvent.fingerprint)
        XCTAssertEqual(failedEvent.exitCode, 7)
        let payload = String(decoding: failedData, as: UTF8.self)
        for secret in [command, directory, output, "\"command\"", "\"cwd\"", "\"error\""] {
            XCTAssertFalse(payload.contains(secret))
        }
        let otherKey = try XCTUnwrap(start.payload(key: Data(repeating: 2, count: 32)))
        XCTAssertNotEqual(ClaudeLoopPayload.parse(otherKey)?.fingerprint, startEvent.fingerprint)
        XCTAssertNil(start.payload(key: Data(repeating: 0, count: 31)))
        let record = ClaudeHook.makeRecord(from: input(event: "PostToolUseFailure", toolID: "tool-1"))
        let stored = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        for secret in [command, directory, output, try XCTUnwrap(startEvent.fingerprint)] {
            XCTAssertFalse(stored.contains(secret))
        }
    }

    func testUnknownFailureInterruptionAndObservedEditsReset() throws {
        var unknown = input(event: "PostToolUseFailure", toolID: "one")
        unknown["error"] = "Shell did not start"
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .reset)
        unknown["error"] = "Exit code 1\n" + output
        unknown["is_interrupt"] = true
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .reset)
        unknown["is_interrupt"] = "false"
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .reset)
        unknown["is_interrupt"] = false
        unknown["error"] = "Exit code 0"
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .reset)
        unknown["tool_name"] = "Edit"
        unknown["hook_event_name"] = "PostToolUse"
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .edit)
        unknown["hook_event_name"] = "Stop"
        XCTAssertEqual(ClaudeLoopInput.classify(unknown)?.kind, .stop)
    }

    func testStrictInputAndWireValidation() throws {
        var invalid = input(event: "PreToolUse", toolID: "tool-1")
        invalid["session_id"] = "../bad"
        XCTAssertNil(ClaudeLoopInput.classify(invalid))
        invalid["session_id"] = "safe-session"
        invalid["tool_use_id"] = "../bad"
        XCTAssertEqual(ClaudeLoopInput.classify(invalid)?.kind, .reset)
        let key = Data(repeating: 7, count: 32)
        let prepared = try XCTUnwrap(ClaudeLoopInput.classify(input(event: "PreToolUse", toolID: "tool-1")))
        let payload = try XCTUnwrap(prepared.payload(key: key))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        json["command"] = command
        XCTAssertNil(ClaudeLoopPayload.parse(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(ClaudeLoopPayload.parse(Data(repeating: 0, count: 4097)))
        json.removeValue(forKey: "command")
        json["kind"] = "failed"
        json["exitCode"] = true
        XCTAssertNil(ClaudeLoopPayload.parse(try JSONSerialization.data(withJSONObject: json)))
    }

    func testRepeatedFailuresDismissalAndIsolation() {
        let now = Date()
        var first = ClaudeLoopTracker()
        var second = ClaudeLoopTracker()
        for index in 0..<4 { attempt(&first, id: "a-\(index)", at: now.addingTimeInterval(Double(index))) }
        XCTAssertNil(first.warning)
        attempt(&first, id: "a-4", at: now.addingTimeInterval(4))
        XCTAssertEqual(first.warning, LoopWarning(threshold: 5, windowMinutes: 10))
        XCTAssertNil(second.warning)
        first.dismiss()
        attempt(&first, id: "a-5", at: now.addingTimeInterval(5))
        XCTAssertNil(first.warning)
        first.consume(event(.edit, at: now.addingTimeInterval(6)), now: now.addingTimeInterval(6))
        for index in 0..<5 { attempt(&first, id: "b-\(index)", at: now.addingTimeInterval(Double(index + 7))) }
        XCTAssertNotNil(first.warning)
        for index in 0..<2 { attempt(&second, id: "other-\(index)", at: now.addingTimeInterval(Double(index))) }
        XCTAssertNil(second.warning)
    }

    func testDifferentCommandCodeSuccessExpiryAndSettings() {
        let now = Date()
        var tracker = ClaudeLoopTracker(threshold: 3, windowMinutes: 1)
        attempt(&tracker, id: "one", at: now)
        attempt(&tracker, id: "two", at: now.addingTimeInterval(1))
        attempt(&tracker, id: "other", fingerprint: String(repeating: "b", count: 64), at: now.addingTimeInterval(2))
        XCTAssertNil(tracker.warning)
        attempt(&tracker, id: "code", fingerprint: String(repeating: "b", count: 64), code: 8, at: now.addingTimeInterval(3))
        XCTAssertNil(tracker.warning)
        tracker.consume(event(.start, id: "success", fingerprint: String(repeating: "b", count: 64), at: now.addingTimeInterval(4)), now: now.addingTimeInterval(4))
        tracker.consume(event(.success, id: "success", fingerprint: String(repeating: "b", count: 64), at: now.addingTimeInterval(5)), now: now.addingTimeInterval(5))
        for index in 0..<3 { attempt(&tracker, id: "new-\(index)", at: now.addingTimeInterval(Double(index + 6))) }
        XCTAssertNotNil(tracker.warning)
        tracker.refresh(now: now.addingTimeInterval(100))
        XCTAssertNil(tracker.warning)
        tracker.configure(threshold: 10, windowMinutes: 30)
        XCTAssertEqual(tracker.threshold, 10)
        XCTAssertEqual(tracker.windowMinutes, 30)
    }

    func testDuplicateUnmatchedAndParallelCallsDoNotCreateAWarning() {
        let now = Date()
        var tracker = ClaudeLoopTracker(threshold: 3)
        attempt(&tracker, id: "duplicate", at: now)
        tracker.consume(event(.failed, id: "duplicate", at: now), now: now)
        tracker.consume(event(.failed, id: "unmatched", at: now), now: now)
        tracker.consume(event(.start, id: "a", at: now), now: now)
        tracker.consume(event(.start, id: "b", at: now), now: now)
        tracker.consume(event(.failed, id: "a", at: now), now: now)
        tracker.consume(event(.failed, id: "b", at: now), now: now)
        attempt(&tracker, id: "after", at: now)
        XCTAssertNil(tracker.warning)
        attempt(&tracker, id: "after-2", at: now)
        XCTAssertNil(tracker.warning)
        attempt(&tracker, id: "after-3", at: now)
        XCTAssertNotNil(tracker.warning)
    }

    func testResetOutOfOrderAndEditDuringCommand() {
        let now = Date()
        var tracker = ClaudeLoopTracker(threshold: 3)
        attempt(&tracker, id: "one", at: now)
        attempt(&tracker, id: "two", at: now.addingTimeInterval(1))
        tracker.consume(event(.reset, at: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
        attempt(&tracker, id: "after-reset", at: now.addingTimeInterval(3))
        XCTAssertNil(tracker.warning)
        tracker.consume(event(.start, id: "old", at: now), now: now.addingTimeInterval(4))
        attempt(&tracker, id: "after-old", at: now.addingTimeInterval(5))
        XCTAssertNil(tracker.warning)
        tracker.consume(event(.start, id: "editing", at: now.addingTimeInterval(6)), now: now.addingTimeInterval(6))
        tracker.consume(event(.edit, at: now.addingTimeInterval(7)), now: now.addingTimeInterval(7))
        tracker.consume(event(.failed, id: "editing", at: now.addingTimeInterval(8)), now: now.addingTimeInterval(8))
        XCTAssertNil(tracker.warning)
    }

    private func input(event: String, toolID: String) -> [String: Any] {
        ["session_id": "session-one", "hook_event_name": event, "tool_name": "Bash", "tool_use_id": toolID,
         "cwd": directory, "tool_input": ["command": command], "is_interrupt": false, "error": "Exit code 7\n" + output]
    }

    private func event(_ kind: ClaudeLoopEvent.Kind, id: String = "", fingerprint: String = String(repeating: "a", count: 64),
                       code: Int32 = 7, at time: Date) -> ClaudeLoopEvent {
        ClaudeLoopEvent(sessionID: "session-one", toolID: id, kind: kind, fingerprint: fingerprint, exitCode: code, time: time)
    }

    private func attempt(_ tracker: inout ClaudeLoopTracker, id: String,
                         fingerprint: String = String(repeating: "a", count: 64), code: Int32 = 7, at time: Date) {
        tracker.consume(event(.start, id: id, fingerprint: fingerprint, at: time), now: time)
        tracker.consume(event(.failed, id: id, fingerprint: fingerprint, code: code, at: time), now: time)
    }
}
