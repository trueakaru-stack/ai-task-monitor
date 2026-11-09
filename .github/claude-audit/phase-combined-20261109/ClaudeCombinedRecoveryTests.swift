import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic-only fixtures; run through the real hook, reader, store and view model.
final class ClaudeCombinedRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-combined-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func record(_ input: [String: Any], time: Date) -> [String: Any] {
        var output = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        output["timestamp"] = formatter.string(from: time)
        return output
    }

    private func prompt(_ id: String, time: Date) -> [String: Any] {
        record(["session_id": id, "hook_event_name": "UserPromptSubmit"], time: time)
    }

    private func created(_ id: String, title: String, stage: String = "one", time: Date) -> [String: Any] {
        record(["session_id": id, "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                "tool_input": ["subject": title],
                "tool_response": ["task": ["id": stage, "subject": title]]], time: time)
    }

    private func completed(_ id: String, stage: String = "one", time: Date) -> [String: Any] {
        record(["session_id": id, "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                "tool_input": ["taskId": stage, "status": "completed"],
                "tool_response": ["success": true, "taskId": stage, "updatedFields": ["status"],
                                  "statusChange": ["from": "pending", "to": "completed"]]], time: time)
    }

    private func encode(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        return data
    }

    private func append(_ records: [[String: Any]], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encode(records))
    }

    private func loss(_ time: Date, partial: Bool = false) -> [String: Any] {
        var event = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: time)
        if partial { event["event"] = "AITMPartialTail" }
        return event
    }

    @MainActor
    func testPartialTailAndNewPromptPreserveBothPreviouslyVisibleAndNewTitles() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), time = Date().addingTimeInterval(1)
        try encode([prompt("case", time: time), created("case", title: "Old title", time: time.addingTimeInterval(0.1))]).write(to: file)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: dir.appendingPathComponent("missing-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: file),
                              journal: DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics")))
        XCTAssertEqual(store.tasks.first(where: { $0.provider == .claude })?.steps.map(\.title), ["Old title"])
        try append([loss(time.addingTimeInterval(0.2), partial: true),
                    prompt("case", time: time.addingTimeInterval(0.3)),
                    created("case", title: "New title", time: time.addingTimeInterval(0.4)),
                    completed("case", time: time.addingTimeInterval(0.5))], to: file)
        store.refresh()
        let task = try XCTUnwrap(store.tasks.first(where: { $0.id == "claude:case" }))
        XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"])
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.planConfirmed)
        XCTAssertNil(task.progress)
        XCTAssertNil(task.progressLabel)
        XCTAssertNotNil(task.planStatusNote)
        XCTAssertTrue(store.unavailableSources.contains(.claude))
    }

    @MainActor
    func testDeletionOrAtomicReplacementKeepsOldAndNewTitlesUnconfirmed() throws {
        for replaceDirectly in [false, true] {
            let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("claude-events-v2.jsonl"), time = Date().addingTimeInterval(1)
            try encode([prompt("case", time: time), created("case", title: "Old title", time: time.addingTimeInterval(0.1))]).write(to: file)
            let store = TaskStore(codexReader: CodexTaskReader(codexHome: dir.appendingPathComponent("missing-codex")),
                                  claudeReader: ClaudeTaskReader(eventFile: file),
                                  journal: DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics")))
            XCTAssertEqual(store.tasks.first(where: { $0.provider == .claude })?.steps.first?.title, "Old title")
            if !replaceDirectly {
                try FileManager.default.removeItem(at: file)
                store.refresh() // Observe absence before recreation.
            }
            let replacement = try encode([prompt("case", time: time.addingTimeInterval(0.4)),
                                          created("case", title: "New title", time: time.addingTimeInterval(0.5)),
                                          completed("case", time: time.addingTimeInterval(0.6))])
            try replacement.write(to: file, options: .atomic)
            store.refresh()
            let task = try XCTUnwrap(store.tasks.first(where: { $0.id == "claude:case" }))
            XCTAssertEqual(task.steps.map(\.title), ["Old title", "New title"], "replaceDirectly=\(replaceDirectly)")
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.planConfirmed)
            XCTAssertNil(task.progress)
            XCTAssertNil(task.progressLabel)
        }
    }

    func testKnownStatusesWithUnknownCompletenessKeepApproximateLabel() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), time = Date().addingTimeInterval(-3)
        try encode([prompt("case", time: time), created("case", title: "Known title", time: time.addingTimeInterval(0.1)),
                    completed("case", time: time.addingTimeInterval(0.2))]).write(to: file)
        let task = try XCTUnwrap(ClaudeTaskReader(eventFile: file).readSnapshot(now: Date()).tasks.first)
        XCTAssertFalse(task.isUnconfirmed)
        XCTAssertTrue(task.planConfirmed)
        XCTAssertEqual(task.progress, 100)
        XCTAssertEqual(task.progressKind, .approximate)
        XCTAssertNotNil(task.planStatusNote)
        XCTAssertNotNil(task.progressLabel)
    }

    func testNewEventAfterClearStopReopensCardWithoutNewPrompt() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), time = Date().addingTimeInterval(-3)
        let stop = record(["session_id": "case", "hook_event_name": "Stop", "background_tasks": [], "session_crons": []],
                          time: time.addingTimeInterval(0.4))
        try encode([prompt("case", time: time), created("case", title: "Title", time: time.addingTimeInterval(0.1)), stop]).write(to: file)
        let reader = ClaudeTaskReader(eventFile: file)
        let stopped = try reader.readSnapshot(now: Date())
        XCTAssertTrue(stopped.tasks.isEmpty)
        XCTAssertTrue(stopped.neutralEndedIDs.contains("claude:case"))
        let continued = record(["session_id": "case", "hook_event_name": "PreToolUse", "tool_name": "Read"],
                               time: time.addingTimeInterval(0.6))
        try append([continued], to: file)
        let next = try reader.readSnapshot(now: Date())
        XCTAssertTrue(next.tasks.contains(where: { $0.id == "claude:case" }))
        XCTAssertFalse(next.neutralEndedIDs.contains("claude:case"))
        XCTAssertFalse(next.terminalIDs.contains("claude:case"))
    }

    @MainActor
    func testForeignCodexNamespaceDoesNotCaptureClaudeInStore() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions", isDirectory: true), withIntermediateDirectories: true)
        try Data("{\"id\":\"claude:case\",\"thread_name\":\"Foreign\"}\n".utf8).write(to: home.appendingPathComponent("session_index.jsonl"))
        let claude = dir.appendingPathComponent("claude-events-v2.jsonl"), time = Date().addingTimeInterval(1)
        try encode([prompt("case", time: time), created("case", title: "Claude title", time: time.addingTimeInterval(0.1))]).write(to: claude)
        let codex = CodexTaskReader(codexHome: home)
        XCTAssertThrowsError(try codex.readSnapshot())
        let store = TaskStore(codexReader: codex, claudeReader: ClaudeTaskReader(eventFile: claude),
                              journal: DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics")))
        XCTAssertTrue(store.unavailableSources.contains(.codex))
        XCTAssertFalse(store.tasks.contains(where: { $0.provider == .codex }))
        let task = try XCTUnwrap(store.tasks.first(where: { $0.id == "claude:case" }))
        XCTAssertEqual(task.provider, .claude)
        XCTAssertEqual(task.steps.first?.title, "Claude title")
    }

    @MainActor
    func testRetainedTitleBoundSignalsOverflowAndDoesNotAlterCodex() {
        let oldSteps = (0..<4100).map { TaskStep(id: "old-\($0)", title: "Old \($0)", status: .done) }
        let old = MonitoredTask(id: "claude:case", provider: .claude, title: "Claude", activity: "", isActive: true,
                                progress: 100, progressKind: .approximate, steps: oldSteps, updatedAt: Date())
        var latest = old
        latest.steps = [TaskStep(id: "new", title: "New", status: .done)]
        latest.isUnconfirmed = true
        latest.planConfirmed = false
        latest.progress = nil
        latest.progressKind = .none
        var codex = old
        codex.provider = .codex
        let result = TaskStore.preserveUncertainClaudeTitles(previous: [old, codex], current: [latest, codex])
        XCTAssertTrue(result.overflow)
        XCTAssertEqual(result.tasks[0].steps.count, 4097)
        XCTAssertEqual(result.tasks[0].steps.last?.title, "New")
        XCTAssertNil(result.tasks[0].progress)
        XCTAssertEqual(result.tasks[1], codex)
    }

    @MainActor
    func testSessionSpecificUncertaintyLeavesCodexAndNeighborClaudeIntact() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("codex", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let codexID = "019127f4-35ae-7c73-9e72-a10123456001"
        try Data(("{\"id\":\"" + codexID + "\",\"thread_name\":\"Codex neighbor\"}\n").utf8)
            .write(to: home.appendingPathComponent("session_index.jsonl"))
        let rollout = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-" + codexID + ".jsonl")
        let time = Date().addingTimeInterval(2)
        let iso = ISO8601DateFormatter()
        let started = "{\"timestamp\":\"" + iso.string(from: time) + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn\"}}\n"
        try Data(started.utf8).write(to: rollout)
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: rollout.path)
        let file = dir.appendingPathComponent("claude-events-v2.jsonl")
        let attempt = record(["session_id": "affected", "hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
                              "tool_input": ["subject": "Unconfirmed"]], time: time.addingTimeInterval(0.1))
        try encode([prompt("affected", time: time), attempt,
                    prompt("neighbor", time: time), created("neighbor", title: "Neighbor", time: time.addingTimeInterval(0.1)),
                    completed("neighbor", time: time.addingTimeInterval(0.2))]).write(to: file)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: home), claudeReader: ClaudeTaskReader(eventFile: file),
                              journal: DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics")))
        let affected = try XCTUnwrap(store.tasks.first(where: { $0.id == "claude:affected" }))
        let neighbor = try XCTUnwrap(store.tasks.first(where: { $0.id == "claude:neighbor" }))
        let codex = try XCTUnwrap(store.tasks.first(where: { $0.provider == .codex }))
        XCTAssertFalse(affected.planConfirmed)
        XCTAssertTrue(neighbor.planConfirmed)
        XCTAssertEqual(neighbor.progress, 100)
        XCTAssertEqual(codex.id, codexID)
        XCTAssertTrue(codex.isActive)
        XCTAssertFalse(store.unavailableSources.contains(.codex))
    }

}
