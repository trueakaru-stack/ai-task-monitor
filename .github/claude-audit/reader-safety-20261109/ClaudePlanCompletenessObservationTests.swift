import Foundation
import XCTest
@testable import AITaskMonitor

// This only captures the current reader output for an incomplete suffix.
// It is not acceptance of the UI: the reader cannot prove plan completeness,
// and the user requires a clear label when showing progress of observed steps.
final class ClaudePlanCompletenessObservationTests: XCTestCase {
    func testPromptAndNewStepCurrentlyProduceNumericProgress() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-claude-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let lines = [
            #"{"session_id":"synthetic","timestamp":"2026-11-05T15:09:00Z","event":"UserPromptSubmit","active":true}"#,
            #"{"session_id":"synthetic","timestamp":"2026-11-05T15:09:01Z","event":"TaskCreated","active":true,"task_id":"new","task_subject":"New step","task_status":"in_progress"}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let now = ISO8601DateFormatter().date(from: "2026-11-05T15:09:02Z")!
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readTasks(now: now).first)
        // The same visible tail is possible even if an older task was omitted.
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 0)
    }
}
