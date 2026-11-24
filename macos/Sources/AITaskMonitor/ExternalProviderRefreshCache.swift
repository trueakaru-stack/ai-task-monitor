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

struct ExternalProviderQuarantinedEvidence {
    let revision: UInt64
    let tasks: [MonitoredTask]
    let terminalIDs: Set<String>
    let currentTerminalIDs: Set<String>
    let terminalRevisions: [String: UInt64]
    let gap: Bool
}

struct ExternalProviderRefreshCapture {
    let tasks: [MonitoredTask]
    let terminalIDs: [TaskProvider: Set<String>]
    let gapProviders: Set<TaskProvider>
    // These proofs must come from the adapter's verified source continuity,
    // not merely from comparing IDs or start keys between two snapshots.
    var verifiedActiveTurns: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    var verifiedEndedTurns: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    // This proof also attributes every pending terminal for this ID to the
    // ended turn; a turn-specific ending by itself is not sufficient.
    var verifiedEndedAfterAllTerminals: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    var verifiedSuccessors: [TaskProvider: Set<ExternalProviderVerifiedSuccessor>] = [:]
    // The adapter proves this active turn follows all retained terminal
    // signals for the ID; a later timestamp or matching ID is insufficient.
    var verifiedPostTerminalActiveTurns: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:]
    // Terminal ordering proofs apply only to the exact per-ID evidence
    // revision supplied to the adapter, not to later terminal observations.
    var verifiedTerminalRevisions: [TaskProvider: [String: UInt64]] = [:]
    // The adapter must prove a complete current roster, including absence;
    // merely completing a read or seeing an empty list is not enough.
    var completeProviders: Set<TaskProvider> = []
    // The generation is captured before reading each provider. A missing
    // value represents the initial generation only.
    var sourceGenerations: [TaskProvider: UInt64] = [:]
    // The adapter has incorporated the exact quarantined evidence revision
    // into this complete capture; a later quarantine invalidates this proof.
    var reconciledEvidenceRevisions: [TaskProvider: UInt64] = [:]
}

struct ExternalProviderRefreshCache {
    private struct Key: Hashable {
        let provider: TaskProvider
        let id: String
    }
    private struct QuarantineKey: Hashable {
        let provider: TaskProvider
        let id: String
        let startKey: String
        let generation: UInt64
        let ordinal: Int
    }

    private let maximumTasks: Int
    private let maximumTerminals: Int
    private var retained: [Key: MonitoredTask] = [:]
    private var quarantined: [QuarantineKey: MonitoredTask] = [:]
    private var uncertainTasks: Set<Key> = []
    private(set) var uncertainProviders: Set<TaskProvider> = []
    private var ordinaryTerminals: [TaskProvider: Set<String>] = [:]
    private var crossGenerationTerminals: [TaskProvider: Set<String>] = [:]
    private var terminalRevisions: [TaskProvider: [String: UInt64]] = [:]
    private var terminalSequence: UInt64 = 0
    private var quarantinedGaps: Set<TaskProvider> = []
    private var evidenceRevisions: [TaskProvider: UInt64] = [:]
    private var taskCapacityLimitedProviders: Set<TaskProvider> = []
    private var quarantinedCapacityLimitedProviders: Set<TaskProvider> = []
    private var terminalCapacityLimitedProviders: Set<TaskProvider> = []
    private var disconnectedProviders: Set<TaskProvider> = []
    private var reconnectingProviders: Set<TaskProvider> = []
    private(set) var sourceGenerations: [TaskProvider: UInt64] = [:]
    var capacityExceeded: Bool {
        !taskCapacityLimitedProviders.isEmpty || !quarantinedCapacityLimitedProviders.isEmpty ||
            !terminalCapacityLimitedProviders.isEmpty
    }
    var quarantinedTaskCount: Int { quarantined.count }

    var pendingTerminalIDs: [TaskProvider: Set<String>] {
        var result = ordinaryTerminals
        for (provider, ids) in crossGenerationTerminals { result[provider, default: []].formUnion(ids) }
        return result
    }

    // Snapshots here are reducer outputs, not a proof that the original V1/V2
    // event stream was complete. The adapter must verify its own history.
    func quarantinedEvidence(for provider: TaskProvider) -> ExternalProviderQuarantinedEvidence {
        let current = ordinaryTerminals[provider] ?? []
        let cross = crossGenerationTerminals[provider] ?? []
        let pending = current.union(cross)
        return ExternalProviderQuarantinedEvidence(revision: evidenceRevisions[provider] ?? 0,
            tasks: quarantined.filter { $0.key.provider == provider }.map(\.value),
            terminalIDs: cross, currentTerminalIDs: current,
            terminalRevisions: (terminalRevisions[provider] ?? [:]).filter { pending.contains($0.key) },
            gap: quarantinedGaps.contains(provider) || quarantinedCapacityLimitedProviders.contains(provider) ||
                terminalCapacityLimitedProviders.contains(provider))
    }

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
    mutating func markUncertain(_ providers: Set<TaskProvider>, sourceGenerations supplied: [TaskProvider: UInt64] = [:]) {
        let eligible = eligibleProviders(providers, supplied: supplied)
        markUncertainEligible(eligible)
    }

    private mutating func markUncertainEligible(_ providers: Set<TaskProvider>) {
        uncertainProviders.formUnion(providers)
        for key in Array(retained.keys) where providers.contains(key.provider) {
            guard let value = retained[key] else { continue }
            retained[key] = Self.unconfirmed(value)
            uncertainTasks.insert(key)
        }
    }

    // These transitions require a confirmed source change, not a missing or
    // delayed read. The new generation rejects older captures and handoffs.
    @discardableResult
    mutating func confirmDisconnected(_ provider: TaskProvider) -> UInt64? {
        guard let next = advanceGeneration(provider) else { return nil }
        disconnectedProviders.insert(provider)
        reconnectingProviders.remove(provider)
        retained = retained.filter { $0.key.provider != provider }
        quarantined = quarantined.filter { $0.key.provider != provider }
        uncertainTasks = Set(uncertainTasks.filter { $0.provider != provider })
        uncertainProviders.remove(provider)
        ordinaryTerminals.removeValue(forKey: provider)
        crossGenerationTerminals.removeValue(forKey: provider)
        terminalRevisions.removeValue(forKey: provider)
        quarantinedGaps.remove(provider)
        taskCapacityLimitedProviders.remove(provider)
        quarantinedCapacityLimitedProviders.remove(provider)
        terminalCapacityLimitedProviders.remove(provider)
        return next
    }

    @discardableResult
    mutating func beginReconnection(_ provider: TaskProvider) -> UInt64? {
        guard let next = advanceGeneration(provider) else { return nil }
        disconnectedProviders.remove(provider)
        reconnectingProviders.insert(provider)
        markUncertainEligible([provider])
        return next
    }

    private mutating func advanceGeneration(_ provider: TaskProvider) -> UInt64? {
        let current = sourceGenerations[provider] ?? 0
        guard current < UInt64.max else {
            markUncertainEligible([provider])
            disconnectedProviders.insert(provider)
            return nil
        }
        guard advanceEvidenceRevision(provider) else {
            disconnectedProviders.insert(provider)
            return nil
        }
        let next = current + 1
        sourceGenerations[provider] = next
        return next
    }

    private mutating func advanceEvidenceRevision(_ provider: TaskProvider) -> Bool {
        let current = evidenceRevisions[provider] ?? 0
        guard current < UInt64.max else {
            terminalCapacityLimitedProviders.insert(provider)
            markUncertainEligible([provider])
            return false
        }
        evidenceRevisions[provider] = current + 1
        return true
    }

    private func eligibleProviders(_ providers: Set<TaskProvider>, supplied: [TaskProvider: UInt64]) -> Set<TaskProvider> {
        Set(providers.filter { !disconnectedProviders.contains($0) && (supplied[$0] ?? 0) == (sourceGenerations[$0] ?? 0) })
    }

    mutating func apply(_ capture: ExternalProviderRefreshCapture?, quality: ExternalProviderRefreshQuality,
                        providers requestedProviders: Set<TaskProvider>, sourceGenerations supplied: [TaskProvider: UInt64] = [:]) {
        var observedGenerations = supplied
        if let capture {
            observedGenerations.merge(capture.sourceGenerations) { _, captured in captured }
            preserveCrossGeneration(capture, requested: requestedProviders, supplied: observedGenerations)
        }
        let providers = eligibleProviders(requestedProviders, supplied: observedGenerations)
        guard !providers.isEmpty else { return }
        guard let capture else {
            markUncertainEligible(providers)
            return
        }
        let gaps = capture.gapProviders.intersection(providers)
        let affected = providers
        let grouped = Dictionary(grouping: capture.tasks.filter { providers.contains($0.provider) }) {
            Key(provider: $0.provider, id: $0.id)
        }
        let duplicates = Set(grouped.filter { $0.value.count != 1 }.keys)
        let contradictory = Set(grouped.keys.filter { (capture.terminalIDs[$0.provider] ?? []).contains($0.id) })
        let invalidProviders = Set(duplicates.union(contradictory).map(\.provider))
        let uncertain = quality == .current ? gaps.union(invalidProviders) : affected
        if !uncertain.isEmpty { markUncertainEligible(uncertain) }

        if quality == .current {
            for (provider, revision) in capture.reconciledEvidenceRevisions where
                capture.completeProviders.contains(provider) && providers.contains(provider) &&
                !uncertain.contains(provider) && !quarantinedCapacityLimitedProviders.contains(provider) &&
                !terminalCapacityLimitedProviders.contains(provider) && revision == (evidenceRevisions[provider] ?? 0) {
                quarantined = quarantined.filter { $0.key.provider != provider }
                let cleared = crossGenerationTerminals.removeValue(forKey: provider) ?? []
                for id in cleared where !(ordinaryTerminals[provider] ?? []).contains(id) {
                    terminalRevisions[provider]?.removeValue(forKey: id)
                }
                if terminalRevisions[provider]?.isEmpty == true { terminalRevisions.removeValue(forKey: provider) }
                quarantinedGaps.remove(provider)
            }
        }

        if quality != .current || !gaps.isEmpty || !duplicates.isEmpty || !contradictory.isEmpty {
            for (provider, ids) in capture.terminalIDs where providers.contains(provider) &&
                (quality != .current || uncertain.contains(provider)) {
                for id in ids {
                    rememberTerminal(id, provider: provider)
                }
            }
        }

        if quality == .current {
            for (provider, ids) in capture.terminalIDs where providers.contains(provider) && !uncertain.contains(provider) {
                for id in ids {
                    let key = Key(provider: provider, id: id)
                    let old = retained[key]
                    let ended = old.map {
                        !$0.startKey.isEmpty &&
                            (capture.verifiedEndedTurns[provider] ?? []).contains(
                                ExternalProviderVerifiedTurn(id: id, startKey: $0.startKey))
                    } ?? false
                    if ended && grouped[key] == nil && !(pendingTerminalIDs[provider] ?? []).contains(id) { continue }
                    rememberTerminal(id, provider: provider)
                    uncertainProviders.insert(provider)
                }
            }
        }

        // Recovery needs an explicit source proof for the same turn, its
        // ending, or a successor ordered after it. Matching IDs alone are not
        // sufficient, particularly when a delayed terminal is pending.
        if quality == .current {
            for (key, values) in grouped where values.count == 1 && retained[key] == nil &&
                !uncertain.contains(key.provider) && (pendingTerminalIDs[key.provider] ?? []).contains(key.id) {
                guard let incoming = values.first, incoming.isActive, !incoming.isUnconfirmed,
                      !incoming.startKey.isEmpty else { continue }
                let turn = ExternalProviderVerifiedTurn(id: key.id, startKey: incoming.startKey)
                if (capture.verifiedActiveTurns[key.provider] ?? []).contains(turn) &&
                    (capture.verifiedPostTerminalActiveTurns[key.provider] ?? []).contains(turn) &&
                    terminalProofMatches(capture, provider: key.provider, id: key.id) {
                    clearTerminals(key.id, provider: key.provider)
                }
            }
            for key in Array(uncertainTasks) where providers.contains(key.provider) && !uncertain.contains(key.provider) &&
                !quarantinedCapacityLimitedProviders.contains(key.provider) &&
                !terminalCapacityLimitedProviders.contains(key.provider) {
                guard let old = retained[key] else { continue }
                let incoming = grouped[key].flatMap { $0.count == 1 ? $0.first : nil }
                let pendingTerminal = (pendingTerminalIDs[key.provider] ?? []).contains(key.id)
                if incoming == nil && capture.completeProviders.contains(key.provider) && !pendingTerminal {
                    retained.removeValue(forKey: key)
                    uncertainTasks.remove(key)
                    continue
                }
                guard !old.startKey.isEmpty else { continue }
                let oldTurn = ExternalProviderVerifiedTurn(id: key.id, startKey: old.startKey)
                let active = capture.verifiedActiveTurns[key.provider] ?? []
                if let incoming, incoming.isActive && !incoming.isUnconfirmed && !incoming.startKey.isEmpty {
                    let incomingTurn = ExternalProviderVerifiedTurn(id: key.id, startKey: incoming.startKey)
                    let sameTurn = incoming.startKey == old.startKey && !pendingTerminal && active.contains(oldTurn)
                    let successor = ExternalProviderVerifiedSuccessor(id: key.id, oldStartKey: old.startKey,
                                                                       newStartKey: incoming.startKey)
                    let nextTurn = !pendingTerminal && incoming.startKey != old.startKey && active.contains(incomingTurn) &&
                        (capture.verifiedSuccessors[key.provider] ?? []).contains(successor)
                    let afterTerminal = pendingTerminal && active.contains(incomingTurn) &&
                        (capture.verifiedPostTerminalActiveTurns[key.provider] ?? []).contains(incomingTurn) &&
                        terminalProofMatches(capture, provider: key.provider, id: key.id)
                    if sameTurn || nextTurn || afterTerminal {
                        uncertainTasks.remove(key)
                        if afterTerminal { clearTerminals(key.id, provider: key.provider) }
                    }
                } else if incoming == nil && (capture.verifiedEndedTurns[key.provider] ?? []).contains(oldTurn) &&
                    (!pendingTerminal || ((capture.verifiedEndedAfterAllTerminals[key.provider] ?? []).contains(oldTurn) &&
                        terminalProofMatches(capture, provider: key.provider, id: key.id))) {
                    retained.removeValue(forKey: key)
                    uncertainTasks.remove(key)
                    clearTerminals(key.id, provider: key.provider)
                }
            }
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
            let turn = ExternalProviderVerifiedTurn(id: key.id, startKey: incoming.startKey)
            let unprovenReconnect = reconnectingProviders.contains(key.provider) &&
                (incoming.startKey.isEmpty || !(capture.verifiedActiveTurns[key.provider] ?? []).contains(turn))
            let hasQuarantinedEvent = quarantined.keys.contains { $0.provider == key.provider && $0.id == key.id }
            let mustRetain = uncertainTasks.contains(key) || uncertain.contains(key.provider) ||
                (pendingTerminalIDs[key.provider] ?? []).contains(key.id) || unprovenReconnect || hasQuarantinedEvent ||
                quarantinedCapacityLimitedProviders.contains(key.provider) || terminalCapacityLimitedProviders.contains(key.provider)
            if mustRetain {
                // Reuse old content when a later capture may refer to another
                // turn with the same ID; never guess which turn it belongs to.
                if retained[key] == nil {
                    guard retained.count + quarantined.count < maximumTasks else {
                        taskCapacityLimitedProviders.insert(key.provider); uncertainProviders.insert(key.provider); continue
                    }
                    retained[key] = Self.unconfirmed(incoming)
                } else if let old = retained[key] {
                    retained[key] = Self.unconfirmed(old)
                }
                uncertainTasks.insert(key)
                uncertainProviders.insert(key.provider)
            } else if retained.count + quarantined.count < maximumTasks || retained[key] != nil {
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
                let hasQuarantined = quarantined.keys.contains { $0.provider == provider } || quarantinedGaps.contains(provider)
                if allRepresented && !uncertainTasks.contains(where: { $0.provider == provider }) &&
                    (pendingTerminalIDs[provider] ?? []).isEmpty && !hasQuarantined {
                    taskCapacityLimitedProviders.remove(provider)
                    reconnectingProviders.remove(provider)
                }
                if allRepresented && !uncertainTasks.contains(where: { $0.provider == provider }) &&
                    (pendingTerminalIDs[provider] ?? []).isEmpty && !hasQuarantined &&
                    !taskCapacityLimitedProviders.contains(provider) &&
                    !quarantinedCapacityLimitedProviders.contains(provider) && !terminalCapacityLimitedProviders.contains(provider) {
                    uncertainProviders.remove(provider)
                }
            }
        }
    }

    // An old in-flight read can contain events emitted after reconnection.
    // Keep those events out of the UI but retain bounded evidence until a
    // source-specific proof accounts for them.
    private mutating func preserveCrossGeneration(_ capture: ExternalProviderRefreshCapture,
                                                  requested: Set<TaskProvider>, supplied: [TaskProvider: UInt64]) {
        let stale = Set(requested.filter {
            !disconnectedProviders.contains($0) && (sourceGenerations[$0] ?? 0) > 0 &&
                (supplied[$0] ?? 0) != (sourceGenerations[$0] ?? 0)
        })
        guard !stale.isEmpty else { return }
        markUncertainEligible(stale)
        var versioned: Set<TaskProvider> = []
        for provider in stale {
            let items = capture.tasks.filter { $0.provider == provider }
            let ids = capture.terminalIDs[provider] ?? []
            let gap = capture.gapProviders.contains(provider)
            guard !items.isEmpty || !ids.isEmpty || gap else { continue }
            guard advanceEvidenceRevision(provider) else { continue }
            versioned.insert(provider)
            if gap { quarantinedGaps.insert(provider) }
            for id in ids { rememberTerminal(id, provider: provider, crossGeneration: true) }
        }
        for task in capture.tasks where versioned.contains(task.provider) {
            let generation = supplied[task.provider] ?? 0
            let matches = quarantined.filter {
                $0.key.provider == task.provider && $0.key.id == task.id &&
                    $0.key.startKey == task.startKey && $0.key.generation == generation
            }
            if matches.values.contains(task) { continue }
            let quarantineLimit = max(1, maximumTasks / 2)
            guard quarantined.count < quarantineLimit, retained.count + quarantined.count < maximumTasks else {
                quarantinedCapacityLimitedProviders.insert(task.provider)
                continue
            }
            let ordinal = (matches.keys.map(\.ordinal).max() ?? -1) + 1
            let key = QuarantineKey(provider: task.provider, id: task.id, startKey: task.startKey,
                                    generation: generation, ordinal: ordinal)
            quarantined[key] = task
        }
    }

    private mutating func rememberTerminal(_ id: String, provider: TaskProvider, crossGeneration: Bool = false) {
        guard terminalSequence < UInt64.max else {
            terminalCapacityLimitedProviders.insert(provider)
            markUncertainEligible([provider])
            return
        }
        terminalSequence += 1
        let existing = crossGeneration ? crossGenerationTerminals[provider] : ordinaryTerminals[provider]
        let count = ordinaryTerminals.values.reduce(0) { $0 + $1.count } +
            crossGenerationTerminals.values.reduce(0) { $0 + $1.count }
        if (existing ?? []).contains(id) || count < maximumTerminals {
            terminalRevisions[provider, default: [:]][id] = terminalSequence
            if crossGeneration { crossGenerationTerminals[provider, default: []].insert(id) }
            else { ordinaryTerminals[provider, default: []].insert(id) }
        } else {
            // Invalidate a proof for this ID even when the second kind of
            // evidence could not be stored at capacity.
            if terminalRevisions[provider]?[id] != nil {
                terminalRevisions[provider]?[id] = terminalSequence
            }
            terminalCapacityLimitedProviders.insert(provider)
            markUncertainEligible([provider])
        }
    }

    private func terminalProofMatches(_ capture: ExternalProviderRefreshCapture,
                                      provider: TaskProvider, id: String) -> Bool {
        guard let current = terminalRevisions[provider]?[id] else { return false }
        return capture.verifiedTerminalRevisions[provider]?[id] == current
    }

    private mutating func clearTerminals(_ id: String, provider: TaskProvider) {
        ordinaryTerminals[provider]?.remove(id)
        crossGenerationTerminals[provider]?.remove(id)
        terminalRevisions[provider]?.removeValue(forKey: id)
        if ordinaryTerminals[provider]?.isEmpty == true { ordinaryTerminals.removeValue(forKey: provider) }
        if crossGenerationTerminals[provider]?.isEmpty == true { crossGenerationTerminals.removeValue(forKey: provider) }
        if terminalRevisions[provider]?.isEmpty == true { terminalRevisions.removeValue(forKey: provider) }
    }

    private static func unconfirmed(_ task: MonitoredTask) -> MonitoredTask {
        var copy = TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        if copy.provider == .opencode { copy.steps = [] }
        return copy
    }
}
