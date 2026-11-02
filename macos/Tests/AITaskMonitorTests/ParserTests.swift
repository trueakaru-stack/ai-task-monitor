import XCTest
import AppKit
@testable import AITaskMonitor

final class ParserTests: XCTestCase {
    func testCodexLifecycleUsesLatestState() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        XCTAssertTrue(reader.isRunning(tail: started))
        XCTAssertFalse(reader.isRunning(tail: started + "\n" + completed))
    }

    func testCodexPlanUsesLatestPublishedPlan() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let first = record(plan: [["step": "Первый", "status": "in_progress"]])
        let second = record(plan: [
            ["step": "Первый", "status": "completed"],
            ["step": "Второй", "status": "in_progress"]
        ])
        let steps = reader.parsePlan(from: first + "\n" + second)
        XCTAssertEqual(steps.map(\.title), ["Первый", "Второй"])
        XCTAssertEqual(steps.map(\.status), [.done, .active])
        XCTAssertEqual(MonitoredTask.progress(for: steps), 50)
    }

    func testActivityUsesLatestCommentary() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let first = #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Старое действие"}}"#
        let second = #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Новое действие"}}"#
        XCTAssertEqual(reader.parseActivity(from: first + "\n" + second), "Новое действие")
    }

    func testClaudeReaderHidesStoppedAndStaleSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let now = Date()
        let active = event(session: "active", name: "UserPromptSubmit", active: true, date: now, prompt: "Активная задача")
        let stopped = event(session: "stopped", name: "SessionEnd", active: false, date: now, prompt: "Завершённая задача")
        let stale = event(session: "stale", name: "UserPromptSubmit", active: true, date: now.addingTimeInterval(-8_000), prompt: "Старая задача")
        let step: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: now), "session_id": "active",
            "event": "TaskCreated", "active": true, "task_id": "step-1",
            "task_subject": "Первый этап", "task_status": "in_progress"
        ]
        let stepLine = String(decoding: try JSONSerialization.data(withJSONObject: step), as: UTF8.self)
        try ([active, stepLine, stopped, stale].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let tasks = ClaudeTaskReader(eventFile: file).readTasks(now: now)
        XCTAssertEqual(tasks.map(\.title), ["Задача Claude Code"])
        XCTAssertEqual(tasks.first?.steps.map(\.title), ["Первый этап"])
        XCTAssertEqual(tasks.first?.steps.map(\.status), [.active])
    }

    func testClaudeHookDoesNotStorePromptOrWorkingPath() throws {
        let secret = "SYNTHETIC_ONLY_SECRET_9D42EBF6"
        let input: [String: Any] = [
            "hook_event_name": "UserPromptSubmit", "session_id": "synthetic-session",
            "prompt": secret, "cwd": "/synthetic/project"
        ]
        let record = ClaudeHook.makeRecord(from: input)
        let output = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertNil(record["prompt"])
        XCTAssertNil(record["cwd"])
        XCTAssertFalse(output.contains(secret))
        XCTAssertEqual(record["activity"] as? String, "New request")
    }

    func testProgressLabelsPreserveCertainty() {
        let base = MonitoredTask(id: "1", provider: .codex, title: "Task", activity: "", isActive: true, progress: 40, progressKind: .exact, steps: [], updatedAt: Date())
        XCTAssertEqual(base.progressLabel, "40%")
        var approximate = base
        approximate.progressKind = .approximate
        XCTAssertEqual(approximate.progressLabel, "≈40%")
        var unavailable = base
        unavailable.progress = nil
        unavailable.progressKind = .none
        XCTAssertNil(unavailable.progressLabel)
    }

    func testCursorHintPositionsRespectScreenEdges() {
        let workArea = NSRect(x: 0, y: 0, width: 400, height: 300)
        let size = NSSize(width: 160, height: 70)
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: 200, y: 150), size: size, workArea: workArea), NSPoint(x: 120, y: 154))
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: 10, y: 150), size: size, workArea: workArea), NSPoint(x: 0, y: 154))
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: 395, y: 150), size: size, workArea: workArea), NSPoint(x: 240, y: 154))
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: 200, y: 299), size: size, workArea: workArea), NSPoint(x: 120, y: 225))
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: 200, y: 2), size: size, workArea: workArea), NSPoint(x: 120, y: 6))
        let leftMonitor = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(cursorHintOrigin(pointer: NSPoint(x: -1915, y: 500), size: size, workArea: leftMonitor), NSPoint(x: -1920, y: 504))
    }

    private func record(plan: [[String: String]]) -> String {
        let input = try! JSONSerialization.data(withJSONObject: ["plan": plan])
        let inputString = String(decoding: input, as: UTF8.self)
        let record: [String: Any] = ["payload": ["type": "custom_tool_call", "name": "update_plan", "input": inputString]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }

    private func event(session: String, name: String, active: Bool, date: Date, prompt: String) -> String {
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date), "session_id": session,
            "event": name, "active": active, "prompt": prompt, "activity": name
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }
}
