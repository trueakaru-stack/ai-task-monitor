import Foundation

struct ClaudeTaskReader {
    let eventFile: URL

    init(eventFile: URL = AppPaths.claudeEvents) {
        self.eventFile = eventFile
    }

    func readTasks(now: Date = Date()) -> [MonitoredTask] {
        guard let text = try? FileHelpers.tail(of: eventFile, maximumBytes: 4_194_304) else { return [] }
        var sessions: [String: SessionState] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let event = FileHelpers.jsonObject(line) else { continue }
            let id = event.string("session_id")
            guard !id.isEmpty else { continue }
            var state = sessions[id] ?? SessionState(id: id)
            state.updatedAt = FileHelpers.isoDate(event["timestamp"]) ?? state.updatedAt
            if !event.string("cwd").isEmpty { state.cwd = event.string("cwd") }
            if !event.string("activity").isEmpty { state.activity = localizedActivity(event) }
            state.isActive = event["active"] as? Bool ?? state.isActive
            if event.string("event") == "UserPromptSubmit", !event.string("prompt").isEmpty {
                state.title = FileHelpers.normalized(event.string("prompt"), limit: 240)
            }
            updateSteps(event, state: &state)
            sessions[id] = state
        }

        return sessions.values.compactMap { state in
            guard state.isActive, now.timeIntervalSince(state.updatedAt) < 7_200 else { return nil }
            let steps = state.stepsOrder.compactMap { state.steps[$0] }
            let title = state.title.isEmpty ? fallbackTitle(cwd: state.cwd) : state.title
            let progress = MonitoredTask.progress(for: steps)
            return MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: title,
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
        default: return event.string("activity")
        }
    }

    private func fallbackTitle(cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? "Claude Code" : "Claude Code · \(name)"
    }
}

private struct SessionState {
    let id: String
    var title = ""
    var activity = ""
    var isActive = false
    var updatedAt = Date.distantPast
    var cwd = ""
    var steps: [String: TaskStep] = [:]
    var stepsOrder: [String] = []
}
