import Foundation

/// Presentation only: the source tasks remain separate for lifecycle and diagnostics.
enum CodexTaskGrouping {
    struct Projection {
        let tasks: [MonitoredTask]
        let displayIDBySourceID: [String: String]
    }

    /// Only hide the exact file currently verified as an assistant. A title,
    /// session ID or retained card on its own is never identity evidence.
    static func compactVisibleIndices(_ tasks: [MonitoredTask], confirmedChildren: [String: CodexFileIdentity]) -> [Int] {
        tasks.indices.filter { index in
            let task = tasks[index]
            guard task.provider == .codex, let file = task.lastActivityFileIdentity,
                  let verified = confirmedChildren[task.id.lowercased()] else { return true }
            return file != verified
        }
    }

    static func compactSelectionSourceIndex(_ tasks: [MonitoredTask], confirmedChildren: [String: CodexFileIdentity],
                                            chosenID: String?, previous: MonitoredTask?, previousVisibleIndex: Int?) -> Int? {
        let visible = Array(compactVisibleIndices(tasks, confirmedChildren: confirmedChildren).prefix(3))
        if let previous, previous.id == chosenID {
            let identities = visible.filter { tasks[$0].compactSelectionKey == previous.compactSelectionKey }
            if identities.count == 1 { return identities[0] }
            let identical = identities.filter { tasks[$0] == previous }
            if identical.count == 1 { return identical[0] }
            if let previousVisibleIndex, visible.indices.contains(previousVisibleIndex),
               tasks[visible[previousVisibleIndex]] == previous { return visible[previousVisibleIndex] }
            if let file = previous.lastActivityFileIdentity {
                let sameFile = visible.filter {
                    tasks[$0].provider == previous.provider && tasks[$0].id == previous.id &&
                    tasks[$0].lastActivityFileIdentity == file &&
                    (tasks[$0].startKey.isEmpty || previous.startKey.isEmpty)
                }
                if sameFile.count == 1 { return sameFile[0] }
            }
        }
        if let chosenID {
            let matches = visible.filter { tasks[$0].id == chosenID }
            if matches.count == 1 { return matches[0] }
        }
        return visible.first
    }

    // Preserve a click made during a source read. A new turn can change its
    // selection key, so a unique verified file may identify the same chat.
    // Duplicates and missing file identity are never resolved by guessing.
    static func manualRefreshMatch(_ current: [MonitoredTask], previous: [MonitoredTask], selected: MonitoredTask) -> Int? {
        let oldExact = previous.indices.filter { previous[$0].compactSelectionKey == selected.compactSelectionKey }
        let exact = current.indices.filter { current[$0].compactSelectionKey == selected.compactSelectionKey }
        guard oldExact.count == 1 else { return nil }
        if selected.provider == .claude {
            // A Claude card represents the same unique session even when a
            // newer prompt changes its turn key during a source read.
            let oldSession = previous.indices.filter { previous[$0].provider == .claude && previous[$0].id == selected.id }
            let session = current.indices.filter { current[$0].provider == .claude && current[$0].id == selected.id }
            return oldSession.count == 1 && session.count == 1 ? session[0] : nil
        }
        guard selected.provider == .codex, let file = selected.lastActivityFileIdentity else {
            let oldSource = previous.filter { $0.provider == selected.provider && $0.id == selected.id }
            let source = current.filter { $0.provider == selected.provider && $0.id == selected.id }
            return oldSource.count == 1 && source.count == 1 && exact.count == 1 ? exact[0] : nil
        }
        let oldSameFile = previous.indices.filter {
            previous[$0].provider == selected.provider && previous[$0].id == selected.id &&
                previous[$0].lastActivityFileIdentity == file
        }
        let sameFile = current.indices.filter {
            current[$0].provider == selected.provider && current[$0].id == selected.id &&
                current[$0].lastActivityFileIdentity == file
        }
        guard oldSameFile.count == 1, sameFile.count == 1 else { return nil }
        guard exact.isEmpty || (exact.count == 1 && exact[0] == sameFile[0]) else { return nil }
        return sameFile[0]
    }

    static func compactSnapshotChanged(_ previous: [MonitoredTask], _ current: [MonitoredTask],
                                       confirmedChildren: [String: CodexFileIdentity]) -> Bool {
        let old = compactVisibleIndices(previous, confirmedChildren: confirmedChildren).prefix(3).map { previous[$0] }
        let new = compactVisibleIndices(current, confirmedChildren: confirmedChildren).prefix(3).map { current[$0] }
        let oldKeys = old.map(\.compactSelectionKey)
        let newKeys = new.map(\.compactSelectionKey)
        guard oldKeys == newKeys else { return true }
        let counts = Dictionary(grouping: oldKeys, by: { $0 }).mapValues(\.count)
        return old.indices.contains { index in
            (counts[oldKeys[index]] ?? 0) > 1 && old[index] != new[index]
        }
    }

    static func project(_ source: [MonitoredTask], parents: [String: String], titles: [String: String],
                        confirmedRoots: Set<String> = []) -> [MonitoredTask] {
        makeProjection(source, parents: parents, titles: titles, confirmedRoots: confirmedRoots).tasks
    }

    static func makeProjection(_ source: [MonitoredTask], parents: [String: String], titles: [String: String],
                               confirmedRoots: Set<String> = []) -> Projection {
        let visible = source.filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
        let eligible = visible.filter { $0.provider == .codex && UUID(uuidString: $0.id) != nil }
        guard eligible.count <= 512, parents.count <= 2_048 else {
            return Projection(tasks: visible, displayIDBySourceID: [:])
        }
        let byID = Dictionary(grouping: eligible, by: { $0.id.lowercased() })
        let roots = Set(confirmedRoots.filter { UUID(uuidString: $0) != nil }.map { $0.lowercased() })
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
                guard !roots.contains(current), !conflicts.contains(current), !linkConflicts.contains(current), let parent = parentByID[current],
                      !conflicts.contains(parent), !linkConflicts.contains(parent), visited.insert(parent).inserted else { return nil }
                if parentByID[parent] != nil {
                    current = parent
                    continue
                }
                guard roots.contains(parent) else { return nil }
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
                let activity = (!child.isUnconfirmed || child.lastActivityIdentityConfirmed == true)
                    ? (child.lastKnownActivity ?? child.activity) : child.activity
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
