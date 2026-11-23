import Foundation

/// Presentation only: the source tasks remain separate for lifecycle and diagnostics.
enum CodexTaskGrouping {
    struct Projection {
        let tasks: [MonitoredTask]
        let displayIDBySourceID: [String: String]
    }

    static func project(_ source: [MonitoredTask], parents: [String: String], titles: [String: String]) -> [MonitoredTask] {
        makeProjection(source, parents: parents, titles: titles).tasks
    }

    static func makeProjection(_ source: [MonitoredTask], parents: [String: String], titles: [String: String]) -> Projection {
        let visible = source.filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
        let eligible = visible.filter { $0.provider == .codex && UUID(uuidString: $0.id) != nil }
        guard eligible.count <= 512, parents.count <= 2_048 else {
            return Projection(tasks: visible, displayIDBySourceID: [:])
        }
        let byID = Dictionary(grouping: eligible, by: { $0.id.lowercased() })
        let conflicts = Set(byID.compactMap { id, values in
            values.dropFirst().allSatisfy { $0 == values[0] } ? nil : id
        })
        var parentByID: [String: String] = [:]
        var linkConflicts: Set<String> = []
        for (child, parent) in parents {
            guard UUID(uuidString: child) != nil else { continue }
            let key = child.lowercased(), value = parent.lowercased()
            guard UUID(uuidString: parent) != nil, key != value else {
                linkConflicts.insert(key)
                continue
            }
            if let old = parentByID[key], old != value { linkConflicts.insert(key) }
            parentByID[key] = value
        }
        let titleGroups = Dictionary(grouping: titles.map { ($0.key.lowercased(), $0.value) }, by: { $0.0 })
        var titleByID: [String: String] = [:]
        for (id, values) in titleGroups where Set(values.map { $0.1 }).count == 1 {
            titleByID[id] = values[0].1
        }

        func root(for child: String) -> String? {
            var current = child
            var visited: Set<String> = [child]
            for _ in 0..<128 {
                guard !conflicts.contains(current), !linkConflicts.contains(current), let parent = parentByID[current],
                      !conflicts.contains(parent), !linkConflicts.contains(parent), visited.insert(parent).inserted else { return nil }
                if parentByID[parent] != nil {
                    current = parent
                    continue
                }
                if byID[parent] != nil { return parent }
                guard let title = titleByID[parent],
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      title != "Guardian review" else { return nil }
                return parent
            }
            return nil
        }

        var members: [String: Set<String>] = [:]
        var rootByChild: [String: String] = [:]
        for task in eligible {
            let id = task.id.lowercased()
            guard !conflicts.contains(id), let rootID = root(for: id) else { continue }
            members[rootID, default: []].insert(id)
            rootByChild[id] = rootID
        }

        var result: [MonitoredTask] = []
        var emitted: Set<String> = []
        var displayIDs: [String: String] = [:]
        func details(for childIDs: Set<String>) -> [CodexAgentDetail] {
            childIDs.sorted().compactMap { id in
                guard let child = byID[id]?.first else { return nil }
                let activity = child.lastKnownActivity ?? child.activity
                return CodexAgentDetail(id: child.id, title: child.title, activity: activity,
                                        isActive: child.isActive && !child.isUnconfirmed,
                                        isUnconfirmed: child.isUnconfirmed, loopWarning: child.loopWarning)
            }
        }
        for (child, rootID) in rootByChild {
            let target = byID[rootID]?.first?.id ?? "codex-group:" + rootID
            displayIDs[child] = target
            displayIDs[rootID] = target
            displayIDs["codex-group:" + rootID] = target
        }
        for task in visible {
            let id = task.id.lowercased()
            guard task.provider == .codex, UUID(uuidString: task.id) != nil else {
                result.append(task)
                continue
            }
            if rootByChild[id] != nil { continue }
            guard let childIDs = members[id], !childIDs.isEmpty else {
                result.append(task)
                continue
            }
            guard emitted.insert(id).inserted else { continue }
            var parent = task
            parent.codexAgentCount = childIDs.count
            parent.codexAgentsUnconfirmed = childIDs.contains { child in
                byID[child]?.contains(where: { $0.isUnconfirmed }) ?? false
            }
            parent.codexAgents = details(for: childIDs)
            result.append(parent)
        }
        for (rootID, childIDs) in members where byID[rootID] == nil {
            guard !childIDs.isEmpty, let title = titleByID[rootID], emitted.insert(rootID).inserted else { continue }
            let updated = childIDs.compactMap { byID[$0]?.map(\.updatedAt).max() }.max() ?? .distantPast
            var parent = MonitoredTask(id: "codex-group:" + rootID, provider: .codex,
                title: title, activity: tr("Статус не подтверждён", "Status unconfirmed"),
                isActive: false, progress: nil, progressKind: .none, steps: [],
                updatedAt: updated, isUnconfirmed: true, planConfirmed: false)
            parent.codexAgentCount = childIDs.count
            parent.codexAgentsUnconfirmed = childIDs.contains { child in
                byID[child]?.contains(where: { $0.isUnconfirmed }) ?? false
            }
            parent.codexAgents = details(for: childIDs)
            result.append(parent)
        }
        return Projection(tasks: result.sorted { $0.updatedAt > $1.updatedAt }, displayIDBySourceID: displayIDs)
    }

}
