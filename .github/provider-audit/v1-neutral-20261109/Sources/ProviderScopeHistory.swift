import Foundation

// Process-local evidence only. Loss of identity history is permanent for this
// instance: later names must not inherit a forgotten namespace by inference.
struct ProviderScopeHistory {
    private(set) var seen: [Data: String] = [:]
    private(set) var disabled: Set<Data> = []
    private(set) var historyLost = false
    private(set) var stable: [Data: String] = [:]
    private(set) var previousConnected: [Data: String] = [:]
    private let maximumClaims = 256

    private static func key(_ name: String) -> Data { Data(name.utf8) }

    @discardableResult
    mutating func update(_ profiles: [DeepSeekProfile]) -> Bool {
        // Swift String equality treats canonically equivalent spellings alike.
        // Reject ambiguous names rather than merging two possible identities.
        guard Set(profiles.map(\.name)).count == profiles.count,
              profiles.filter({ $0.state == "connected" }).count <= maximumClaims,
              profiles.allSatisfy({ profile in
                  !profile.name.isEmpty && ["connected", "disconnected", "partial", "error"].contains(profile.state) &&
                  (profile.state == "connected" ? DeepSeekIntegration.validScope(profile.scope) :
                    (profile.state == "disconnected" ? (profile.scope == nil || DeepSeekIntegration.validScope(profile.scope)) : profile.scope == nil))
              }) else { return false }
        let old = seen
        let changed = profiles.contains { profile in
            guard ["connected", "disconnected"].contains(profile.state), let scope = profile.scope,
                  let previous = old[Self.key(profile.name)] else { return false }
            return previous != scope
        }
        for profile in profiles {
            let name = Self.key(profile.name)
            if profile.state == "connected", let scope = profile.scope {
                seen[name] = scope
                disabled.remove(name)
            } else if profile.state == "disconnected" {
                if let scope = profile.scope { seen[name] = scope }
                if seen[name] != nil { disabled.insert(name) }
            }
        }
        if !historyLost && (changed || seen.count > maximumClaims) {
            stable.removeAll()
            for (name, scope) in previousConnected {
                let current = profiles.filter { Self.key($0.name) == name && $0.state == "connected" && $0.scope == scope }
                guard current.count == 1, old[name] == scope else { continue }
                let oldConflict = old.contains { $0.key != name && $0.value == scope }
                let newConflict = profiles.contains { $0.state == "connected" && Self.key($0.name) != name && $0.scope == scope }
                if !oldConflict && !newConflict { stable[name] = scope }
            }
            historyLost = true
        }
        if historyLost {
            for name in Array(stable.keys) {
                guard let scope = stable[name] else { continue }
                let current = profiles.filter { Self.key($0.name) == name && $0.state == "connected" && $0.scope == scope }
                let oldConflict = old.contains { $0.key != name && $0.value == scope }
                let seenConflict = seen.contains { $0.key != name && $0.value == scope }
                if current.count != 1 || oldConflict || seenConflict { stable.removeValue(forKey: name) }
            }
        }
        if seen.count > maximumClaims {
            let current = Set(profiles.filter { $0.state == "connected" }.map { Self.key($0.name) })
            let removable = seen.keys.filter { !current.contains($0) }.sorted { $0.lexicographicallyPrecedes($1) }
            for name in removable where seen.count > maximumClaims {
                seen.removeValue(forKey: name)
                disabled.remove(name)
            }
        }
        previousConnected.removeAll(keepingCapacity: true)
        for profile in profiles where profile.state == "connected" {
            if let scope = profile.scope { previousConnected[Self.key(profile.name)] = scope }
        }
        return seen.count <= maximumClaims && disabled.count <= maximumClaims && stable.count <= maximumClaims && previousConnected.count <= maximumClaims
    }

    mutating func markScanFailed() {
        previousConnected.removeAll()
        if historyLost { stable.removeAll() }
    }

    mutating func markInvalidRoster() {
        // A rejected roster may contain unrecorded competing owners.
        previousConnected.removeAll()
        stable.removeAll()
        historyLost = true
    }

    mutating func markDisconnected(_ name: String) {
        let identity = Self.key(name)
        if seen[identity] != nil { disabled.insert(identity) }
        previousConnected.removeValue(forKey: identity)
        if historyLost { stable.removeValue(forKey: identity) }
    }

    func ambiguous(_ profiles: [DeepSeekProfile]) -> Set<String> {
        var owners: [String: Data] = [:], result: Set<String> = []
        func claim(_ name: Data, _ scope: String) {
            if let prior = owners[scope], prior != name { result.insert(scope) }
            else { owners[scope] = name }
        }
        for profile in profiles where profile.state == "connected" {
            guard let scope = profile.scope, DeepSeekIntegration.validScope(scope) else { continue }
            claim(Self.key(profile.name), scope)
        }
        for (name, scope) in seen where DeepSeekIntegration.validScope(scope) {
            let current = profiles.filter { Self.key($0.name) == name }
            if current.count != 1 || current[0].state != "connected" || current[0].scope != scope { claim(name, scope) }
        }
        if historyLost {
            for profile in profiles where profile.state == "connected" {
                guard let scope = profile.scope, DeepSeekIntegration.validScope(scope) else { continue }
                if stable[Self.key(profile.name)] != scope { result.insert(scope) }
            }
        }
        return result
    }

    func allowed(_ profiles: [DeepSeekProfile], scanFailed: Bool) -> Set<String> {
        guard !scanFailed else { return [] }
        let conflicts = ambiguous(profiles)
        return Set(profiles.compactMap { profile in
            guard profile.state == "connected", let scope = profile.scope,
                  DeepSeekIntegration.validScope(scope), !conflicts.contains(scope) else { return nil }
            return scope
        })
    }

    func uncertain(_ profiles: [DeepSeekProfile], scanFailed: Bool) -> Set<String> {
        var result = ambiguous(profiles)
        for (name, scope) in seen where !disabled.contains(name) && DeepSeekIntegration.validScope(scope) {
            // Once identity history is incomplete, a previously unverified
            // name must not expose its scope via the uncertain fallback.
            // Ambiguous live scopes above remain in the gap set and are
            // independently removed by the visibility filter.
            if historyLost && stable[name] != scope { continue }
            let current = profiles.filter { Self.key($0.name) == name }
            if scanFailed || current.count != 1 || current[0].state == "partial" || current[0].state == "error" {
                result.insert(scope)
            }
        }
        return result
    }
}
