import Foundation

struct ClaudeTaskSnapshot {
    var tasks: [MonitoredTask] = []
    var terminalIDs: Set<String> = []
    var interruptedIDs: Set<String> = []
}

struct ClaudeTaskReader {
    let eventFile: URL
    let legacyFile: URL?
    let usesExplicitFile: Bool

    init(eventFile: URL? = nil, legacyFile: URL? = nil) {
        self.eventFile = eventFile ?? AppPaths.claudeEvents
        self.legacyFile = legacyFile ?? (eventFile == nil ? AppPaths.legacyClaudeEvents : nil)
        self.usesExplicitFile = eventFile != nil
    }

    func readTasks(now: Date = Date(), observedSince: Date? = nil) -> [MonitoredTask] {
        (try? readSnapshot(now: now, observedSince: observedSince).tasks) ?? []
    }

    func readSnapshot(now: Date = Date(), observedSince: Date? = nil) throws -> ClaudeTaskSnapshot {
        let text = try FileHelpers.tail(of: eventFile, maximumBytes: 4_194_304)
        let current: [([String: Any], Date)] = text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let event = FileHelpers.jsonObject(line), !event.string("session_id").isEmpty,
                  let timestamp = FileHelpers.isoDate(event["timestamp"]) else { return nil }
            return (event, timestamp)
        }
        let observedIDs = Set(current.map { $0.0.string("session_id") })
        let freshIDs = Set(current.compactMap { item -> String? in
            if let observedSince, item.1 < observedSince { return nil }
            guard item.0["active"] as? Bool == true else { return nil }
            return item.0.string("session_id")
        })
        var legacy: [([String: Any], Date)] = []
        if let legacyFile, !observedIDs.isEmpty,
           let legacyText = try? FileHelpers.tail(of: legacyFile, maximumBytes: 4_194_304) {
            legacy = legacyText.split(whereSeparator: \.isNewline).compactMap { line in
                guard let event = FileHelpers.jsonObject(line), observedIDs.contains(event.string("session_id")),
                      let timestamp = FileHelpers.isoDate(event["timestamp"]) else { return nil }
                return (event, timestamp)
            }
        }
        let ordered = (legacy + current).enumerated().sorted { left, right in
            if left.element.1 != right.element.1 { return left.element.1 < right.element.1 }
            return left.offset < right.offset
        }
        var sessions: [String: SessionState] = [:]
        for entry in ordered {
            let event = entry.element.0
            let id = event.string("session_id")
            var state = sessions[id] ?? SessionState(id: id)
            let isNewPrompt = event.string("event") == "UserPromptSubmit" && (event["active"] as? Bool) != false
            let becameActive = (event["active"] as? Bool) == true && !state.isActive
            if isNewPrompt || becameActive {
                state.startedAt = entry.element.1
                state.startKey = "event:" + event.string("timestamp")
            }
            state.updatedAt = entry.element.1
            state.lastEvent = event.string("event")
            if !event.string("activity").isEmpty { state.activity = localizedActivity(event) }
            state.isActive = event["active"] as? Bool ?? state.isActive
            updateSteps(event, state: &state)
            sessions[id] = state
        }

        var result = ClaudeTaskSnapshot()
        for state in sessions.values {
            if !state.isActive && ["Stop", "SessionEnd", "StopFailure"].contains(state.lastEvent) {
                var recognized = false
                if let observedSince {
                    if state.updatedAt >= observedSince { recognized = true }
                } else {
                    recognized = true
                }
                if recognized {
                    let id = "claude:\(state.id)"
                    result.terminalIDs.insert(id)
                    if state.lastEvent != "Stop" { result.interruptedIDs.insert(id) }
                }
                continue
            }
            guard state.isActive, freshIDs.contains(state.id) else { continue }
            let steps = state.stepsOrder.compactMap { state.steps[$0] }
            let progress = MonitoredTask.progress(for: steps)
            let unconfirmed = now.timeIntervalSince(state.updatedAt) >= 7_200
            result.tasks.append(MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: tr("Задача Claude Code", "Claude Code task"),
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : state.activity, isActive: !unconfirmed, progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps, updatedAt: state.updatedAt, isUnconfirmed: unconfirmed,
                startedAt: state.startedAt, startKey: state.startKey
            ))
        }
        result.tasks.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    private func updateSteps(_ event: [String: Any], state: inout SessionState) {
        let taskID = event.string("task_id")
        guard !taskID.isEmpty else { return }
        if state.steps[taskID] == nil {
            let subject = event.string("task_subject")
            state.steps[taskID] = TaskStep(id: taskID, title: subject.isEmpty ? tr("Этап \(taskID)", "Step \(taskID)") : subject, status: .pending)
            state.stepsOrder.append(taskID)
        }
        let status = event.string("task_status")
        if event.string("event") == "TaskCompleted" || status == "completed" { state.steps[taskID]?.status = .done }
        else if status == "in_progress" { state.steps[taskID]?.status = .active }
        else if status == "pending" { state.steps[taskID]?.status = .pending }
    }

    private func localizedActivity(_ event: [String: Any]) -> String {
        let tool = event.string("tool_name")
        let subject = event.string("task_subject")
        switch event.string("event") {
        case "UserPromptSubmit": return tr("Обрабатывает новый запрос", "Processing a new request")
        case "PreToolUse": return tool.isEmpty ? tr("Выполняет действие", "Running an action") : tr("Выполняет: \(tool)", "Running: \(tool)")
        case "PostToolUse": return tool.isEmpty ? tr("Действие завершено", "Action completed") : tr("Завершено: \(tool)", "Completed: \(tool)")
        case "PostToolUseFailure": return tool.isEmpty ? tr("Ошибка действия", "Action failed") : tr("Ошибка: \(tool)", "Failed: \(tool)")
        case "TaskCreated": return subject.isEmpty ? tr("Добавлен этап", "Step added") : tr("Добавлен этап: \(subject)", "Step added: \(subject)")
        case "TaskCompleted": return subject.isEmpty ? tr("Завершён этап", "Step completed") : tr("Завершён этап: \(subject)", "Step completed: \(subject)")
        case "SubagentStart": return tr("Запущен дополнительный агент", "Subagent started")
        case "SubagentStop": return tr("Дополнительный агент завершён", "Subagent finished")
        default: return ""
        }
    }

}

private struct SessionState {
    let id: String
    var activity = ""
    var isActive = false
    var lastEvent = ""
    var updatedAt = Date.distantPast
    var startedAt = Date.distantPast
    var startKey = ""
    var steps: [String: TaskStep] = [:]
    var stepsOrder: [String] = []
}
