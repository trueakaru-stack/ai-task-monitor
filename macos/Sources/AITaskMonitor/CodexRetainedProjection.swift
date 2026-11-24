import Foundation

struct CodexRetainedAgentCard: Equatable {
    let file: CodexFileIdentity
    let startKey: String
}

extension CodexTaskGrouping {
    // Only the retention owner can decide whether its evidence still belongs
    // to this root. A retained count is not proof of current agent activity.
    static func makeRetainedProjection(_ source: [MonitoredTask], groups: [CodexAgentRetention.Group],
                                       titles: [String: String],
                                       retainedCards: [String: CodexRetainedAgentCard] = [:],
                                       fallbackRoots: [String: MonitoredTask] = [:]) -> Projection {
        let visible = source.filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
        let codex = visible.filter { $0.provider == .codex && UUID(uuidString: $0.id) != nil }
        guard codex.count <= 2_048, groups.count <= 256 else {
            return Projection(tasks: visible, displayIDBySourceID: [:])
        }
        let tasksByID = Dictionary(grouping: codex, by: { $0.id.lowercased() })
        let titleGroups = Dictionary(grouping: titles.map { ($0.key.lowercased(), $0.value) }, by: { $0.0 })
        var titleByID: [String: String] = [:]
        for (id, values) in titleGroups where Set(values.map { $0.1 }).count == 1 {
            titleByID[id] = values[0].1
        }
        var roots: [String: MonitoredTask] = [:]
        var childTargets: [String: String] = [:]
        var displayIDs: [String: String] = [:]
        for group in groups where group.canAttach && group.knownCount > 0 {
            let rootID = group.rootID.lowercased()
            guard roots[rootID] == nil, (tasksByID[rootID]?.count ?? 0) <= 1 else { continue }
            let parent: MonitoredTask
            if let current = tasksByID[rootID]?.first {
                guard current.lastActivityFileIdentity == group.rootIdentity.file else { continue }
                parent = current
            } else {
                guard let title = titleByID[rootID], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      title != "Guardian review", group.members.contains(where: \.current) else { continue }
                let updated = group.members.compactMap { tasksByID[$0.id]?.first?.updatedAt }.max() ?? .distantPast
                parent = MonitoredTask(id: "codex-group:" + rootID, provider: .codex, title: title,
                                       activity: tr("Статус не подтверждён", "Status unconfirmed"),
                                       isActive: false, progress: nil, progressKind: .none, steps: [],
                                       updatedAt: updated, isUnconfirmed: true, planConfirmed: false)
            }
            var projected = parent
            projected.codexAgentCount = group.knownCount
            projected.codexAgentCountUnconfirmed = group.countUnconfirmed
            projected.codexAgentsUnconfirmed = group.members.contains(where: \.statusUnconfirmed)
            let targetID = projected.id
            projected.codexAgents = group.members.map { member in
                let matches = tasksByID[member.id] ?? []
                let current = member.current && matches.count == 1 &&
                    matches[0].lastActivityIdentityConfirmed == true &&
                    matches[0].lastActivityFileIdentity == member.identity.file ? matches[0] : nil
                let carried = matches.count == 1 && retainedCards[member.id]?.file == member.identity.file &&
                    retainedCards[member.id]?.startKey == matches[0].startKey &&
                    matches[0].lastActivityFileIdentity == member.identity.file && matches[0].isUnconfirmed &&
                    !matches[0].isActive && !matches[0].isWaiting
                if current != nil || carried { childTargets[member.id] = targetID }
                let title = current?.title ?? (member.title.isEmpty ? tr("Агент", "Agent") : member.title)
                let activity = current.map { task in
                    (!task.isUnconfirmed || task.lastActivityIdentityConfirmed == true)
                        ? (task.lastKnownActivity ?? task.activity) : task.activity
                } ?? tr("Статус не подтверждён", "Status unconfirmed")
                return CodexAgentDetail(id: member.id, title: title, activity: activity,
                                        isActive: current?.isActive == true && current?.isUnconfirmed != true,
                                        isUnconfirmed: member.statusUnconfirmed, loopWarning: current?.loopWarning)
            }
            roots[rootID] = projected
            displayIDs[rootID] = projected.id
            displayIDs["codex-group:" + rootID] = projected.id
            displayIDs["codex-retained:" + rootID] = projected.id
        }
        for (child, target) in childTargets { displayIDs[child] = target }
        var emitted: Set<String> = []
        var result: [MonitoredTask] = []
        for task in visible {
            guard task.provider == .codex, UUID(uuidString: task.id) != nil else {
                result.append(task)
                continue
            }
            let id = task.id.lowercased()
            if childTargets[id] != nil { continue }
            guard let parent = roots[id] else { result.append(task); continue }
            if emitted.insert(id).inserted { result.append(parent) }
        }
        for (id, parent) in roots where tasksByID[id] == nil {
            if emitted.insert(id).inserted { result.append(parent) }
        }
        for group in groups where !group.canAttach && group.knownCount > 0 {
            let id = group.rootID.lowercased()
            guard let old = fallbackRoots[id], old.id.lowercased() == id,
                  old.lastActivityFileIdentity == group.rootIdentity.file else { continue }
            let details = group.members.map { member in
                CodexAgentDetail(id: member.id, title: member.title.isEmpty ? tr("Агент", "Agent") : member.title,
                                 activity: tr("Статус не подтверждён", "Status unconfirmed"),
                                 isActive: false, isUnconfirmed: true)
            }
            let retained = MonitoredTask(id: "codex-retained:" + id, provider: .codex, title: old.title,
                activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false,
                progress: nil, progressKind: .none, steps: old.steps, updatedAt: old.updatedAt,
                isUnconfirmed: true, startedAt: old.startedAt, startKey: old.startKey, planConfirmed: false,
                codexAgentCount: group.knownCount, codexAgentCountUnconfirmed: true,
                codexAgentsUnconfirmed: true, codexAgents: details,
                lastActivityIdentityConfirmed: false, lastActivityFileIdentity: group.rootIdentity.file)
            result.append(retained)
        }
        return Projection(tasks: result.sorted { $0.updatedAt > $1.updatedAt }, displayIDBySourceID: displayIDs)
    }
}
