import Foundation
import CoreFoundation

// Bound work and preserve byte identity. The input must already have passed
// strict UTF-8 decoding; never truncate an identifier to fit this limit.
func claudeSessionKey(_ value: String) -> String? {
    let bytes = Array(value.utf8.prefix(257))
    guard !bytes.isEmpty, bytes.count <= 256 else { return nil }
    if bytes.allSatisfy({ $0 < 128 }) && bytes.first != 0x7e { return value }
    let hex = Array("0123456789abcdef".utf8)
    var output: [UInt8] = [0x7e]
    output.reserveCapacity(1 + bytes.count * 2)
    for byte in bytes { output.append(hex[Int(byte >> 4)]); output.append(hex[Int(byte & 15)]) }
    return String(decoding: output, as: UTF8.self)
}

private enum ClaudeReadError: Error { case incomplete, invalidRecord, unsupportedIdentity }
private typealias ClaudeRecord = ([String: Any], Date, String)

// A complete invalid line can belong to any session: do not replace bytes or
// skip it and then accept another session's terminal record. An incomplete
// final write is retried on the next poll instead of being parsed as complete.
private func readClaudeRecords(_ url: URL) throws -> (records: [ClaudeRecord], truncated: Bool) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let length = try handle.seekToEnd()
    let limit: UInt64 = 4_194_304
    let count = min(limit, length)
    let start = length - count
    try handle.seek(toOffset: start)
    var data = try handle.read(upToCount: Int(count)) ?? Data()
    guard data.count == Int(count) else { throw ClaudeReadError.incomplete }
    guard data.isEmpty || data.last == 0x0a else { throw ClaudeReadError.incomplete }
    let truncated = start > 0
    if truncated {
        guard let newline = data.firstIndex(of: 0x0a) else { throw ClaudeReadError.incomplete }
        data = Data(data[data.index(after: newline)...])
    }
    var records: [ClaudeRecord] = []
    for bytes in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
        let line = Data(bytes)
        guard let event = ClaudeJSONValidation.object(line),
              let timestamp = FileHelpers.isoDate(event["timestamp"]),
              let session = event["session_id"] as? String else { throw ClaudeReadError.invalidRecord }
        guard let id = claudeSessionKey(session) else { throw ClaudeReadError.unsupportedIdentity }
        records.append((event, timestamp, id))
    }
    return (records, truncated)
}

private func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

private func safeStageID(_ value: String) -> Bool {
    let bytes = Array(value.utf8.prefix(129))
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
        (97...122).contains($0) || $0 == 45 || $0 == 95 }
}

private func phaseVersionOne(_ event: [String: Any]) -> Bool {
    guard let n = event["plan_version"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
    return n.doubleValue == 1
}

private struct ClaudePhase {
    var kind: String
    var tool: String = ""
    var taskID: String = ""
    var title: String = ""
    var status: String = ""
    var previousStatus: String = ""
    var intentStatus: String = ""
    var callID: String = ""
}

// Only the hook's validated, minimal PostToolUse records can mutate status.
// Old records, failure and unlinked lifecycle notifications remain uncertain.
private func phaseOf(_ event: [String: Any]) -> ClaudePhase {
    let name = event.string("event"), tool = event.string("tool_name")
    let id = event.string("task_id"), title = event.string("task_subject")
    let rawCall = event.string("plan_call_id")
    let call = safeStageID(rawCall) ? rawCall : ""
    if sameBytes(name, "TaskCreated") || sameBytes(name, "TaskCompleted") {
        return ClaudePhase(kind: "unlinked", taskID: id, title: title, callID: call)
    }
    let isPhaseEvent = ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains { sameBytes(name, $0) }
    let isTargetTool = ["TaskCreate", "TaskUpdate"].contains { sameBytes(tool, $0) }
    if isPhaseEvent && tool.isEmpty { return ClaudePhase(kind: "uncertain", taskID: id, title: title) }
    if !isPhaseEvent && (!id.isEmpty || !event.string("task_status").isEmpty) {
        return ClaudePhase(kind: "legacy", taskID: id, title: title)
    }
    if !isPhaseEvent || !isTargetTool {
        if phaseVersionOne(event), sameBytes(event.string("plan_signal"), "uncertain") {
            return ClaudePhase(kind: "uncertain")
        }
        return ClaudePhase(kind: "none")
    }
    guard phaseVersionOne(event) else { return ClaudePhase(kind: "legacy", tool: tool, taskID: id, title: title) }
    let signal = event.string("plan_signal")
    if sameBytes(signal, "attempt"), sameBytes(name, "PreToolUse") {
        let intent = event.string("task_intent_status")
        if sameBytes(tool, "TaskUpdate"), safeStageID(id),
           ["pending", "in_progress", "completed"].contains(where: { sameBytes(intent, $0) }) {
            return ClaudePhase(kind: "attempt", tool: tool, taskID: id, intentStatus: intent, callID: call)
        }
        if sameBytes(tool, "TaskCreate"), id.isEmpty, !title.isEmpty, Array(title.utf8.prefix(1025)).count <= 1024 {
            return ClaudePhase(kind: "attempt", tool: tool, title: title, callID: call)
        }
        return ClaudePhase(kind: "uncertain", tool: tool, taskID: id, callID: call)
    }
    if sameBytes(signal, "failure"), sameBytes(name, "PostToolUseFailure") {
        return ClaudePhase(kind: "failure", tool: tool, taskID: id, callID: call)
    }
    let status = event.string("task_status")
    let previousStatus = event.string("task_from_status")
    let validStatus = ["pending", "in_progress", "completed"].contains { sameBytes(status, $0) }
    if sameBytes(name, "PostToolUse"), safeStageID(id), validStatus {
        if sameBytes(signal, "observed_update"), sameBytes(tool, "TaskUpdate"),
           ["pending", "in_progress", "completed"].contains(where: { sameBytes(previousStatus, $0) }),
           !sameBytes(previousStatus, status) {
            return ClaudePhase(kind: "observed_update", tool: tool, taskID: id, status: status, previousStatus: previousStatus, callID: call)
        }
        if sameBytes(signal, "observed_create"), sameBytes(tool, "TaskCreate"), sameBytes(status, "pending"),
           previousStatus.isEmpty, !title.isEmpty, Array(title.utf8.prefix(1025)).count <= 1024 {
            return ClaudePhase(kind: "observed_create", tool: tool, taskID: id, title: title, status: status, callID: call)
        }
    }
    return ClaudePhase(kind: "uncertain", tool: tool, taskID: id, title: title, callID: call)
}

private struct ClaudePhaseAttempt {
    let tool: String
    let taskID: String
    let title: Data
    let intentStatus: String
    let date: Date
}

private struct ClaudePhaseSignature: Hashable {
    let kind: String
    let taskID: String
    let status: String
    let previousStatus: String
    let title: Data
}

private struct ClaudeSeenObservation: Hashable {
    let signature: ClaudePhaseSignature
    let date: Date
    let callID: String
}

private struct ClaudePhaseTracker {
    var unresolved: [String: ClaudePhaseAttempt] = [:]
    var resolved: [String: ClaudePhaseSignature] = [:]
    var seen: Set<ClaudeSeenObservation> = []
    var lastStatuses: [String: String] = [:]
    var inconsistent = false
    var sawObservation = false

    mutating func consume(_ phase: ClaudePhase, at date: Date) {
        switch phase.kind {
        case "none": break
        case "attempt":
            guard !phase.callID.isEmpty,
                  !sameBytes(phase.tool, "TaskUpdate") || safeStageID(phase.taskID) else { inconsistent = true; return }
            if resolved[phase.callID] != nil { inconsistent = true; return }
            if let old = unresolved[phase.callID] {
                if old.date != date || !sameBytes(old.tool, phase.tool) || !sameBytes(old.taskID, phase.taskID) ||
                    old.title != Data(phase.title.utf8) || !sameBytes(old.intentStatus, phase.intentStatus) { inconsistent = true }
            } else {
                unresolved[phase.callID] = ClaudePhaseAttempt(tool: phase.tool, taskID: phase.taskID,
                                                              title: Data(phase.title.utf8), intentStatus: phase.intentStatus, date: date)
            }
        case "observed_create", "observed_update":
            sawObservation = true
            let signature = ClaudePhaseSignature(kind: phase.kind, taskID: phase.taskID, status: phase.status,
                                                 previousStatus: phase.previousStatus, title: Data(phase.title.utf8))
            if !seen.insert(ClaudeSeenObservation(signature: signature, date: date, callID: phase.callID)).inserted { return }
            if !phase.callID.isEmpty {
                if let old = resolved[phase.callID], old != signature { inconsistent = true }
                if let attempt = unresolved.removeValue(forKey: phase.callID) {
                    if date <= attempt.date || !sameBytes(attempt.tool, phase.tool) ||
                        (!attempt.taskID.isEmpty && !sameBytes(attempt.taskID, phase.taskID)) ||
                        (!attempt.intentStatus.isEmpty && !sameBytes(attempt.intentStatus, phase.status)) ||
                        (!attempt.title.isEmpty && attempt.title != Data(phase.title.utf8)) { inconsistent = true }
                }
                resolved[phase.callID] = signature
            }
            if let previous = lastStatuses[phase.taskID] {
                if sameBytes(phase.kind, "observed_create") || !sameBytes(previous, phase.previousStatus) { inconsistent = true }
            }
            lastStatuses[phase.taskID] = phase.status
        default: inconsistent = true
        }
    }

    var isUncertain: Bool { inconsistent || !unresolved.isEmpty || !sawObservation }
}

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
        let currentInput = try readClaudeRecords(eventFile)
        let current = currentInput.records
        let observedIDs = Set(current.map { $0.2 })
        let freshIDs = Set(current.compactMap { item -> String? in
            if let observedSince, item.1 < observedSince { return nil }
            guard item.0["active"] as? Bool == true else { return nil }
            return item.2
        })
        var legacy: [([String: Any], Date, String)] = []
        var legacyTruncated = false
        if let legacyFile, !observedIDs.isEmpty {
            do {
                let prior = try readClaudeRecords(legacyFile)
                legacyTruncated = prior.truncated
                legacy = prior.records.filter { observedIDs.contains($0.2) }
            } catch {
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError { throw error }
            }
        }
        // Preserve ordering anomalies before sorting. The two files may overlap
        // and do not share a monotonic sequence or a reliable common cursor.
        typealias Observation = (date: Date, active: Bool?)
        var latest: [[String: Observation]] = [[:], [:]]
        var latestActive: [[String: Observation]] = [[:], [:]]
        var timeUncertain: Set<String> = (currentInput.truncated || legacyTruncated) ? observedIDs : []
        // Plan ordering is separate from session activity. A short reversal of
        // two plan mutations can make progress unsafe without proving the
        // session itself stopped or became inactive.
        var planUncertain: Set<String> = (currentInput.truncated || legacyTruncated) ? observedIDs : []
        var latestPrompt: [[String: Date]] = [[:], [:]]
        var latestStep: [[String: Date]] = [[:], [:]]
        var latestTask: [[PlanTaskKey: Date]] = [[:], [:]]
        var latestCall: [[PlanTaskKey: Date]] = [[:], [:]]
        var taskIdentityBytes: [PlanTaskKey: Data] = [:]
        // Legacy is scanned first. Store its evidence only; compare each
        // current event against it without retaining a second timestamp index.
        var legacyEffects: [PlanStepTimeKey: PlanEffectSummary] = [:]
        var legacyPromptTimes: Set<PlanTimeKey> = []
        var legacyStepTimes: Set<PlanTimeKey> = []
        var legacyActivity: [PlanTimeKey: UInt8] = [:]
        var sessionsWithPrompt: Set<String> = []
        for (source, records) in [legacy, current].enumerated() {
            for (event, date, id) in records {
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
                let phase = phaseOf(event)
                if !phase.callID.isEmpty {
                    let callKey = PlanTaskKey(session: id, task: phase.callID)
                    if let previous = latestCall[source][callKey], date < previous { planUncertain.insert(id) }
                    if latestCall[source][callKey] == nil || date > latestCall[source][callKey]! { latestCall[source][callKey] = date }
                }
                if !taskID.isEmpty, phase.kind != "none" {
                    guard let taskIdentity = claudeSessionKey(taskID) else { planUncertain.insert(id); continue }
                    let taskKey = PlanTaskKey(session: id, task: taskIdentity)
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
                    if let effect = planStepEffect(event) {
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
        var phaseTrackers: [String: ClaudePhaseTracker] = [:]
        for entry in ordered {
            let event = entry.element.0
            let id = entry.element.2
            var tracker = phaseTrackers[id] ?? ClaudePhaseTracker()
            tracker.consume(phaseOf(event), at: entry.element.1)
            phaseTrackers[id] = tracker
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
                sessionsWithPrompt.contains(state.id) && !(phaseTrackers[state.id]?.isUncertain ?? true)
            let progress = planConfirmed ? MonitoredTask.progress(for: steps) : nil
            result.tasks.append(MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: tr("Задача Claude Code", "Claude Code task"),
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : state.activity, isActive: !unconfirmed, progress: progress,
                progressKind: progress == nil ? .none : .approximate,
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
        let phase = phaseOf(event)
        let status = phase.status
        let subject = phase.title
        let statusEffect: Int?
        if sameBytes(status, "completed") { statusEffect = 2 }
        else if sameBytes(status, "in_progress") { statusEffect = 1 }
        else if sameBytes(status, "pending") { statusEffect = 0 }
        else { statusEffect = nil }
        let titleEffect: Data? = subject.isEmpty ? nil : Data(subject.utf8)
        guard statusEffect != nil || titleEffect != nil else { return nil }
        return PlanStepEffect(status: statusEffect, title: titleEffect)
    }

    private func updateSteps(_ event: [String: Any], state: inout SessionState) {
        let phase = phaseOf(event)
        guard phase.kind != "none", !phase.taskID.isEmpty, let key = claudeSessionKey(phase.taskID) else { return }
        let subject = Array(phase.title.utf8.prefix(1025)).count <= 1024 ? phase.title : ""
        if state.steps[key] == nil {
            state.steps[key] = TaskStep(id: key, title: subject.isEmpty ? tr("Этап \(phase.taskID)", "Step \(phase.taskID)") : subject, status: .pending)
            state.stepsOrder.append(key)
        } else if !subject.isEmpty {
            state.steps[key]?.title = subject
        }
        if sameBytes(phase.status, "completed") { state.steps[key]?.status = .done }
        else if sameBytes(phase.status, "in_progress") { state.steps[key]?.status = .active }
        else if sameBytes(phase.status, "pending") { state.steps[key]?.status = .pending }
    }

    private func localizedActivity(_ event: [String: Any]) -> String {
        let tool = event.string("tool_name")
        let subject = event.string("task_subject")
        switch event.string("event") {
        case "UserPromptSubmit": return tr("Обрабатывает новый запрос", "Processing a new request")
        case "PreToolUse": return tool.isEmpty ? tr("Выполняет действие", "Running an action") : tr("Выполняет: \(tool)", "Running: \(tool)")
        case "PostToolUse": return tool.isEmpty ? tr("Действие завершено", "Action completed") : tr("Завершено: \(tool)", "Completed: \(tool)")
        case "PostToolUseFailure": return tool.isEmpty ? tr("Ошибка действия", "Action failed") : tr("Ошибка: \(tool)", "Failed: \(tool)")
        case "TaskCreated", "TaskCompleted": return subject.isEmpty ? tr("Обрабатывает этап", "Processing step") : tr("Обрабатывает этап: \(subject)", "Processing step: \(subject)")
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
