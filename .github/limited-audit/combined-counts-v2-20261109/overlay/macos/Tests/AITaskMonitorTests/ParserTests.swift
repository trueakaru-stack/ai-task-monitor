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

    func testCodexInterruptedTurnAndNewerTurnAreDistinguished() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let started = #"{ "payload": { "turn_id": "new-turn", "type": "turn_started" }, "type": "event_msg" }"#
        let oldAbort = #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"old-turn"}}"#
        let currentAbort = #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"new-turn"}}"#
        let nextStart = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"next-turn"}}"#
        XCTAssertTrue(reader.isRunning(tail: started + "\n" + oldAbort))
        XCTAssertFalse(reader.isRunning(tail: started + "\n" + oldAbort + "\n" + currentAbort))
        XCTAssertTrue(reader.isRunning(tail: started + "\n" + currentAbort + "\n" + nextStart))
    }

    func testCodexRequiresAnEventAfterMonitorStartForTheCurrentTurn() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let since = ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z")!
        let oldStart = #"{"timestamp":"2026-11-02T09:59:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"one"}}"#
        let newEvent = #"{"timestamp":"2026-11-02T10:00:01Z","type":"event_msg","payload":{"type":"agent_reasoning","turn_id":"one"}}"#
        let previousTurnEvent = #"{"timestamp":"2026-11-02T10:00:02Z","type":"event_msg","payload":{"type":"agent_reasoning","turn_id":"other"}}"#
        let completed = #"{"timestamp":"2026-11-02T10:00:03Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"one"}}"#
        let anotherOldStart = #"{"timestamp":"2026-11-02T09:58:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"two"}}"#
        XCTAssertFalse(reader.isRunning(tail: oldStart, observedSince: since))
        XCTAssertFalse(reader.isRunning(tail: oldStart + "\n" + previousTurnEvent, observedSince: since))
        XCTAssertTrue(reader.isRunning(tail: oldStart + "\n" + newEvent, observedSince: since))
        XCTAssertFalse(reader.isRunning(tail: oldStart + "\n" + newEvent + "\n" + completed, observedSince: since))
        XCTAssertFalse(reader.isRunning(tail: oldStart + "\n" + newEvent + "\n" + completed + "\n" + anotherOldStart, observedSince: since))
    }

    func testCodexReaderFiltersQuietPreexistingSessions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("session_index.jsonl")
        let session = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456001.jsonl")
        try #"{"id":"019127f4-35ae-7c73-9e72-a10123456001","thread_name":"Synthetic task"}"#.write(to: index, atomically: true, encoding: .utf8)
        let now = Date()
        let since = now.addingTimeInterval(-2)
        let formatter = ISO8601DateFormatter()
        let oldStart = #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(-20)))","type":"event_msg","payload":{"type":"task_started"}}"#
        let newEvent = #"{"timestamp":"\#(formatter.string(from: now))","type":"event_msg","payload":{"type":"agent_reasoning","text":"Synthetic event"}}"#
        try (oldStart + "\n").write(to: session, atomically: true, encoding: .utf8)
        let reader = CodexTaskReader(codexHome: directory)
        XCTAssertTrue(reader.readTasks(now: now, observedSince: since).isEmpty)
        try (oldStart + "\n" + newEvent + "\n").write(to: session, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.readTasks(now: now, observedSince: since).map(\.title), ["Synthetic task"])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20)], ofItemAtPath: session.path)
        XCTAssertTrue(reader.readTasks(now: now, observedSince: since).isEmpty)
        XCTAssertEqual(try reader.readSnapshot(now: now, observedSince: since, previouslyObserved: ["019127f4-35ae-7c73-9e72-a10123456001"]).tasks.count, 1)
        let terminal = #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_complete"}}"#
        try (oldStart + "\n" + newEvent + "\n" + terminal + "\n").write(to: session, atomically: true, encoding: .utf8)
        let snapshot = try reader.readSnapshot(now: now, observedSince: since)
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertTrue(snapshot.terminalIDs.contains("019127f4-35ae-7c73-9e72-a10123456001"))
    }

    func testCodexReaderKeepsObservedQuietTaskAsUnconfirmed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = directory.appendingPathComponent("session_index.jsonl")
        let session = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456001.jsonl")
        let now = Date()
        let eventTime = now.addingTimeInterval(-8_000)
        let formatter = ISO8601DateFormatter()
        let start = #"{"timestamp":"\#(formatter.string(from: eventTime))","type":"event_msg","payload":{"type":"task_started"}}"#
        try #"{"id":"019127f4-35ae-7c73-9e72-a10123456001","thread_name":"Synthetic task"}"#.write(to: index, atomically: true, encoding: .utf8)
        try (start + "\n").write(to: session, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: eventTime], ofItemAtPath: session.path)
        let reader = CodexTaskReader(codexHome: directory)
        let task = try XCTUnwrap(reader.readTasks(now: now, observedSince: now.addingTimeInterval(-9_000)).first)
        XCTAssertFalse(task.isActive)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertEqual(task.activity, tr("Статус не подтверждён", "Status unconfirmed"))
        XCTAssertTrue(reader.readTasks(now: now, observedSince: now.addingTimeInterval(-1)).isEmpty)
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

    func testCodexPlanSupportsFunctionCallLegacyAndClearing() throws {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let json = try JSONSerialization.data(withJSONObject: ["plan": [["step": "JSON step", "status": "completed"]]])
        let direct: [String: Any] = ["payload": ["type": "function_call", "name": "update_plan", "arguments": String(decoding: json, as: UTF8.self)]]
        let directLine = String(decoding: try JSONSerialization.data(withJSONObject: direct), as: UTF8.self)
        XCTAssertEqual(reader.parsePlan(from: directLine).map(\.status), [.done])
        let legacy: [String: Any] = ["payload": ["type": "custom_tool_call", "name": "functions.exec", "input": #"await tools.update_plan({plan:[{step: "Legacy step", status: "pending"}]})"#]]
        let legacyLine = String(decoding: try JSONSerialization.data(withJSONObject: legacy), as: UTF8.self)
        XCTAssertEqual(reader.parsePlan(from: directLine + "\n" + legacyLine).map(\.title), ["Legacy step"])
        let empty: [String: Any] = ["payload": ["type": "function_call", "name": "update_plan", "arguments": #"{"plan":[]}"#]]
        let emptyLine = String(decoding: try JSONSerialization.data(withJSONObject: empty), as: UTF8.self)
        XCTAssertTrue(reader.parsePlan(from: legacyLine + "\n" + emptyLine).isEmpty)
    }

    func testActivityUsesLatestCommentary() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let first = #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Старое действие"}}"#
        let second = #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Новое действие"}}"#
        XCTAssertEqual(reader.parseActivity(from: first + "\n" + second), "Новое действие")
    }

    func testActivityReadsCurrentSummaryWithoutExposingRawReasoning() {
        let reader = CodexTaskReader(codexHome: URL(fileURLWithPath: "/tmp/unused"))
        let old = #"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"Old action"}}"#
        let response = #"{"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"**Checking screenshot stability**\n\nPRIVATE_REASONING"}],"content":[{"text":"PRIVATE_RAW_CONTENT"}]}}"#
        let completed = #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning","summary_text":["**Check build**"]}}}"#
        let commentary = #"{"type":"response_item","payload":{"type":"message","phase":"commentary","content":[{"type":"output_text","text":"Preparing check"}]}}"#
        let start = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"new-turn"}}"#
        XCTAssertEqual(reader.parseActivity(from: old + "\n" + response), "Checking screenshot stability")
        XCTAssertEqual(reader.parseActivity(from: response + "\n" + completed), "Check build")
        XCTAssertEqual(reader.parseActivity(from: response + "\n" + commentary), "Checking screenshot stability")
        XCTAssertEqual(reader.parseActivity(from: response + "\n" + start), "")
        XCTAssertEqual(reader.parseActivity(from: response + "\n" + start + "\n" + commentary), "Preparing check")
        let rawOnly = #"{"type":"response_item","payload":{"type":"reasoning","summary":[],"content":[{"text":"PRIVATE_RAW_CONTENT"}]}}"#
        XCTAssertEqual(reader.parseActivity(from: rawOnly), "")
    }

    func testClaudeStartIdentityChangesOnlyForANewPrompt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("events.jsonl")
        let now = Date()
        let first = event(session: "one", name: "UserPromptSubmit", active: true, date: now.addingTimeInterval(-5), prompt: "")
        let action = event(session: "one", name: "PreToolUse", active: true, date: now.addingTimeInterval(-4), prompt: "")
        let next = event(session: "one", name: "UserPromptSubmit", active: true, date: now.addingTimeInterval(-3), prompt: "")
        let reader = ClaudeTaskReader(eventFile: file)
        try (first + "\n").write(to: file, atomically: true, encoding: .utf8)
        let initial = try XCTUnwrap(reader.readTasks(now: now).first)
        try ([first, action].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let updated = try XCTUnwrap(reader.readTasks(now: now).first)
        XCTAssertFalse(initial.startKey.isEmpty)
        XCTAssertEqual(initial.startKey, updated.startKey)
        try ([first, action, next].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let resumed = try XCTUnwrap(reader.readTasks(now: now).first)
        XCTAssertNotEqual(resumed.startKey, initial.startKey)
        XCTAssertGreaterThan(resumed.startedAt, initial.startedAt)
    }

    func testClaudeReaderHidesStoppedAndMarksObservedQuietSessionsUnconfirmed() throws {
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
        XCTAssertEqual(tasks.count, 2)
        let activeTask = try XCTUnwrap(tasks.first { $0.id == "claude:active" })
        let quietTask = try XCTUnwrap(tasks.first { $0.id == "claude:stale" })
        XCTAssertEqual(activeTask.title, tr("Задача Claude Code", "Claude Code task"))
        XCTAssertEqual(activeTask.steps.map(\.title), ["Первый этап"])
        XCTAssertEqual(activeTask.steps.map(\.status), [.pending])
        XCTAssertFalse(activeTask.planConfirmed)
        XCTAssertNil(activeTask.progress)
        XCTAssertFalse(quietTask.isActive)
        XCTAssertTrue(quietTask.isUnconfirmed)
        XCTAssertEqual(quietTask.activity, tr("Статус не подтверждён", "Status unconfirmed"))
        XCTAssertEqual(ClaudeTaskReader(eventFile: file).readTasks(now: now, observedSince: now.addingTimeInterval(-100)).map(\.id), ["claude:active"])
    }

    func testLegacyClaudeSessionsRequireANewEventAndPreservePlan() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyFile = directory.appendingPathComponent("legacy.jsonl")
        let currentFile = directory.appendingPathComponent("current.jsonl")
        let now = Date()
        let old: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-10)),
            "session_id": "legacy-session", "event": "TaskCreated", "active": true,
            "task_id": "step-1", "task_subject": "Synthetic plan step", "task_status": "in_progress",
            "prompt": "SYNTHETIC_SECRET"
        ]
        let oldLine = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        try (oldLine + "\n").write(to: legacyFile, atomically: true, encoding: .utf8)
        let unrelated = event(session: "other-session", name: "UserPromptSubmit", active: true, date: now.addingTimeInterval(-5), prompt: "")
        try (unrelated + "\n").write(to: currentFile, atomically: true, encoding: .utf8)
        let reader = ClaudeTaskReader(eventFile: currentFile, legacyFile: legacyFile)
        XCTAssertEqual(reader.readTasks(now: now).map(\.id), ["claude:other-session"])
        XCTAssertTrue(reader.readTasks(now: now, observedSince: now.addingTimeInterval(1)).isEmpty)
        let observed = event(session: "legacy-session", name: "PreToolUse", active: true, date: now, prompt: "")
        try ([unrelated, observed].joined(separator: "\n") + "\n").write(to: currentFile, atomically: true, encoding: .utf8)
        let fresh = reader.readTasks(now: now, observedSince: now.addingTimeInterval(-1))
        XCTAssertEqual(fresh.map(\.id), ["claude:legacy-session"])
        let resumed = try XCTUnwrap(fresh.first)
        XCTAssertEqual(resumed.steps.map(\.title), ["Synthetic plan step"])
        XCTAssertFalse(resumed.activity.contains("SYNTHETIC_SECRET"))
        XCTAssertEqual(try String(contentsOf: legacyFile, encoding: .utf8), oldLine + "\n")
        let stopped = event(session: "legacy-session", name: "Stop", active: false, date: now.addingTimeInterval(1), prompt: "")
        try ([unrelated, observed, stopped].joined(separator: "\n") + "\n").write(to: currentFile, atomically: true, encoding: .utf8)
        let futureSnapshot = try reader.readSnapshot(now: now, observedSince: now.addingTimeInterval(-1))
        XCTAssertFalse(futureSnapshot.terminalIDs.contains("claude:legacy-session"))
        XCTAssertFalse(futureSnapshot.neutralEndedIDs.contains("claude:legacy-session"))
        XCTAssertTrue(futureSnapshot.tasks.contains { $0.id == "claude:legacy-session" && $0.isUnconfirmed })
        let stoppedSnapshot = try reader.readSnapshot(now: now.addingTimeInterval(2), observedSince: now.addingTimeInterval(-1))
        XCTAssertTrue(stoppedSnapshot.terminalIDs.isEmpty)
        XCTAssertFalse(stoppedSnapshot.neutralEndedIDs.contains("claude:legacy-session"))
        XCTAssertTrue(stoppedSnapshot.tasks.contains { $0.id == "claude:legacy-session" && $0.isUnconfirmed })
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

    func testClaudeHookBoundsInputWhileReading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.json")
        try Data(repeating: 0x61, count: 16).write(to: file)
        let withinLimit = try FileHandle(forReadingFrom: file)
        XCTAssertEqual(ClaudeHook.readBoundedInput(withinLimit, maximumBytes: 16)?.count, 16)
        try withinLimit.close()
        try Data(repeating: 0x61, count: 17).write(to: file)
        let overLimit = try FileHandle(forReadingFrom: file)
        XCTAssertNil(ClaudeHook.readBoundedInput(overLimit, maximumBytes: 16))
        try overLimit.close()
    }

    func testClaudeIntegrationQuotesPathAndRecognizesOnlyItsOwnCommand() {
        let path = "/tmp/John's $(echo marker)/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"
        let expected = "'/tmp/John'\\''s $(echo marker)/AI Task Monitor.app/Contents/MacOS/AITaskMonitor' --claude-hook"
        XCTAssertEqual(ClaudeIntegration.hookCommand(for: path), expected)
        XCTAssertTrue(ClaudeIntegration.isOwnedHook(["type": "command", "command": expected], executable: path))
        let legacy = "\"\(path)\" --claude-hook"
        XCTAssertTrue(ClaudeIntegration.isOwnedHook(["type": "command", "command": legacy], executable: path))
        XCTAssertFalse(ClaudeIntegration.isOwnedHook(["type": "command", "command": expected + " --other-hook"], executable: path))
        XCTAssertFalse(ClaudeIntegration.isOwnedHook(["type": "command", "command": expected, "args": ["--other-hook"]], executable: path))
        XCTAssertFalse(ClaudeIntegration.isOwnedHook(["type": "command", "command": expected, "shell": "powershell"], executable: path))
        XCTAssertFalse(ClaudeIntegration.isOwnedHook(["type": "prompt", "command": expected], executable: path))
        let unrelated = "'/tmp/other/AI Task Monitor.app/Contents/MacOS/AITaskMonitor' --claude-hook"
        XCTAssertFalse(ClaudeIntegration.isOwnedHook(["type": "command", "command": unrelated], executable: path))
    }

    func testClaudeConnectionDistinguishesDisconnectedAndInvalidSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = directory.appendingPathComponent("settings.json")
        XCTAssertEqual(try ClaudeIntegration.connectionState(settingsURL: settings), .disconnected)
        try Data("{}".utf8).write(to: settings)
        XCTAssertEqual(try ClaudeIntegration.connectionState(settingsURL: settings), .disconnected)
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let hook: [String: Any] = ["type": "command", "command": ClaudeIntegration.hookCommand(for: executable)]
        let object: [String: Any] = ["hooks": ["PreToolUse": [["hooks": [hook]]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
        XCTAssertEqual(try ClaudeIntegration.connectionState(settingsURL: settings), .partial)
        let allHooks = Dictionary(uniqueKeysWithValues: ClaudeIntegration.events.map { ($0, [["hooks": [hook]]]) })
        try JSONSerialization.data(withJSONObject: ["hooks": allHooks]).write(to: settings)
        XCTAssertEqual(try ClaudeIntegration.connectionState(settingsURL: settings), .connected)
        try Data("[]".utf8).write(to: settings)
        XCTAssertThrowsError(try ClaudeIntegration.connectionState(settingsURL: settings))
    }

    func testProgressLabelsPreserveCertainty() {
        let oldLanguage = AppLanguage.previewOverride
        defer { AppLanguage.previewOverride = oldLanguage }
        AppLanguage.previewOverride = .ru
        let base = MonitoredTask(id: "1", provider: .codex, title: "Task", activity: "", isActive: true, progress: 40, progressKind: .exact, steps: [], updatedAt: Date())
        XCTAssertEqual(base.progressLabel, "40%")
        var planned = base
        planned.steps = [TaskStep(title: "Done", status: .done), TaskStep(title: "Current", status: .active), TaskStep(title: "Next", status: .pending)]
        XCTAssertEqual(planned.progressLabel, "Этап 2 из 3")
        AppLanguage.previewOverride = .en
        XCTAssertEqual(planned.progressLabel, "Step 2 of 3")
        var overallWithPlan = planned
        overallWithPlan.progressBasis = .task
        XCTAssertEqual(overallWithPlan.progressLabel, "40%")
        var ambiguous = planned
        ambiguous.steps[2].status = .active
        XCTAssertEqual(ambiguous.progressLabel, "Done 1 of 3")
        ambiguous.steps[1].status = .pending
        ambiguous.steps[2].status = .pending
        XCTAssertEqual(ambiguous.progressLabel, "Done 1 of 3")
        ambiguous.steps = ambiguous.steps.map { TaskStep(title: $0.title, status: .done) }
        XCTAssertEqual(ambiguous.progressLabel, "Done 3 of 3")
        var stale = planned
        stale.planConfirmed = false
        XCTAssertNil(stale.progressLabel)
        stale.planConfirmed = true
        stale.isUnconfirmed = true
        XCTAssertNil(stale.progressLabel)
        var approximate = base
        approximate.progressKind = .approximate
        XCTAssertEqual(approximate.progressLabel, "≈40%")
        var unavailable = base
        unavailable.progress = nil
        unavailable.progressKind = .none
        XCTAssertNil(unavailable.progressLabel)
    }

    @MainActor
    func testPreviewPercentageMatchesItsSyntheticPlan() throws {
        let task = try XCTUnwrap(TaskStore.preview().tasks.first { !$0.steps.isEmpty })
        XCTAssertEqual(task.progress, MonitoredTask.progress(for: task.steps))
    }

    @MainActor
    func testLoopPreviewCanDismissWarning() throws {
        let store = TaskStore.loopPreview()
        let task = try XCTUnwrap(store.tasks.first)
        XCTAssertNotNil(task.loopWarning)
        store.dismissLoop(for: task.id)
        XCTAssertNil(store.tasks.first?.loopWarning)
    }

    @MainActor
    func testCodexLoopWarningTracksAndResetsPerTask() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexHome = directory.appendingPathComponent("codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        let session = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456001.jsonl")
        let claude = directory.appendingPathComponent("claude-events.jsonl")
        try #"{"id":"019127f4-35ae-7c73-9e72-a10123456001","thread_name":"Synthetic task"}"#.write(to: index, atomically: true, encoding: .utf8)
        try "".write(to: session, atomically: true, encoding: .utf8)
        let journal = DiagnosticJournal(directory: directory.appendingPathComponent("diagnostics", isDirectory: true))
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: codexHome), claudeReader: ClaudeTaskReader(eventFile: claude), journal: journal)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let start = #"{"timestamp":"\#(formatter.string(from: now.addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started"}}"#
        func item(_ id: String, _ type: String, _ seconds: Double) throws -> String {
            let data: [String: Any] = ["id": id, "type": type, "command": ["synthetic"], "cwd": "/synthetic", "status": "failed", "exit_code": 1]
            let record: [String: Any] = ["timestamp": formatter.string(from: now.addingTimeInterval(seconds)), "type": "event_msg", "payload": ["type": "item_completed", "item": data]]
            return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        var lines = [start]
        for index in 0..<5 { lines.append(try item("first-\(index)", "CommandExecution", Double(index + 2))) }
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertEqual(store.tasks.first?.loopWarning, LoopWarning(threshold: 5, windowMinutes: 10))
        store.dismissLoop(for: "019127f4-35ae-7c73-9e72-a10123456001")
        XCTAssertNil(store.tasks.first?.loopWarning)
        lines.append(try item("first-5", "CommandExecution", 7))
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertNil(store.tasks.first?.loopWarning)
        lines.append(try item("changed", "FileChange", 8))
        for index in 0..<5 { lines.append(try item("next-\(index)", "CommandExecution", Double(index + 9))) }
        try (lines.joined(separator: "\n") + "\n").write(to: session, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertNotNil(store.tasks.first?.loopWarning)
    }

    func testPreviouslyObservedTaskBecomesUnconfirmedInsteadOfDisappearing() {
        let previous = MonitoredTask(id: "one", provider: .codex, title: "Synthetic task", activity: "Working", isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date())
        let uncertain = TaskSnapshotMerger.merge(previous: [previous], current: [], terminalIDs: [])
        XCTAssertEqual(uncertain.count, 1)
        XCTAssertFalse(uncertain[0].isActive)
        XCTAssertTrue(uncertain[0].isUnconfirmed)
        XCTAssertEqual(uncertain[0].activity, tr("Статус не подтверждён", "Status unconfirmed"))
        XCTAssertTrue(TaskSnapshotMerger.merge(previous: uncertain, current: [], terminalIDs: ["one"]).isEmpty)
        XCTAssertEqual(TaskSnapshotMerger.merge(previous: uncertain, current: [previous], terminalIDs: []), [previous])
    }

    @MainActor
    func testSourceFailurePreservesObservedTaskAndOtherProvider() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexHome = directory.appendingPathComponent("codex", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        let session = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456001.jsonl")
        let claude = directory.appendingPathComponent("claude-events.jsonl")
        let indexLine = #"{"id":"019127f4-35ae-7c73-9e72-a10123456001","thread_name":"Synthetic task"}"#
        try (indexLine + "\n").write(to: index, atomically: true, encoding: .utf8)
        try "".write(to: session, atomically: true, encoding: .utf8)
        let journal = DiagnosticJournal(directory: directory.appendingPathComponent("diagnostics", isDirectory: true))
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: codexHome), claudeReader: ClaudeTaskReader(eventFile: claude), journal: journal)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start = #"{"timestamp":"\#(formatter.string(from: Date().addingTimeInterval(1)))","type":"event_msg","payload":{"type":"task_started"}}"#
        let claudeEvent = event(session: "active-claude", name: "UserPromptSubmit", active: true, date: Date().addingTimeInterval(2), prompt: "")
        try (start + "\n").write(to: session, atomically: true, encoding: .utf8)
        try (claudeEvent + "\n").write(to: claude, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertEqual(store.tasks.count, 2)
        XCTAssertTrue(store.unavailableSources.isEmpty)
        try FileManager.default.removeItem(at: index)
        store.refresh()
        XCTAssertEqual(store.unavailableSources, [.codex])
        let uncertain = try XCTUnwrap(store.tasks.first { $0.provider == .codex })
        XCTAssertTrue(uncertain.isUnconfirmed)
        XCTAssertFalse(uncertain.isActive)
        XCTAssertTrue(store.tasks.contains { $0.provider == .claude && $0.isActive })
        try (indexLine + "\n").write(to: index, atomically: true, encoding: .utf8)
        let end = #"{"timestamp":"\#(formatter.string(from: Date().addingTimeInterval(3)))","type":"event_msg","payload":{"type":"task_complete"}}"#
        try (start + "\n" + end + "\n").write(to: session, atomically: true, encoding: .utf8)
        store.refresh()
        XCTAssertTrue(store.unavailableSources.isEmpty)
        XCTAssertFalse(store.tasks.contains { $0.provider == .codex })
        XCTAssertTrue(store.tasks.contains { $0.provider == .claude && $0.isActive })
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
        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: date), "session_id": session,
            "event": name, "active": active, "prompt": prompt, "activity": name
        ]
        if name == "Stop" { record["plan_version"] = 2; record["stop_background"] = "clear" }
        return String(decoding: try! JSONSerialization.data(withJSONObject: record), as: UTF8.self)
    }
}
