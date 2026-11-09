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
        // Preserve ordering anomalies before sorting. The two files may overlap
        // and do not share a monotonic sequence or a reliable common cursor.
        typealias Observation = (date: Date, active: Bool?)
        var latest: [[String: Observation]] = [[:], [:]]
        var latestActive: [[String: Observation]] = [[:], [:]]
        var timeUncertain: Set<String> = []
        // Plan ordering is separate from session activity. A short reversal of
        // two plan mutations can make progress unsafe without proving the
        // session itself stopped or became inactive.
        var planUncertain: Set<String> = []
        var latestPrompt: [[String: Date]] = [[:], [:]]
        var latestStep: [[String: Date]] = [[:], [:]]
        var latestTask: [[PlanTaskKey: Date]] = [[:], [:]]
        var taskIdentityBytes: [PlanTaskKey: Data] = [:]
        // Legacy is scanned first. Store its evidence only; compare each
        // current event against it without retaining a second timestamp index.
        var legacyEffects: [PlanStepTimeKey: PlanEffectSummary] = [:]
        var legacyPromptTimes: Set<PlanTimeKey> = []
        var legacyStepTimes: Set<PlanTimeKey> = []
        var legacyActivity: [PlanTimeKey: UInt8] = [:]
        var sessionsWithPrompt: Set<String> = []
        for (source, records) in [legacy, current].enumerated() {
            for (event, date) in records {
                let id = event.string("session_id")
                let active = event["active"] as? Bool
                let timeKey = PlanTimeKey(session: id, date: date)
                if let previous = latest[source][id] {
                    let reversed = previous.date.timeIntervalSince(date)
                    if reversed > 60 || (reversed > 0 && previous.active != nil && active != nil && previous.active != active) {
                        timeUncertain.insert(id)
                    }
                    if date >= previous.date { latest[source][id] = (date, active) }
                } else { latest[source][id] = (date, active) }
                if let active {
                    if let previous = latestActive[source][id] {
                        if date < previous.date && previous.active != active { timeUncertain.insert(id) }
                        if date >= previous.date { latestActive[source][id] = (date, active) }
                    } else { latestActive[source][id] = (date, active) }
                    // Equal-time activity conflicts cannot be discarded when a
                    // later same-source event replaces the latest observation.
                    let bit: UInt8 = active ? 1 : 2
                    let opposite: UInt8 = active ? 2 : 1
                    if source == 0 { legacyActivity[timeKey, default: 0] |= bit }
                    else if ((legacyActivity[timeKey] ?? 0) & opposite) != 0 { timeUncertain.insert(id) }
                }
                let name = event.string("event")
                let isPrompt = name == "UserPromptSubmit" && active != false
                if isPrompt {
                    sessionsWithPrompt.insert(id)
                    if let previous = latestPrompt[source][id], date < previous { planUncertain.insert(id) }
                    if let previous = latestStep[source][id], date < previous { planUncertain.insert(id) }
                    if latestPrompt[source][id] == nil || date > latestPrompt[source][id]! {
                        latestPrompt[source][id] = date
                    }
                    if source == 0 { legacyPromptTimes.insert(timeKey) }
                    else if legacyStepTimes.contains(timeKey) { planUncertain.insert(id) }
                }
                let taskID = event.string("task_id")
                if !taskID.isEmpty, let effect = planStepEffect(event) {
                    let taskKey = PlanTaskKey(session: id, task: taskID)
                    let rawIdentity = Data(taskID.utf8)
                    if let prior = taskIdentityBytes[taskKey], prior != rawIdentity { planUncertain.insert(id) }
                    else { taskIdentityBytes[taskKey] = rawIdentity }
                    if let previous = latestTask[source][taskKey], date < previous { planUncertain.insert(id) }
                    if let previous = latestPrompt[source][id], date < previous { planUncertain.insert(id) }
                    if latestTask[source][taskKey] == nil || date > latestTask[source][taskKey]! {
                        latestTask[source][taskKey] = date
                    }
                    if latestStep[source][id] == nil || date > latestStep[source][id]! {
                        latestStep[source][id] = date
                    }
                    if source == 0 { legacyStepTimes.insert(timeKey) }
                    else if legacyPromptTimes.contains(timeKey) { planUncertain.insert(id) }
                    let stepKey = PlanStepTimeKey(task: taskKey, date: date)
                    if source == 0 {
                        var summary = legacyEffects[stepKey] ?? PlanEffectSummary()
                        summary.record(effect)
                        legacyEffects[stepKey] = summary
                    } else if let summary = legacyEffects[stepKey], summary.conflicts(with: effect) {
                        planUncertain.insert(id)
                    }
                }
            }
        }
        for (id, prior) in latest[0] {
            if let present = latest[1][id],
               prior.date > present.date || (prior.date == present.date && prior.active != nil && present.active != nil && prior.active != present.active) {
                timeUncertain.insert(id)
            }
        }
        for (id, prior) in latestActive[0] {
            if let present = latestActive[1][id], prior.date >= present.date && prior.active != present.active {
                timeUncertain.insert(id)
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
                if isNewPrompt && !state.steps.isEmpty { state.planConfirmed = false }
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
            let age = now.timeIntervalSince(state.updatedAt)
            let timeAnomaly = age < -60 || (!state.isActive && age < 0) || timeUncertain.contains(state.id)
            if !state.isActive && !timeAnomaly && ["Stop", "SessionEnd", "StopFailure"].contains(state.lastEvent) {
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
            guard (state.isActive || timeAnomaly), freshIDs.contains(state.id) else { continue }
            let steps = state.stepsOrder.compactMap { state.steps[$0] }
            let unconfirmed = age >= 7_200 || timeAnomaly
            // A step observed without any prompt boundary is not proof that
            // it belongs to the currently observed user request.
            let planConfirmed = state.planConfirmed && !unconfirmed && !planUncertain.contains(state.id) &&
                sessionsWithPrompt.contains(state.id)
            let progress = planConfirmed ? MonitoredTask.progress(for: steps) : nil
            result.tasks.append(MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: tr("Задача Claude Code", "Claude Code task"),
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : state.activity, isActive: !unconfirmed, progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps, updatedAt: state.updatedAt, isUnconfirmed: unconfirmed,
                startedAt: state.startedAt, startKey: state.startKey, planConfirmed: planConfirmed
            ))
        }
        result.tasks.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    // An event carrying only task_id does not change an existing step's
    // status or title. Keep earlier meaningful observations for conflict
    // detection instead of letting such a later record replace them.
    private func planStepEffect(_ event: [String: Any]) -> PlanStepEffect? {
        let name = event.string("event")
        let status = event.string("task_status")
        let subject = event.string("task_subject")
        let statusEffect: Int?
        if name == "TaskCompleted" || status == "completed" { statusEffect = 2 }
        else if status == "in_progress" { statusEffect = 1 }
        else if name == "TaskCreated" || status == "pending" { statusEffect = 0 }
        else { statusEffect = nil }
        let titleEffect: Data? = (name == "TaskCreated" || !subject.isEmpty) ? Data(subject.utf8) : nil
        guard statusEffect != nil || titleEffect != nil else { return nil }
        return PlanStepEffect(status: statusEffect, title: titleEffect)
    }

    private func updateSteps(_ event: [String: Any], state: inout SessionState) {
        let taskID = event.string("task_id")
        guard !taskID.isEmpty else { return }
        let subject = event.string("task_subject")
        if state.steps[taskID] == nil {
            state.steps[taskID] = TaskStep(id: taskID, title: subject.isEmpty ? tr("Этап \(taskID)", "Step \(taskID)") : subject, status: .pending)
            state.stepsOrder.append(taskID)
        } else if event.string("event") == "TaskCreated" {
            state.steps[taskID]?.title = subject.isEmpty ? tr("Этап \(taskID)", "Step \(taskID)") : subject
            state.steps[taskID]?.status = .pending
        } else if !subject.isEmpty {
            state.steps[taskID]?.title = subject
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

private struct PlanTaskKey: Hashable {
    let session: String
    let task: String
}

private struct PlanTimeKey: Hashable {
    let session: String
    let date: Date
}

private struct PlanStepTimeKey: Hashable {
    let task: PlanTaskKey
    let date: Date
}

private struct PlanStepEffect {
    let status: Int?
    let title: Data?
}

// One bounded summary per task and timestamp, rather than pairwise comparison
// of every overlapping line. Missing fields represent no mutation.
private struct PlanEffectSummary {
    private var statuses: UInt8 = 0
    private var firstTitle: Data?
    private var multipleTitles = false

    init() {}

    mutating func record(_ effect: PlanStepEffect) {
        if let status = effect.status { statuses |= UInt8(1) << status }
        if let title = effect.title {
            if let firstTitle {
                if firstTitle != title { multipleTitles = true }
            } else { firstTitle = title }
        }
    }

    func conflicts(with effect: PlanStepEffect) -> Bool {
        if let status = effect.status, statuses != 0 {
            let same = UInt8(1) << status
            if (statuses & same) != statuses { return true }
        }
        if let title = effect.title, let firstTitle, multipleTitles || firstTitle != title { return true }
        return false
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
    var planConfirmed = true
    var steps: [String: TaskStep] = [:]
    var stepsOrder: [String] = []
}
