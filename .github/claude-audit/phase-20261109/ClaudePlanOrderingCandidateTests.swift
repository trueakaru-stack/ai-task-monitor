import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudePlanOrderingCandidateTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-05T15:09:00Z")!
    private let formatter = ISO8601DateFormatter()

    private func line(_ seconds: TimeInterval, _ name: String, id: String? = nil,
                      subject: String? = nil, status: String? = nil, active: Bool? = true,
                      session: String = "synthetic") throws -> String {
        var event: [String: Any] = ["session_id": session, "timestamp": formatter.string(from: start.addingTimeInterval(seconds)), "event": name]
        if let active { event["active"] = active }
        if let id { event["task_id"] = id }
        if let subject { event["task_subject"] = subject }
        if let status { event["task_status"] = status }
        return String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    private func observed(_ seconds: TimeInterval, session: String, status: String, subject: String? = nil) throws -> String {
        var event: [String: Any] = ["session_id": session, "timestamp": formatter.string(from: start.addingTimeInterval(seconds)),
                                    "event": "PostToolUse", "active": true, "plan_version": 2, "task_id": "x", "task_status": status]
        if let subject {
            event["tool_name"] = "TaskCreate"; event["plan_signal"] = "observed_create"; event["task_subject"] = subject
        } else {
            event["tool_name"] = "TaskUpdate"; event["plan_signal"] = "observed_update"; event["task_from_status"] = "pending"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), as: UTF8.self)
    }

    private func snapshot(_ current: [String], legacy: [String] = []) throws -> ClaudeTaskSnapshot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-claude-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let currentURL = dir.appendingPathComponent("current.jsonl")
        let legacyURL = dir.appendingPathComponent("legacy.jsonl")
        try (current.joined(separator: "\n") + "\n").write(to: currentURL, atomically: true, encoding: .utf8)
        try (legacy.joined(separator: "\n") + "\n").write(to: legacyURL, atomically: true, encoding: .utf8)
        return try ClaudeTaskReader(eventFile: currentURL, legacyFile: legacyURL)
            .readSnapshot(now: start.addingTimeInterval(20), observedSince: start)
    }

    private func assertPlanUnconfirmed(_ task: MonitoredTask, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(task.isActive, file: file, line: line)
        XCTAssertFalse(task.isUnconfirmed, file: file, line: line)
        XCTAssertFalse(task.planConfirmed, file: file, line: line)
        XCTAssertNil(task.progress, file: file, line: line)
        XCTAssertEqual(task.progressKind, .none, file: file, line: line)
    }

    func testSameStepBackdatedStatusDoesNotConfirmPlan() throws {
        let title = "Сохранить 🚀 e\u{301} и \u{200B}"
        let events = [
            try line(0, "UserPromptSubmit"),
            try line(1, "TaskCreated", id: "x", subject: title, status: "pending"),
            try line(10, "TaskCompleted", id: "x", subject: title, status: "completed"),
            try line(9, "PostToolUse", id: "x", subject: title, status: "in_progress")
        ]
        let result = try snapshot(events)
        let task = try XCTUnwrap(result.tasks.first)
        assertPlanUnconfirmed(task)
        XCTAssertEqual(task.steps.first?.title, title)
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertTrue(result.terminalIDs.isEmpty)
    }

    func testBackdatedPromptAfterCreatedStepDoesNotConfirmPlan() throws {
        let events = [
            try line(0, "UserPromptSubmit"),
            try line(10, "TaskCreated", id: "x", subject: "Step", status: "in_progress"),
            try line(9, "UserPromptSubmit")
        ]
        let task = try XCTUnwrap(snapshot(events).tasks.first)
        assertPlanUnconfirmed(task)
        XCTAssertEqual(task.steps.first?.title, "Step")
    }

    func testEqualTimeConflictingStepSurvivesLaterNeutralRecord() throws {
        let legacy = [try line(10, "PostToolUse", id: "x", subject: "Step", status: "completed")]
        let current = [
            try line(0, "UserPromptSubmit"),
            try line(10, "PostToolUse", id: "x", subject: "Step", status: "in_progress"),
            try line(11, "Notice", id: "x")
        ]
        let task = try XCTUnwrap(snapshot(current, legacy: legacy).tasks.first)
        assertPlanUnconfirmed(task)
        XCTAssertEqual(task.steps.first?.title, "Step")
    }

    func testBothCrossFileConflictDirectionsAndEqualTimeTitles() throws {
        let begin = try line(0, "UserPromptSubmit")
        let pending = try line(10, "PostToolUse", id: "x", subject: "A", status: "pending")
        let done = try line(10, "PostToolUse", id: "x", subject: "A", status: "completed")
        for (old, new) in [(pending, done), (done, pending)] {
            assertPlanUnconfirmed(try XCTUnwrap(snapshot([begin, new], legacy: [old]).tasks.first))
        }
        let renamed = try line(10, "PostToolUse", id: "x", subject: "B", status: "pending")
        assertPlanUnconfirmed(try XCTUnwrap(snapshot([begin, renamed], legacy: [pending]).tasks.first))
    }

    func testIdenticalLegacyDuplicatesAndOrdinaryOverlapStayUnconfirmed() throws {
        let begin = try line(0, "UserPromptSubmit")
        let created = try line(1, "TaskCreated", id: "x", subject: "Step", status: "pending")
        let updated = try line(2, "PostToolUse", id: "x", subject: "Step", status: "in_progress")
        let same = try XCTUnwrap(snapshot([begin, created, updated], legacy: [begin, created, updated]).tasks.first)
        XCTAssertTrue(same.isActive)
        XCTAssertFalse(same.planConfirmed)
        XCTAssertNil(same.progress)
        XCTAssertEqual(same.steps.first?.status, .pending)
        let overlap = try XCTUnwrap(snapshot([begin, updated], legacy: [created]).tasks.first)
        XCTAssertTrue(overlap.isActive)
        XCTAssertFalse(overlap.planConfirmed)
        XCTAssertNil(overlap.progress)
        XCTAssertEqual(overlap.steps.first?.title, "Step")
    }

    func testRepeatedOlderRecordAfterNewStateStaysUncertain() throws {
        let begin = try line(0, "UserPromptSubmit")
        let created = try line(1, "TaskCreated", id: "x", subject: "Step", status: "pending")
        let done = try line(2, "TaskCompleted", id: "x", subject: "Step", status: "completed")
        let task = try XCTUnwrap(snapshot([begin, created, done, created]).tasks.first)
        // Without an event ID this could be a duplicate or a new mutation.
        assertPlanUnconfirmed(task)
    }

    func testLegacyCompletionAndUnverifiedPostAreNotSuccessEvidence() throws {
        let begin = try line(0, "UserPromptSubmit")
        let old = try line(10, "TaskCompleted", id: "x", subject: "Step")
        let current = try line(10, "PostToolUse", id: "x", subject: "Step", status: "completed")
        let task = try XCTUnwrap(snapshot([begin, current], legacy: [old]).tasks.first)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertEqual(task.steps.first?.status, .pending)
        XCTAssertNil(task.progress)
    }

    func testDifferentStepsMayArriveOutOfTimestampOrder() throws {
        let events = [
            try line(0, "UserPromptSubmit"),
            try line(10, "TaskCreated", id: "x", subject: "One", status: "in_progress"),
            try line(9, "TaskCreated", id: "y", subject: "Two", status: "pending")
        ]
        let task = try XCTUnwrap(snapshot(events).tasks.first)
        XCTAssertTrue(task.isActive)
        XCTAssertFalse(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertEqual(Set(task.steps.map(\.title)), ["One", "Two"])
    }

    func testPromptAndStepAtSameTimeAcrossFilesAreUncertain() throws {
        let prompt = try line(10, "UserPromptSubmit")
        let step = try line(10, "TaskCreated", id: "x", subject: "Step", status: "in_progress")
        assertPlanUnconfirmed(try XCTUnwrap(snapshot([step], legacy: [prompt]).tasks.first))
        assertPlanUnconfirmed(try XCTUnwrap(snapshot([prompt], legacy: [step]).tasks.first))
    }

    func testCanonicalEquivalentTaskIdentifiersAreNotTrustedAsOne() throws {
        let events = [
            try line(0, "UserPromptSubmit"),
            try line(1, "TaskCreated", id: "e\u{301}", subject: "One", status: "pending"),
            try line(2, "TaskCompleted", id: "\u{00E9}", subject: "One", status: "completed")
        ]
        let task = try XCTUnwrap(snapshot(events).tasks.first)
        assertPlanUnconfirmed(task)
    }

    func testPlanAmbiguityIsIsolatedBySession() throws {
        let events = [
            try line(0, "UserPromptSubmit"),
            try line(10, "TaskCreated", id: "x", subject: "One", status: "pending"),
            try line(9, "PostToolUse", id: "x", subject: "One", status: "in_progress"),
            try line(0, "UserPromptSubmit", session: "other"),
            try observed(2, session: "other", status: "pending", subject: "Other"),
            try observed(3, session: "other", status: "completed")
        ]
        let tasks = try snapshot(events).tasks
        assertPlanUnconfirmed(try XCTUnwrap(tasks.first { $0.id == "claude:synthetic" }))
        let other = try XCTUnwrap(tasks.first { $0.id == "claude:other" })
        XCTAssertTrue(other.isActive)
        XCTAssertTrue(other.planConfirmed)
        XCTAssertEqual(other.progress, 100)
    }

    func testCompletedStepWithoutVisiblePromptHasNoConfirmedPlan() throws {
        let task = try XCTUnwrap(snapshot([
            line(10, "TaskCompleted", id: "old", subject: "Old step", status: "completed")
        ]).tasks.first)
        assertPlanUnconfirmed(task)
        XCTAssertEqual(task.steps.first?.title, "Old step")
        XCTAssertEqual(task.steps.first?.status, .pending)
    }

    func testLaterActivityDoesNotMaskEqualTimeConflictAcrossFiles() throws {
        let begin = try line(0, "UserPromptSubmit")
        let stop = try line(10, "Stop", active: false)
        let active = try line(10, "PreToolUse", active: true)
        let later = try line(11, "PostToolUse", active: true)
        for (old, new) in [(stop, active), (active, stop)] {
            let state = try snapshot([begin, new, later], legacy: [old])
            XCTAssertTrue(state.terminalIDs.isEmpty)
            let task = try XCTUnwrap(state.tasks.first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.isActive)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
        }
    }

    func testMatchingEqualTimeActivityAcrossFilesStaysConfirmed() throws {
        let begin = try line(0, "UserPromptSubmit")
        let same = try line(10, "PreToolUse")
        let later = try line(11, "PostToolUse")
        let task = try XCTUnwrap(snapshot([begin, same, later], legacy: [same]).tasks.first)
        XCTAssertTrue(task.isActive)
        XCTAssertFalse(task.isUnconfirmed)
    }
}
