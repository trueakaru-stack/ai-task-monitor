import Foundation

struct ClaudeTaskReader {
    let eventFile: URL
    let legacyFile: URL?

    init(eventFile: URL? = nil, legacyFile: URL? = nil) {
        self.eventFile = eventFile ?? AppPaths.claudeEvents
        self.legacyFile = legacyFile ?? (eventFile == nil ? AppPaths.legacyClaudeEvents : nil)
    }

    func readTasks(now: Date = Date(), observedSince: Date? = nil) -> [MonitoredTask] {
        guard let text = try? FileHelpers.tail(of: eventFile, maximumBytes: 4_194_304) else { return [] }
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
            state.updatedAt = entry.element.1
            if !event.string("activity").isEmpty { state.activity = localizedActivity(event) }
            state.isActive = event["active"] as? Bool ?? state.isActive
            updateSteps(event, state: &state)
            sessions[id] = state
        }

        return sessions.values.compactMap { state in
            guard state.isActive, freshIDs.contains(state.id), now.timeIntervalSince(state.updatedAt) < 7_200 else { return nil }
            let steps = state.stepsOrder.compactMap { state.steps[$0] }
            let progress = MonitoredTask.progress(for: steps)
            return MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: "Задача Claude Code",
                activity: state.activity, isActive: true, progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps, updatedAt: state.updatedAt
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func updateSteps(_ event: [String: Any], state: inout SessionState) {
        let taskID = event.string("task_id")
        guard !taskID.isEmpty else { return }
        if state.steps[taskID] == nil {
            let subject = event.string("task_subject")
            state.steps[taskID] = TaskStep(id: taskID, title: subject.isEmpty ? "Этап \(taskID)" : subject, status: .pending)
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
        case "UserPromptSubmit": return "Обрабатывает новый запрос"
        case "PreToolUse": return tool.isEmpty ? "Выполняет действие" : "Выполняет: \(tool)"
        case "PostToolUse": return tool.isEmpty ? "Действие завершено" : "Завершено: \(tool)"
        case "PostToolUseFailure": return tool.isEmpty ? "Ошибка действия" : "Ошибка: \(tool)"
        case "TaskCreated": return subject.isEmpty ? "Добавлен этап" : "Добавлен этап: \(subject)"
        case "TaskCompleted": return subject.isEmpty ? "Завершён этап" : "Завершён этап: \(subject)"
        case "SubagentStart": return "Запущен дополнительный агент"
        case "SubagentStop": return "Дополнительный агент завершён"
        default: return ""
        }
    }

}

private struct SessionState {
    let id: String
    var activity = ""
    var isActive = false
    var updatedAt = Date.distantPast
    var steps: [String: TaskStep] = [:]
    var stepsOrder: [String] = []
}
