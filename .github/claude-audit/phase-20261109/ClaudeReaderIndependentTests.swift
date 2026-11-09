import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic regression cases for a macOS runner. These tests have not been
// compiled or run on the Windows research machine.
final class ClaudeReaderIndependentTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ delta: TimeInterval, _ name: String, active: Bool? = true,
                       session: String = "synthetic", task: String? = nil,
                       subject: String? = nil, status: String? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var result: [String: Any] = ["timestamp": formatter.string(from: base.addingTimeInterval(delta)),
                                     "session_id": session, "event": name]
        if let active { result["active"] = active }
        if let task { result["task_id"] = task }
        if let subject { result["task_subject"] = subject }
        if let status { result["task_status"] = status }
        if name == "Stop" { result["plan_version"] = 2; result["stop_background"] = "clear" }
        return result
    }

    private func snapshot(_ current: [[String: Any]], legacy: [[String: Any]] = [],
                          now: TimeInterval = 120, since: TimeInterval? = nil) throws -> ClaudeTaskSnapshot {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ records: [[String: Any]], to url: URL) throws {
            let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let currentFile = directory.appendingPathComponent("current.jsonl")
        let legacyFile = directory.appendingPathComponent("legacy.jsonl")
        try write(current, to: currentFile)
        try write(legacy, to: legacyFile)
        return try ClaudeTaskReader(eventFile: currentFile, legacyFile: legacyFile)
            .readSnapshot(now: base.addingTimeInterval(now),
                          observedSince: since.map { base.addingTimeInterval($0) })
    }

    func testFutureStopSuppressesTerminalAcrossTolerance() throws {
        for offset in [0.001, 1.0, 60.0, 60.001] {
            let result = try snapshot([event(0, "UserPromptSubmit"), event(offset, "Stop", active: false)], now: 0, since: 0)
            XCTAssertEqual(result.tasks.count, 1, "offset=\(offset)")
            XCTAssertEqual(result.tasks.first?.isUnconfirmed, true, "offset=\(offset)")
            XCTAssertTrue(result.terminalIDs.isEmpty, "offset=\(offset)")
            XCTAssertTrue(result.neutralEndedIDs.isEmpty, "offset=\(offset)")
            XCTAssertTrue(result.interruptedIDs.isEmpty, "offset=\(offset)")
        }
    }

    func testCurrentOrPastStopAndInterruptedTerminalIDs() throws {
        for name in ["Stop", "StopFailure", "SessionEnd"] {
            let result = try snapshot([event(-1, "UserPromptSubmit"), event(0, name, active: false)], now: 0, since: -1)
            XCTAssertTrue(result.tasks.isEmpty, name)
            if name == "Stop" {
                XCTAssertTrue(result.terminalIDs.isEmpty)
                XCTAssertTrue(result.neutralEndedIDs.contains("claude:synthetic"))
                XCTAssertTrue(result.interruptedIDs.isEmpty)
            } else {
                XCTAssertTrue(result.terminalIDs.contains("claude:synthetic"), name)
                XCTAssertTrue(result.interruptedIDs.contains("claude:synthetic"), name)
            }
        }
        let tooOld = try snapshot([event(-2, "UserPromptSubmit"), event(-1, "Stop", active: false)], now: 0, since: 0)
        XCTAssertTrue(tooOld.terminalIDs.isEmpty)
    }

    func testSameFutureStopBecomesTerminalAfterClockCatchesUp() throws {
        let records = [event(0, "UserPromptSubmit"), event(1, "Stop", active: false)]
        let before = try snapshot(records, now: 0, since: 0)
        let after = try snapshot(records, now: 1, since: 0)
        XCTAssertEqual(before.tasks.first?.isUnconfirmed, true)
        XCTAssertTrue(before.terminalIDs.isEmpty)
        XCTAssertTrue(after.tasks.isEmpty)
        XCTAssertTrue(after.terminalIDs.isEmpty)
        XCTAssertTrue(after.neutralEndedIDs.contains("claude:synthetic"))
    }

    func testNewPromptDoesNotConfirmOldPlanAndPreservesLaterSubject() throws {
        let title = "Точный 🚀 e\u{301} и \u{200B} текст"
        let result = try snapshot([
            event(0, "UserPromptSubmit"),
            event(1, "PostToolUse", task: "one", status: "completed"),
            event(2, "UserPromptSubmit"),
            event(3, "TaskCreated", task: "two", subject: title, status: "in_progress"),
            event(4, "TaskCreated", task: "one", subject: title)
        ])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(task.steps.count, 2)
        XCTAssertEqual(Array(task.steps[0].title.utf8), Array(title.utf8))
        XCTAssertEqual(Array(task.steps[1].title.utf8), Array(title.utf8))
    }

    func testFutureStopAndBackwardClockDoNotPublishTerminal() throws {
        let result = try snapshot([
            event(0, "UserPromptSubmit"), event(120, "PreToolUse"), event(59, "Stop", active: false)
        ], now: 121, since: 0)
        XCTAssertEqual(result.tasks.first?.isUnconfirmed, true)
        XCTAssertTrue(result.terminalIDs.isEmpty)
        XCTAssertTrue(result.neutralEndedIDs.isEmpty)
    }

    func testEqualTimesAndCrossFileContradiction() throws {
        let ordinary = try snapshot([event(0, "UserPromptSubmit"), event(0, "Stop", active: false)], now: 1)
        XCTAssertTrue(ordinary.tasks.isEmpty)
        XCTAssertTrue(ordinary.terminalIDs.isEmpty)
        XCTAssertTrue(ordinary.neutralEndedIDs.contains("claude:synthetic"))

        let conflict = try snapshot([event(0, "UserPromptSubmit"), event(10, "Stop", active: false)],
                                    legacy: [event(10, "PreToolUse")], now: 11, since: 0)
        XCTAssertEqual(conflict.tasks.first?.isUnconfirmed, true)
        XCTAssertTrue(conflict.terminalIDs.isEmpty)
    }

    func testSmallReversalAcrossNeutralRecord() throws {
        let result = try snapshot([event(0, "UserPromptSubmit"), event(10, "PreToolUse"),
                                   event(10, "Other", active: nil), event(9, "Stop", active: false)], now: 11)
        XCTAssertEqual(result.tasks.first?.isUnconfirmed, true)
        XCTAssertTrue(result.terminalIDs.isEmpty)
    }

    // The following assertions express desired conservative handling. Static
    // inspection predicts failures in the frozen candidate; execution is pending.
    func testRepeatedCreatedTaskDoesNotKeepPreviousCompletion() throws {
        let result = try snapshot([event(0, "UserPromptSubmit"), event(1, "TaskCreated", task: "one", subject: "Old"),
                                   event(2, "TaskCompleted", task: "one"), event(3, "TaskCreated", task: "one", subject: "New")])
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(task.steps.first?.title, "New")
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertNotEqual(task.progress, 100)
    }

    func testSmallBackwardStepChangeDoesNotConfirmPlan() throws {
        let result = try snapshot([event(0, "UserPromptSubmit"), event(1, "TaskCreated", task: "one"),
                                   event(10, "TaskCompleted", task: "one"),
                                   event(9, "PostToolUse", task: "one", status: "in_progress")], now: 11)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
    }

    func testSmallBackwardNewPromptDoesNotConfirmOldPlan() throws {
        let result = try snapshot([event(0, "UserPromptSubmit"),
                                   event(10, "TaskCreated", task: "one", subject: "Synthetic", status: "in_progress"),
                                   event(9, "UserPromptSubmit")], now: 11)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.planConfirmed, false)
        XCTAssertNil(result.tasks.first?.progress)
    }

    func testConflictingStepStatesAtEqualTimeAcrossFilesAreUnconfirmed() throws {
        let result = try snapshot([event(0, "UserPromptSubmit"),
                                   event(10, "PostToolUse", task: "one", subject: "Synthetic", status: "in_progress")],
                                  legacy: [event(10, "PostToolUse", task: "one", subject: "Synthetic", status: "completed")], now: 11)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.planConfirmed, false)
        XCTAssertNil(result.tasks.first?.progress)
    }

    func testDistinctOpaqueSessionIDsDoNotShareTerminal() throws {
        let first = "\u{00E9}"
        let second = "e\u{0301}"
        XCTAssertNotEqual(Array(first.utf8), Array(second.utf8))
        let result = try snapshot([event(0, "UserPromptSubmit", session: first),
                                   event(1, "Stop", active: false, session: second)], now: 2)
        let firstKey = try XCTUnwrap(claudeSessionKey(first))
        let secondKey = try XCTUnwrap(claudeSessionKey(second))
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.id, "claude:" + firstKey)
        XCTAssertFalse(result.terminalIDs.contains("claude:" + firstKey))
        XCTAssertTrue(result.neutralEndedIDs.contains("claude:" + secondKey))
    }

    func testSessionKeysPreserveDistinctBytesAndPlainLoopIDs() throws {
        let first = "\u{00E9}"
        let second = "e\u{0301}"
        let reserved = "~c3a9"
        XCTAssertNotEqual(claudeSessionKey(first), claudeSessionKey(second))
        XCTAssertNotEqual(claudeSessionKey(first), claudeSessionKey(reserved))
        XCTAssertEqual(claudeSessionKey("abc-123_X"), "abc-123_X")
        let result = try snapshot([event(0, "UserPromptSubmit", session: first),
                                   event(1, "UserPromptSubmit", session: second),
                                   event(2, "UserPromptSubmit", session: reserved)], now: 3)
        let firstKey = try XCTUnwrap(claudeSessionKey(first))
        let secondKey = try XCTUnwrap(claudeSessionKey(second))
        let reservedKey = try XCTUnwrap(claudeSessionKey(reserved))
        XCTAssertEqual(Set(result.tasks.map(\.id)), Set(["claude:" + firstKey, "claude:" + secondKey, "claude:" + reservedKey]))
        XCTAssertTrue(result.terminalIDs.isEmpty)
    }
}
