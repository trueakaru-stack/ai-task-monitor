import CoreFoundation
import Foundation

// Candidate protocol gate. Authorization by this gate is necessary but not
// sufficient to assert that a provider's status is current: the consumer must
// also enforce the version-specific observer and source-boundary contract.
struct ExternalProviderV2Scope: Hashable {
    let provider: String
    let scope: String

    var valid: Bool {
        if provider == "opencode" { return scope == "global" }
        return provider == "deepseek" && Self.hex(scope)
    }

    static func hex(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct ExternalProviderV2Notice {
    let scope: ExternalProviderV2Scope
    let generation: String
    let instance: String
    let ticket: String?
    let event: ExternalProviderEvent?
    let gap: Bool
}

final class ExternalProviderV2Broker {
    private struct Producer {
        var sequence: Int64 = 0
        var lastHello: UInt64
        var valid = true
    }
    private struct State {
        let generation: String
        var ticket: String?
        var seen = false
        var producers: [String: Producer] = [:]
    }
    private struct PendingGap: Hashable {
        let generation: String
        let instance: String
        let ticket: String?
    }
    private let lock = NSLock()
    // A socket response must be written before its event is made visible. If
    // the write fails, the sender cannot know whether it was accepted.
    private let deliveryLock = NSLock()
    private let pendingLock = NSLock()
    private var pendingScope: ExternalProviderV2Scope?
    private var scopes: [ExternalProviderV2Scope: State] = [:]
    private var queue: [ExternalProviderV2Notice] = []
    private var pendingGaps: [ExternalProviderV2Scope: Set<PendingGap>] = [:]
    private let maxScopes = 257, maxProducers = 32, maxQueue = 1024

    @discardableResult
    func configure(_ scope: ExternalProviderV2Scope, generation: String) -> Bool {
        guard scope.valid, ExternalProviderV2Scope.hex(generation) else { return false }
        lock.lock(); defer { lock.unlock() }
        let retainedScopes = Set(scopes.keys).union(pendingGaps.keys)
        guard retainedScopes.contains(scope) || retainedScopes.count < maxScopes else { return false }
        if let old = scopes[scope] {
            guard old.generation != generation else { return false }
            for instance in old.producers.keys { rememberGap(scope, old.generation, instance, old.ticket) }
        }
        scopes[scope] = State(generation: generation, ticket: nil)
        return true
    }

    @discardableResult
    func acknowledgeRestart(_ scope: ExternalProviderV2Scope, generation: String, ticket: String) -> Bool {
        guard ExternalProviderV2Scope.hex(ticket) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard var state = scopes[scope], state.generation == generation, state.seen,
              state.ticket != ticket else { return false }
        for instance in state.producers.keys { rememberGap(scope, state.generation, instance, state.ticket) }
        state.ticket = ticket
        state.producers.removeAll()
        scopes[scope] = state
        return true
    }

    func hasSeenInstance(_ scope: ExternalProviderV2Scope, generation: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = scopes[scope] else { return false }
        return state.generation == generation && state.seen
    }

    func revoke(_ scope: ExternalProviderV2Scope) {
        lock.lock(); defer { lock.unlock() }
        guard let state = scopes.removeValue(forKey: scope) else { return }
        for instance in state.producers.keys { rememberGap(scope, state.generation, instance, state.ticket) }
    }

    // The runtime has already removed this scope from its visible roster. A
    // detached notice can no longer become current, and need not occupy the
    // bounded history when another profile is connected.
    func forget(_ scope: ExternalProviderV2Scope) {
        lock.lock(); defer { lock.unlock() }
        scopes.removeValue(forKey: scope)
        queue.removeAll { $0.scope == scope }
        pendingGaps.removeValue(forKey: scope)
    }

    func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        for source in Array(scopes.keys) {
            guard var state = scopes[source] else { continue }
            for instance in Array(state.producers.keys) {
                state.producers[instance]?.valid = false
                rememberGap(source, state.generation, instance, state.ticket)
            }
            scopes[source] = state
        }
    }

    // Returns a response payload to write on the same synthetic/local socket.
    func receive(_ payload: Data, now: UInt64) -> [String: Any] {
        guard payload.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 2, version.doubleValue == 2,
              let provider = value["provider"] as? String, let scopeName = value["scope"] as? String,
              let generation = value["generation"] as? String, ExternalProviderV2Scope.hex(generation),
              let instance = value["instance"] as? String, ExternalProviderV2Scope.hex(instance),
              let kind = value["kind"] as? String else { invalidateAll(); return ["accepted": false] }
        let source = ExternalProviderV2Scope(provider: provider, scope: scopeName)
        guard source.valid else { invalidateAll(); return ["accepted": false] }
        let keys = Set(value.keys), base: Set<String> = ["version", "provider", "scope", "generation", "instance", "kind"]
        lock.lock(); defer { lock.unlock() }
        guard var state = scopes[source], state.generation == generation else { return ["accepted": false] }
        func rejectAuthenticated() -> [String: Any] {
            if let supplied = value["ticket"] as? String, supplied == state.ticket, state.producers[instance] != nil {
                state.producers[instance]?.valid = false
                scopes[source] = state
                rememberGap(source, state.generation, instance, state.ticket)
            }
            return ["accepted": false]
        }
        if kind == "hello" {
            guard keys == base else { return ["accepted": false] }
            state.seen = true
            guard let ticket = state.ticket else { scopes[source] = state; return ["state": "wait"] }
            if state.producers[instance] == nil {
                guard state.producers.count < maxProducers else {
                    for id in Array(state.producers.keys) { state.producers[id]?.valid = false }
                    scopes[source] = state
                    rememberGap(source, state.generation, "overflow", state.ticket)
                    return ["state": "wait"]
                }
                state.producers[instance] = Producer(lastHello: now)
            } else { state.producers[instance]?.lastHello = now }
            let valid = state.producers[instance]?.valid == true
            scopes[source] = state
            return valid ? ["state": "ready", "ticket": ticket] : ["state": "wait"]
        }
        if kind == "gap" {
            guard keys == base.union(["ticket"]), let ticket = value["ticket"] as? String,
                  ticket == state.ticket, state.producers[instance] != nil else { return rejectAuthenticated() }
            state.producers[instance]?.valid = false
            scopes[source] = state
            rememberGap(source, state.generation, instance, state.ticket)
            return ["accepted": true]
        }
        guard kind == "event", keys == base.union(["ticket", "seq", "event"]),
              let eventValue = value["event"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: eventValue),
              let event = ExternalProviderEventParser.parse(encoded), event.provider == provider,
              provider != "deepseek" || event.session.hasPrefix(scopeName + "_") else { return rejectAuthenticated() }
        let ticket = value["ticket"] as? String
        if ticket == nil {
            guard value["ticket"] is NSNull, value["seq"] is NSNull else { return ["accepted": false] }
        } else {
            guard ticket == state.ticket, var producer = state.producers[instance], producer.valid,
                  let number = value["seq"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  number.int64Value > 0, number.int64Value <= 9_007_199_254_740_990 else { return rejectAuthenticated() }
            guard number.int64Value == producer.sequence + 1 else {
                producer.valid = false; state.producers[instance] = producer; scopes[source] = state
                rememberGap(source, state.generation, instance, state.ticket)
                return ["accepted": false]
            }
            producer.sequence = number.int64Value
            state.producers[instance] = producer
            scopes[source] = state
            if event.kind == "gap" {
                state.producers[instance]?.valid = false
                scopes[source] = state
                rememberGap(source, state.generation, instance, state.ticket)
                return ["accepted": true]
            }
        }
        guard queue.count < maxQueue else {
            if ticket != nil {
                state.producers[instance]?.valid = false; scopes[source] = state
                rememberGap(source, state.generation, instance, state.ticket)
                rememberGap(source, state.generation, "overflow", state.ticket)
            }
            return ["accepted": false]
        }
        queue.append(ExternalProviderV2Notice(scope: source, generation: generation, instance: instance,
            ticket: ticket, event: event, gap: false))
        return ["accepted": true]
    }

    // Recheck immediately before applying a previously drained event.
    func isCurrent(_ notice: ExternalProviderV2Notice) -> Bool {
        guard let ticket = notice.ticket else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let state = scopes[notice.scope] else { return false }
        return state.generation == notice.generation && state.ticket == ticket && state.producers[notice.instance]?.valid == true
    }

    // Production channel uses this transaction, so a failed acknowledgement
    // invalidates the producer before drain can expose its frame.
    func receiveResponding(_ payload: Data, now: UInt64,
                           write: ([String: Any]) -> Bool) {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        pendingLock.lock(); pendingScope = Self.identifyScope(payload); pendingLock.unlock()
        defer { pendingLock.lock(); pendingScope = nil; pendingLock.unlock() }
        let response = receive(payload, now: now)
        if !write(response) { replyUndelivered(payload) }
    }

    func scopeAwaitingReply() -> ExternalProviderV2Scope? {
        pendingLock.lock(); defer { pendingLock.unlock() }
        return pendingScope
    }

    private static func identifyScope(_ payload: Data) -> ExternalProviderV2Scope? {
        guard payload.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let version = value["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 2, let provider = value["provider"] as? String,
              let name = value["scope"] as? String,
              let generation = value["generation"] as? String, ExternalProviderV2Scope.hex(generation),
              let instance = value["instance"] as? String, ExternalProviderV2Scope.hex(instance),
              value["kind"] is String else { return nil }
        let result = ExternalProviderV2Scope(provider: provider, scope: name)
        return result.valid ? result : nil
    }

    // The channel calls this if it could not write its reply. The sender may
    // not learn whether a frame was committed, so that instance loses trust.
    func replyUndelivered(_ payload: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let provider = value["provider"] as? String, let scopeName = value["scope"] as? String,
              let generation = value["generation"] as? String, let instance = value["instance"] as? String else { return }
        let source = ExternalProviderV2Scope(provider: provider, scope: scopeName)
        guard source.valid, ExternalProviderV2Scope.hex(generation), ExternalProviderV2Scope.hex(instance) else { return }
        lock.lock(); defer { lock.unlock() }
        guard var state = scopes[source], state.generation == generation, state.producers[instance] != nil else { return }
        if let supplied = value["ticket"] as? String, supplied != state.ticket { return }
        state.producers[instance]?.valid = false
        scopes[source] = state
        rememberGap(source, state.generation, instance, state.ticket)
    }

    func drain() -> [ExternalProviderV2Notice] {
        deliveryLock.lock(); defer { deliveryLock.unlock() }
        return drainLocked()
    }

    // UI polling must never wait for a slow local client writing its reply.
    func drainIfReady() -> [ExternalProviderV2Notice]? {
        guard deliveryLock.try() else { return nil }
        defer { deliveryLock.unlock() }
        return drainLocked()
    }

    private func drainLocked() -> [ExternalProviderV2Notice] {
        lock.lock(); defer { lock.unlock() }
        var notices = queue
        queue.removeAll(keepingCapacity: true)
        for (source, gaps) in pendingGaps {
            for gap in gaps {
                notices.append(ExternalProviderV2Notice(scope: source, generation: gap.generation,
                    instance: gap.instance, ticket: gap.ticket, event: nil, gap: true))
            }
        }
        pendingGaps.removeAll(keepingCapacity: true)
        return notices
    }

    func expire(now: UInt64, timeout: UInt64) {
        lock.lock(); defer { lock.unlock() }
        for source in Array(scopes.keys) {
            guard var state = scopes[source] else { continue }
            for instance in Array(state.producers.keys) {
                guard var producer = state.producers[instance], producer.valid else { continue }
                if now < producer.lastHello || now - producer.lastHello > timeout {
                    producer.valid = false; state.producers[instance] = producer
                    rememberGap(source, state.generation, instance, state.ticket)
                }
            }
            scopes[source] = state
        }
    }

    // Must be called with the lock held. On repeated generations, a bounded
    // wildcard reports a scope-wide loss rather than forgetting a producer.
    private func rememberGap(_ scope: ExternalProviderV2Scope, _ generation: String,
                             _ instance: String, _ ticket: String?) {
        let wildcard = PendingGap(generation: "", instance: "", ticket: nil)
        var gaps = pendingGaps[scope, default: []]
        if gaps.contains(wildcard) { return }
        if gaps.count >= maxProducers { gaps = [wildcard] }
        else { gaps.insert(PendingGap(generation: generation, instance: instance, ticket: ticket)) }
        pendingGaps[scope] = gaps
    }
}
