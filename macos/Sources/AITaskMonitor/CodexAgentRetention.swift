import Foundation

/// All fields must come from the same fresh, strict verification of one
/// unambiguous session header. A cached/appending observation is insufficient.
/// This identifies a current file/header, not uninterrupted agent lifetime.
struct CodexVerifiedAgentIdentity: Equatable {
    let file: CodexFileIdentity
    let headerDigest: Data
    let parentID: String?
    let isRoot: Bool
}

/// A conservative in-memory projection for the source owner; not connected to
/// TaskStore or the UI. It neither reads a source nor proves an agent closed.
struct CodexAgentRetention {
    struct Member: Equatable {
        let id: String
        let parentID: String
        let identity: CodexVerifiedAgentIdentity
        let title: String
        /// A verified observation in this snapshot, not proof of a continuous lifetime.
        let current: Bool
        let active: Bool
        let statusUnconfirmed: Bool
        let conflict: Bool
    }

    struct Group: Equatable {
        let rootID: String
        let rootIdentity: CodexVerifiedAgentIdentity
        let members: [Member]
        let canAttach: Bool
        /// An opaque capability for retaining this exact root card only.
        let rootBinding: UUID?
        let rootCardRetained: Bool
        let conflictIDs: Set<String>
        var knownCount: Int { members.count }
        let countUnconfirmed = true
        let coverageUnconfirmed = true
        let closureUnconfirmed = true
        let continuityUnconfirmed = true
    }

    struct Snapshot {
        let groups: [Group]
        let conflictIDs: Set<String>
        let missingIdentityIDs: Set<String>
        let sourcePartial: Bool
        let sourceUnavailable: Bool
        let capacityExceeded: Bool
        let coverageUnconfirmed = true
        let closureUnconfirmed = true
        let continuityUnconfirmed = true
    }

    private struct Node: Equatable {
        let id: String
        let parentID: String?
        let identity: CodexVerifiedAgentIdentity
    }

    private struct Agent {
        let id: String
        let parentID: String
        let identity: CodexVerifiedAgentIdentity
        let rootID: String
        let ancestry: [String]
        var title: String
    }

    private struct RootBinding {
        let token: UUID
        let file: CodexFileIdentity
        let startKey: String
    }

    private let maximumAgents: Int
    private let maximumRoots: Int
    private var nodes: [String: Node] = [:]
    private var fileOwners: [CodexFileIdentity: String] = [:]
    private var agents: [String: Agent] = [:]
    private var roots: [String: CodexVerifiedAgentIdentity] = [:]
    private var rootBindings: [String: RootBinding] = [:]
    private var conflicts: Set<String> = []
    private var capacityExceeded = false

    init(maximumAgents: Int = 512, maximumRoots: Int = 64) {
        precondition((1...2048).contains(maximumAgents) && (1...256).contains(maximumRoots))
        self.maximumAgents = maximumAgents
        self.maximumRoots = maximumRoots
    }

    private static func normalizedID(_ value: String) -> String? {
        guard value.utf8.count == 36, let id = UUID(uuidString: value) else { return nil }
        return id.uuidString.lowercased()
    }

    private mutating func markConflict(_ id: String) {
        guard Self.normalizedID(id) != nil, !conflicts.contains(id) else { return }
        guard conflicts.count < 4 * (maximumAgents + maximumRoots) else {
            capacityExceeded = true
            return
        }
        conflicts.insert(id)
    }

    /// `identities` must contain only fresh strict proofs, each binding the
    /// displayed session ID, its parent/root classification and the file used
    /// by the task snapshot. A caller creates a new owner for another profile.
    /// `retainedRootBindings` may be passed only for the same card carried
    /// forward from a prior accepted snapshot, never by matching a new card's
    /// ID. No timeout, turn completion, failed read or missing file removes a member.
    mutating func observe(tasks: [MonitoredTask], identities: [String: CodexVerifiedAgentIdentity],
                          sourcePartial: Bool = false, sourceUnavailable: Bool = false,
                          conflictedIDs: Set<String> = [], retainedRootBindings: [String: UUID] = [:]) -> Snapshot {
        var taskByID: [String: MonitoredTask] = [:]
        var duplicateIDs: Set<String> = []
        let overInputLimit = tasks.count > 2048 || identities.count > 2048 || conflictedIDs.count > 2048 ||
            retainedRootBindings.count > 2048
        var transientConflicts = Set(conflictedIDs.prefix(2048).compactMap(Self.normalizedID))
        var missing: Set<String> = []
        let boundedTasks = overInputLimit ? [] : tasks
        for task in boundedTasks where task.provider == .codex {
            guard let id = Self.normalizedID(task.id) else { continue }
            if taskByID[id] != nil {
                duplicateIDs.insert(id)
                if sourceUnavailable { transientConflicts.insert(id) } else { markConflict(id) }
            } else {
                taskByID[id] = task
            }
        }

        var currentNodes: [String: Node] = [:]
        var carriedBindings: [String: UUID] = [:]
        if !overInputLimit {
            for (rawID, token) in retainedRootBindings {
                guard let id = Self.normalizedID(rawID) else { continue }
                if carriedBindings[id] != nil { transientConflicts.insert(id) }
                else { carriedBindings[id] = token }
            }
        }
        if overInputLimit { capacityExceeded = true }
        if !sourceUnavailable && !overInputLimit {
            for (rawID, proof) in identities {
                guard let id = Self.normalizedID(rawID) else { continue }
                guard proof.headerDigest.count == 32 else { missing.insert(id); continue }
                let parent = proof.parentID.flatMap(Self.normalizedID)
                guard (proof.isRoot && proof.parentID == nil) ||
                      (!proof.isRoot && parent != nil && parent != id) else {
                    missing.insert(id)
                    continue
                }
                let normalizedProof = CodexVerifiedAgentIdentity(file: proof.file, headerDigest: proof.headerDigest,
                                                                  parentID: parent, isRoot: proof.isRoot)
                let node = Node(id: id, parentID: parent, identity: normalizedProof)
                if currentNodes[id] != nil { markConflict(id); continue }
                currentNodes[id] = node
                if let old = nodes[id], old != node { markConflict(id) }
                if let owner = fileOwners[proof.file], owner != id {
                    markConflict(id)
                    markConflict(owner)
                }
            }
            for (id, task) in taskByID {
                if let old = nodes[id], let file = task.lastActivityFileIdentity, file != old.identity.file {
                    if task.lastActivityIdentityConfirmed == true { markConflict(id) }
                    else { transientConflicts.insert(id) }
                }
            }
        }

        var current: Set<String> = []
        if !sourceUnavailable && !overInputLimit {
            for id in taskByID.keys.sorted() {
                guard !duplicateIDs.contains(id), !conflicts.contains(id), !transientConflicts.contains(id),
                      let task = taskByID[id], task.isActive || task.isUnconfirmed || task.isWaiting else { continue }
                guard let first = currentNodes[id], !first.identity.isRoot,
                      task.lastActivityIdentityConfirmed == true, task.lastActivityFileIdentity == first.identity.file else {
                    if currentNodes[id]?.identity.isRoot != true { missing.insert(id) }
                    continue
                }
                var chain: [Node] = []
                var seen: Set<String> = []
                var seenFiles: [CodexFileIdentity: String] = [:]
                var cursor = id
                var valid = false
                for _ in 0..<128 {
                    guard !seen.contains(cursor) else {
                        for visited in seen { markConflict(visited) }
                        break
                    }
                    guard let node = currentNodes[cursor], !conflicts.contains(cursor),
                          !transientConflicts.contains(cursor), !duplicateIDs.contains(cursor) else {
                        missing.insert(cursor)
                        break
                    }
                    seen.insert(cursor)
                    if let owner = fileOwners[node.identity.file], owner != cursor {
                        markConflict(cursor); markConflict(owner)
                        break
                    }
                    if let owner = seenFiles[node.identity.file], owner != cursor {
                        markConflict(cursor); markConflict(owner)
                        break
                    }
                    seenFiles[node.identity.file] = cursor
                    if let associated = taskByID[cursor],
                       let file = associated.lastActivityFileIdentity, file != node.identity.file {
                        if associated.lastActivityIdentityConfirmed == true { markConflict(cursor) }
                        else { transientConflicts.insert(cursor) }
                        break
                    }
                    chain.append(node)
                    if node.identity.isRoot { valid = true; break }
                    guard let parent = node.parentID else { break }
                    cursor = parent
                }
                guard valid, chain.count >= 2, let root = chain.last else { continue }
                let newAgents = chain.filter { !$0.identity.isRoot && agents[$0.id] == nil }.count
                guard agents.count + newAgents <= maximumAgents,
                      roots[root.id] != nil || roots.count < maximumRoots else {
                    capacityExceeded = true
                    continue
                }
                roots[root.id] = root.identity
                for index in chain.indices.reversed() {
                    let node = chain[index]
                    if nodes[node.id] == nil {
                        nodes[node.id] = node
                        fileOwners[node.identity.file] = node.id
                    }
                    guard !node.identity.isRoot, let parent = node.parentID else { continue }
                    if agents[node.id] == nil {
                        agents[node.id] = Agent(id: node.id, parentID: parent, identity: node.identity,
                                                rootID: root.id, ancestry: chain[index...].map(\.id), title: "")
                    }
                }
                current.insert(id)
                if task.title.utf16.count <= 4096 &&
                    !task.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    agents[id]?.title = task.title
                }
            }
        }

        var groups: [Group] = []
        for rootID in roots.keys.sorted() {
            guard let rootIdentity = roots[rootID] else { continue }
            var groupConflicts: Set<String> = []
            let retained = agents.values.filter { $0.rootID == rootID }.sorted { $0.id < $1.id }
            let members = retained.map { agent -> Member in
                for ancestor in agent.ancestry where conflicts.contains(ancestor) || transientConflicts.contains(ancestor) {
                    groupConflicts.insert(ancestor)
                }
                let present = current.contains(agent.id) && !conflicts.contains(agent.id)
                let task = present ? taskByID[agent.id] : nil
                return Member(id: agent.id, parentID: agent.parentID, identity: agent.identity, title: agent.title,
                              current: present, active: present && (task?.isActive == true) && (task?.isUnconfirmed != true),
                              statusUnconfirmed: !present || (task?.isUnconfirmed == true),
                              conflict: conflicts.contains(agent.id) || transientConflicts.contains(agent.id))
            }
            if conflicts.contains(rootID) || transientConflicts.contains(rootID) { groupConflicts.insert(rootID) }
            let verifiedRoot = currentNodes[rootID].map { $0.identity == rootIdentity && $0.identity.isRoot } ?? false
            let rootCard = taskByID[rootID]
            let rootMatches: Bool
            if let rootCard {
                rootMatches = verifiedRoot && rootCard.lastActivityIdentityConfirmed == true &&
                    rootCard.lastActivityFileIdentity == rootIdentity.file &&
                    (rootCard.isActive || rootCard.isUnconfirmed || rootCard.isWaiting)
            } else {
                rootMatches = verifiedRoot
            }
            if rootMatches && groupConflicts.isEmpty, let rootCard, !rootCard.startKey.isEmpty,
               rootCard.startKey.utf8.count <= 512 {
                let old = rootBindings[rootID]
                if old == nil || old?.file != rootIdentity.file || old?.startKey != rootCard.startKey {
                    rootBindings[rootID] = RootBinding(token: UUID(), file: rootIdentity.file, startKey: rootCard.startKey)
                }
            }
            let oldBinding = rootBindings[rootID]
            let rootCardRetained: Bool
            if !rootMatches, let rootCard, let oldBinding {
                rootCardRetained = rootCard.isUnconfirmed && !rootCard.isActive && !rootCard.isWaiting &&
                    rootCard.lastActivityFileIdentity == oldBinding.file && rootCard.startKey == oldBinding.startKey &&
                    carriedBindings[rootID] == oldBinding.token
            } else {
                rootCardRetained = false
            }
            let canAttach = (rootMatches || rootCardRetained) && groupConflicts.isEmpty &&
                (rootCard != nil || members.contains(where: \.current))
            let binding = canAttach && rootCard != nil ? rootBindings[rootID]?.token : nil
            groups.append(Group(rootID: rootID, rootIdentity: rootIdentity, members: members,
                                canAttach: canAttach, rootBinding: binding,
                                rootCardRetained: canAttach && rootCardRetained, conflictIDs: groupConflicts))
        }
        return Snapshot(groups: groups, conflictIDs: conflicts.union(transientConflicts), missingIdentityIDs: missing,
                        sourcePartial: sourcePartial || overInputLimit, sourceUnavailable: sourceUnavailable,
                        capacityExceeded: capacityExceeded)
    }
}
