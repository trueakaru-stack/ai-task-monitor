import Foundation
import XCTest
@testable import AITaskMonitor

// Adapted from the independent namespace regression to exercise a missing
// synthetic index with the current production reader. Visual QA is separate.
final class CodexSourceStalePlanTests: XCTestCase {
    @MainActor
    func testMissingIndexDoesNotLeaveConfirmedPlanOnRetainedCodexCard() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-codex-stale-plan-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let index = codex.appendingPathComponent("session_index.jsonl")
        try Data(#"{"id":"safe-session","thread_name":"Synthetic"}"#.utf8).write(to: index, options: .atomic)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(2))
        let start = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"synthetic"}}"# + "\n"
        let arguments = #"{"plan":[{"step":"Synthetic step","status":"in_progress"}]}"#
        let plan = ["type": "response_item", "payload": ["type": "function_call", "name": "update_plan", "arguments": arguments]] as [String: Any]
        let planBytes = try JSONSerialization.data(withJSONObject: plan)
        let file = sessions.appendingPathComponent("rollout-safe-session.jsonl")
        var content = Data(start.utf8)
        content.append(planBytes)
        content.append(0x0a)
        try content.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)

        let store = TaskStore(codexReader: CodexTaskReader(codexHome: codex),
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
            journal: DiagnosticJournal(directory: root.appendingPathComponent("diagnostics")))
        store.refresh()
        let original = try XCTUnwrap(store.tasks.first { $0.id == "safe-session" })
        XCTAssertTrue(original.isActive)
        XCTAssertTrue(original.planConfirmed)
        XCTAssertNotNil(original.progress)
        XCTAssertEqual(original.steps.first?.status, .active)

        try FileManager.default.removeItem(at: index)
        store.refresh()
        XCTAssertTrue(store.unavailableSources.contains(.codex))
        let retained = try XCTUnwrap(store.tasks.first { $0.id == "safe-session" })
        XCTAssertTrue(retained.isUnconfirmed)
        XCTAssertFalse(retained.isActive)
        XCTAssertFalse(retained.planConfirmed, "A retained plan is not confirmed after source loss")
        XCTAssertNil(retained.progress, "The old progress bar must not imply current progress")
    }
}
