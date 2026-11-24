import Foundation

// A capture is the already-reduced output of the serial source owner. A gap
// or a stale capture cannot prove that a missing task ended. Terminal IDs in
// such a capture remain evidence; an ID alone does not identify a turn.
struct ExternalProviderVerifiedTurn: Hashable {
    let id: String
    let startKey: String
}

struct ExternalProviderVerifiedSuccessor: Hashable {
    let id: String
    let oldStartKey: String
    let newStartKey: String
}

struct ExternalProviderRefreshCapture {
    let tasks: [MonitoredTask]
    let terminalIDs: [TaskProvider: Set<String>]
    let gapProviders: Set<TaskProvider>
    // These proofs must come from the adapter's verified source continuity,
    // not merely from comparing IDs or start keys between two snapshots.
    var verifiedActiveTurns: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    var verifiedEndedTurns: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    var verifiedSuccessors: [TaskProvider: Set<ExternalProviderVerifiedSuccessor>] = [:]
    // The adapter must prove a complete current roster, including absence;
    // merely completing a read or seeing an empty list is not enough.
    var completeProviders: Set<TaskProvider> = []
}

struct ExternalProviderRefreshCache {
    private struct Key: Hashable {
        let provider: TaskProvider
        let id: String
    }

    private let maximumTasks: Int
    private let maximumTerminals: Int
    private var retained: [Key: MonitoredTask] = [:]
    private var uncertainTasks: Set<Key> = []
    private(set) var uncertainProviders: Set<TaskProvider> = []
    private(set) var pendingTerminalIDs: [TaskProvider: Set<String>] = [:]
    private var taskCapacityLimitedProviders: Set<TaskProvider> = []
    private var terminalCapacityLimitedProviders: Set<TaskProvider> = []
    var capacityExceeded: Bool { !taskCapacityLimitedProviders.isEmpty || !terminalCapacityLimitedProviders.isEmpty }

    init(maximumTasks: Int = 512, maximumTerminals: Int = 2_048) {
        precondition((1...2_048).contains(maximumTasks) && (1...8_192).contains(maximumTerminals))
        self.maximumTasks = maximumTasks
        self.maximumTerminals = maximumTerminals
    }

    var tasks: [MonitoredTask] {
        retained.values.sorted { left, right in
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            if left.provider.rawValue != right.provider.rawValue { return left.provider.rawValue < right.provider.rawValue }
            return left.id < right.id
        }
    }

    // The owner calls this only after its monotonic timeout or an explicit
    // invalidation. A normal refresh request does not change visible status.
    mutating func markUncertain(_ providers: Set<TaskProvider>) {
        uncertainProviders.formUnion(providers)
        for key in Array(retained.keys) where providers.contains(key.provider) {
            guard let value = retained[key] else { continue }
            retained[key] = Self.unconfirmed(value)
            uncertainTasks.insert(key)
        }
    }

    mutating func apply(_ capture: ExternalProviderRefreshCapture?, quality: ExternalProviderRefreshQuality,
                        providers: Set<TaskProvider>) {
        guard let capture else {
            if quality != .current { markUncertain(providers) }
            return
        }
        let affected = providers.union(capture.gapProviders)
        let grouped = Dictionary(grouping: capture.tasks.filter { providers.contains($0.provider) }) {
            Key(provider: $0.provider, id: $0.id)
        }
        let duplicates = Set(grouped.filter { $0.value.count != 1 }.keys)
        let contradictory = Set(grouped.keys.filter { (capture.terminalIDs[$0.provider] ?? []).contains($0.id) })
        let invalidProviders = Set(duplicates.union(contradictory).map(\.provider))
        let uncertain = quality == .current ? capture.gapProviders.union(invalidProviders) : affected
        if !uncertain.isEmpty { markUncertain(uncertain) }

        if quality != .current || !capture.gapProviders.isEmpty || !duplicates.isEmpty || !contradictory.isEmpty {
            for (provider, ids) in capture.terminalIDs where providers.contains(provider) &&
                (quality != .current || uncertain.contains(provider)) {
                for id in ids {
                    rememberTerminal(id, provider: provider)
                }
            }
        }

        // Recovery needs an explicit source proof for the same turn, its
        // ending, or a successor ordered after it. Matching IDs alone are not
        // sufficient, particularly when a delayed terminal is pending.
        if quality == .current {
            for key in Array(uncertainTasks) where providers.contains(key.provider) && !uncertain.contains(key.provider) {
                guard let old = retained[key], !old.startKey.isEmpty else { continue }
                let oldTurn = ExternalProviderVerifiedTurn(id: key.id, startKey: old.startKey)
                let incoming = grouped[key].flatMap { $0.count == 1 ? $0.first : nil }
                let pendingTerminal = (pendingTerminalIDs[key.provider] ?? []).contains(key.id)
                let active = capture.verifiedActiveTurns[key.provider] ?? []
                if let incoming, incoming.isActive && !incoming.isUnconfirmed && !incoming.startKey.isEmpty {
                    let incomingTurn = ExternalProviderVerifiedTurn(id: key.id, startKey: incoming.startKey)
                    let sameTurn = incoming.startKey == old.startKey && !pendingTerminal && active.contains(oldTurn)
                    let successor = ExternalProviderVerifiedSuccessor(id: key.id, oldStartKey: old.startKey,
                                                                       newStartKey: incoming.startKey)
                    let nextTurn = incoming.startKey != old.startKey && active.contains(incomingTurn) &&
                        (capture.verifiedSuccessors[key.provider] ?? []).contains(successor)
                    if sameTurn || nextTurn {
                        uncertainTasks.remove(key)
                        if nextTurn { pendingTerminalIDs[key.provider]?.remove(key.id) }
                    }
                } else if incoming == nil && ((capture.verifiedEndedTurns[key.provider] ?? []).contains(oldTurn) ||
                            (capture.completeProviders.contains(key.provider) && !pendingTerminal)) {
                    retained.removeValue(forKey: key)
                    uncertainTasks.remove(key)
                    pendingTerminalIDs[key.provider]?.remove(key.id)
                }
            }
            pendingTerminalIDs = pendingTerminalIDs.filter { !$0.value.isEmpty }
        }

        // Absence in a current snapshot is not itself a terminal signal.
        let previousKeys = Set(retained.keys)
        let replaceable = providers.subtracting(uncertain)
        for key in Array(retained.keys) where replaceable.contains(key.provider) && !uncertainTasks.contains(key) {
            guard let old = retained[key] else { continue }
            if grouped[key] != nil {
                retained.removeValue(forKey: key)
                continue
            }
            let oldTurn = ExternalProviderVerifiedTurn(id: key.id, startKey: old.startKey)
            let ended = !old.startKey.isEmpty && (capture.verifiedEndedTurns[key.provider] ?? []).contains(oldTurn)
            let complete = capture.completeProviders.contains(key.provider) &&
                !(pendingTerminalIDs[key.provider] ?? []).contains(key.id)
            if ended || complete {
                retained.removeValue(forKey: key)
            } else {
                retained[key] = Self.unconfirmed(old)
                uncertainTasks.insert(key)
                uncertainProviders.insert(key.provider)
                if (capture.terminalIDs[key.provider] ?? []).contains(key.id) {
                    rememberTerminal(key.id, provider: key.provider)
                }
            }
        }
        let ordered = grouped.sorted { left, right in
            let leftPrior = previousKeys.contains(left.key), rightPrior = previousKeys.contains(right.key)
            if leftPrior != rightPrior { return leftPrior }
            if left.key.provider.rawValue != right.key.provider.rawValue {
                return left.key.provider.rawValue < right.key.provider.rawValue
            }
            return left.key.id < right.key.id
        }
        for (key, values) in ordered where values.count == 1 {
            guard let incoming = values.first else { continue }
            let mustRetain = uncertainTasks.contains(key) || uncertain.contains(key.provider) ||
                (pendingTerminalIDs[key.provider] ?? []).contains(key.id)
            if mustRetain {
                // Reuse old content when a later capture may refer to another
                // turn with the same ID; never guess which turn it belongs to.
                if retained[key] == nil {
                    guard retained.count < maximumTasks else {
                        taskCapacityLimitedProviders.insert(key.provider); uncertainProviders.insert(key.provider); continue
                    }
                    retained[key] = Self.unconfirmed(incoming)
                } else if let old = retained[key] {
                    retained[key] = Self.unconfirmed(old)
                }
                uncertainTasks.insert(key)
                uncertainProviders.insert(key.provider)
            } else if retained.count < maximumTasks || retained[key] != nil {
                retained[key] = incoming
            } else {
                taskCapacityLimitedProviders.insert(key.provider)
                uncertainProviders.insert(key.provider)
            }
        }
        if quality == .current {
            for provider in capture.completeProviders.intersection(providers).subtracting(uncertain) {
                let completeKeys = grouped.keys.filter { $0.provider == provider }
                let allRepresented = completeKeys.allSatisfy { retained[$0] != nil && !uncertainTasks.contains($0) }
                if allRepresented && !uncertainTasks.contains(where: { $0.provider == provider }) &&
                    (pendingTerminalIDs[provider] ?? []).isEmpty {
                    taskCapacityLimitedProviders.remove(provider)
                }
                if allRepresented && !uncertainTasks.contains(where: { $0.provider == provider }) &&
                    (pendingTerminalIDs[provider] ?? []).isEmpty &&
                    !taskCapacityLimitedProviders.contains(provider) && !terminalCapacityLimitedProviders.contains(provider) {
                    uncertainProviders.remove(provider)
                }
            }
        }
    }

    private mutating func rememberTerminal(_ id: String, provider: TaskProvider) {
        if (pendingTerminalIDs[provider] ?? []).contains(id) { return }
        let count = pendingTerminalIDs.values.reduce(0) { $0 + $1.count }
        if count < maximumTerminals { pendingTerminalIDs[provider, default: []].insert(id) }
        else { terminalCapacityLimitedProviders.insert(provider); uncertainProviders.insert(provider) }
    }

    private static func unconfirmed(_ task: MonitoredTask) -> MonitoredTask {
        var copy = TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        if copy.provider == .opencode { copy.steps = [] }
        return copy
    }
}
