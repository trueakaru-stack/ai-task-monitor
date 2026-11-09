import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeReaderSafetyCandidateTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-05T15:09:00Z")!

    private func line(_ timestamp: String, _ event: String, active: Bool?, id: String? = nil,
                      subject: String? = nil, status: String? = nil) throws -> String {
        var value: [String: Any] = ["session_id": "synthetic", "timestamp": timestamp, "event": event]
        if let active { value["active"] = active }
        if let id { value["task_id"] = id }
        if let subject { value["task_subject"] = subject }
        if let status { value["task_status"] = status }
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func snapshot(_ current: [String], legacy: [String] = [], now: Date) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-claude-reader-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let currentURL = dir.appendingPathComponent("current.jsonl")
        let legacyURL = dir.appendingPathComponent("legacy.jsonl")
        try (current.joined(separator: "\n") + "\n").write(to: currentURL, atomically: true, encoding: .utf8)
        try (legacy.joined(separator: "\n") + "\n").write(to: legacyURL, atomically: true, encoding: .utf8)
        return try ClaudeTaskReader(eventFile: currentURL, legacyFile: legacyURL).readSnapshot(now: now, observedSince: start)
    }

    func testOldPlanIsNotConfirmedForNextPrompt() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        let created = try line("2026-11-05T15:09:01Z", "TaskCreated", active: true, id: "1", subject: "Старый этап")
        let done = try line("2026-11-05T15:09:02Z", "TaskCompleted", active: true, id: "1")
        let stop = try line("2026-11-05T15:09:03Z", "Stop", active: false)
        let next = try line("2026-11-05T15:09:04Z", "UserPromptSubmit", active: true)
        for sequence in [[begin, created, done, next], [begin, created, done, stop, next]] {
            let task = try XCTUnwrap(snapshot(sequence, now: start.addingTimeInterval(5)).tasks.first)
            XCTAssertTrue(task.isActive)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
            XCTAssertEqual(task.steps.first?.title, "Старый этап")
        }
    }

    func testLaterSubjectReplacesGeneratedLabel() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        let created = try line("2026-11-05T15:09:01Z", "TaskCreated", active: true, id: "7")
        let done = try line("2026-11-05T15:09:02Z", "TaskCompleted", active: true, id: "7", subject: "Новый реальный текст")
        let task = try XCTUnwrap(snapshot([begin, created, done], now: start.addingTimeInterval(3)).tasks.first)
        XCTAssertEqual(task.steps.first?.title, "Новый реальный текст")
        XCTAssertEqual(task.steps.first?.status, .done)
    }

    func testRecreatedTaskDoesNotKeepOldCompletion() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        let created = try line("2026-11-05T15:09:01Z", "TaskCreated", active: true, id: "1", subject: "Старый")
        let done = try line("2026-11-05T15:09:02Z", "TaskCompleted", active: true, id: "1")
        let recreated = try line("2026-11-05T15:09:03Z", "TaskCreated", active: true, id: "1", subject: "Новый")
        let task = try XCTUnwrap(snapshot([begin, created, done, recreated], now: start.addingTimeInterval(4)).tasks.first)
        XCTAssertEqual(task.steps.first?.title, "Новый")
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertEqual(task.progress, 0)
    }

    func testFutureStopDoesNotBecomeATerminalUntilItsTime() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        for time in ["2026-11-05T15:09:01Z", "2026-11-05T15:10:00Z", "2026-11-06T15:09:00Z"] {
            let stop = try line(time, "Stop", active: false)
            let state = try snapshot([begin, stop], now: start)
            XCTAssertTrue(state.terminalIDs.isEmpty)
            let task = try XCTUnwrap(state.tasks.first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
        }
        let stopNow = try line("2026-11-05T15:09:01Z", "Stop", active: false)
        let ended = try snapshot([begin, stopNow], now: start.addingTimeInterval(1))
        XCTAssertTrue(ended.tasks.isEmpty)
        XCTAssertEqual(ended.terminalIDs, ["claude:synthetic"])
    }

    func testReorderedAndEqualTimeActivityDoesNotBecomeConfirmed() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        let active = try line("2026-11-05T15:09:12Z", "PreToolUse", active: true)
        let stop = try line("2026-11-05T15:09:12Z", "Stop", active: false)
        let neutral = try line("2026-11-05T15:09:15Z", "Notice", active: nil)
        let earlier = try line("2026-11-05T15:09:11Z", "PreToolUse", active: true)
        let state = try snapshot([begin, active, stop, neutral, earlier], now: start.addingTimeInterval(16))
        XCTAssertTrue(state.terminalIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(state.tasks.first).isUnconfirmed)
        let crossA = try snapshot([begin, stop], legacy: [active], now: start.addingTimeInterval(16))
        let crossB = try snapshot([begin, active], legacy: [stop], now: start.addingTimeInterval(16))
        XCTAssertTrue(crossA.terminalIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(crossA.tasks.first).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(crossB.tasks.first).isUnconfirmed)
    }

    func testOverlappingFilesAndStalenessBoundaries() throws {
        let begin = try line("2026-11-05T15:09:00Z", "UserPromptSubmit", active: true)
        let old = try line("2026-11-05T15:12:00Z", "TaskCreated", active: true, id: "a", subject: "Шаг")
        let oldLater = try line("2026-11-05T15:13:00Z", "PostToolUse", active: true)
        let currentLater = try line("2026-11-05T15:14:00Z", "PreToolUse", active: true)
        let overlap = try XCTUnwrap(snapshot([begin, currentLater], legacy: [old, oldLater], now: start.addingTimeInterval(360)).tasks.first)
        XCTAssertFalse(overlap.isUnconfirmed)
        XCTAssertTrue(overlap.planConfirmed)
        let before = try XCTUnwrap(snapshot([begin], now: start.addingTimeInterval(7_199)).tasks.first)
        let stale = try XCTUnwrap(snapshot([begin], now: start.addingTimeInterval(7_200)).tasks.first)
        XCTAssertFalse(before.isUnconfirmed)
        XCTAssertTrue(stale.isUnconfirmed)
        XCTAssertFalse(stale.planConfirmed)
    }
}
