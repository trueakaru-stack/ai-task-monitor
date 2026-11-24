import Foundation

// A capture is the already-reduced output of the serial source owner. A gap
// or a stale capture cannot prove that a missing task ended. Terminal IDs in
// such a capture remain evidence; an ID alone does not identify a turn.
struct ExternalProviderRefreshCapture {
    let tasks: [MonitoredTask]
    let terminalIDs: [TaskProvider: Set<String>]
    let gapProviders: Set<TaskProvider>
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
    private(set) var capacityExceeded = false

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
        let invalidProviders = Set(duplicates.map(\.provider))
        let uncertain = quality == .current ? capture.gapProviders.union(invalidProviders) : affected
        if !uncertain.isEmpty { markUncertain(uncertain) }

        if quality != .current || !capture.gapProviders.isEmpty || !duplicates.isEmpty {
            for (provider, ids) in capture.terminalIDs where providers.contains(provider) &&
                (quality != .current || uncertain.contains(provider)) {
                for id in ids {
                    if (pendingTerminalIDs[provider] ?? []).contains(id) { continue }
                    let count = pendingTerminalIDs.values.reduce(0) { $0 + $1.count }
                    if count < maximumTerminals { pendingTerminalIDs[provider, default: []].insert(id) }
                    else { capacityExceeded = true; uncertainProviders.insert(provider) }
                }
            }
        }

        // Only a current, gap-free result may replace unaffected prior data.
        let previousKeys = Set(retained.keys)
        let replaceable = providers.subtracting(uncertain)
        for key in Array(retained.keys) where replaceable.contains(key.provider) && !uncertainTasks.contains(key) {
            retained.removeValue(forKey: key)
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
                        capacityExceeded = true; uncertainProviders.insert(key.provider); continue
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
                capacityExceeded = true
                uncertainProviders.insert(key.provider)
            }
        }
    }

    private static func unconfirmed(_ task: MonitoredTask) -> MonitoredTask {
        var copy = TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        if copy.provider == .opencode { copy.steps = [] }
        return copy
    }
}
