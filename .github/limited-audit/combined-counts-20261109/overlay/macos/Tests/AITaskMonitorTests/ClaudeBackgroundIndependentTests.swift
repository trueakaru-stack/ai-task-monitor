import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic regression case. Not compiled or executed on the Windows reviewer.
final class ClaudeBackgroundIndependentTests: XCTestCase {
    func testStopWithRunningBackgroundTaskDoesNotEraseTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-background-independent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var start = ClaudeHook.makeRecord(from: ["session_id": "synthetic", "hook_event_name": "UserPromptSubmit"])
        start["timestamp"] = formatter.string(from: now.addingTimeInterval(-2))
        var stop = ClaudeHook.makeRecord(from: ["session_id": "synthetic", "hook_event_name": "Stop",
            "background_tasks": [["id": "background-1", "type": "subagent", "status": "running",
                                   "description": "SYNTHETIC_PRIVATE_DESCRIPTION"]]])
        stop["timestamp"] = formatter.string(from: now.addingTimeInterval(-1))
        var bytes = Data()
        for event in [start, stop] { bytes.append(try JSONSerialization.data(withJSONObject: event)); bytes.append(0x0a) }
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("SYNTHETIC_PRIVATE_DESCRIPTION"))
        let file = directory.appendingPathComponent("claude-events-v2.jsonl")
        try bytes.write(to: file)
        let snapshot = try ClaudeTaskReader(eventFile: file).readSnapshot(now: now)
        XCTAssertFalse(snapshot.terminalIDs.contains("claude:synthetic"), "Running background work must not be marked terminal")
        XCTAssertTrue(snapshot.tasks.contains(where: { $0.id == "claude:synthetic" }), "The background task must remain visible")
    }
}
