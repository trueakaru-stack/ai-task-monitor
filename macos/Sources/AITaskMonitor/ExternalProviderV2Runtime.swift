import Darwin
import Foundation

// The caller owns this object on the main actor. The socket and broker are
// separate from the v1 receiver so malformed v2 frames cannot disrupt other
// providers. Each profile owns its own reducer and restart ticket.
final class ExternalProviderV2Runtime {
    private final class Slot {
        let generation: String
        var ticket: String?
        var verified: ExternalProviderStateStore
        var unknown: ExternalProviderStateStore
        var parked: [String: MonitoredTask] = [:]
        var owners: [String: String] = [:]
        var terminalIDs: Set<String> = []
        var trustLost = false
        init(scope: ExternalProviderV2Scope, generation: String) {
            self.generation = generation
            verified = Self.makeStore(scope, unconfirmed: false)
            unknown = Self.makeStore(scope, unconfirmed: true)
        }
        static func makeStore(_ scope: ExternalProviderV2Scope, unconfirmed: Bool) -> ExternalProviderStateStore {
            let store = ExternalProviderStateStore()
            store.retainProviders([scope.provider])
            if scope.provider == "deepseek" { store.retainSessionScopes(provider: "deepseek", scopes: [scope.scope]) }
            if unconfirmed { store.markGap(provider: scope.provider) }
            return store
        }
        static func tasks(_ store: ExternalProviderStateStore, now: Date) -> [MonitoredTask] {
            ExternalProviderTaskMapper.tasks(store.snapshot(now: now))
        }
    }

    let broker: ExternalProviderV2Broker
    private let channel: ExternalProviderV2Channel
    private let generations: ExternalProviderV2GenerationFile
    private var slots: [ExternalProviderV2Scope: Slot] = [:]
    private(set) var capacityLimitedScopes: Set<ExternalProviderV2Scope> = []
    private var lastSnapshotReady = false
    private var lastPendingScope: ExternalProviderV2Scope?
    private let maximumSessions = 256
    #if DEBUG
    private(set) var testUnconfirmedFrames = 0
    #endif

    init(directory: String? = nil) throws {
        let path = directory ?? "/private/tmp/aitm-provider-\(geteuid())"
        let gate = ExternalProviderV2Broker()
        broker = gate
        channel = try ExternalProviderV2Channel(directory: path, broker: gate)
        generations = ExternalProviderV2GenerationFile(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    var isStopped: Bool { channel.isStopped }

    // Atomically publish one startup generation per live scope. Existing scopes
    // keep theirs; removing or adding a neighbour never reauthorizes another.
    func setScopes(_ desired: Set<ExternalProviderV2Scope>, now: Date = Date()) throws {
        guard !channel.isStopped, desired.count <= 257, desired.allSatisfy(\.valid) else {
            throw ExternalProviderRuntimeError.stopped
        }
        guard consume(now: now) else { return }
        guard desired != Set(slots.keys) else { return }
        var next = slots
        for scope in Set(slots.keys).subtracting(desired) { next.removeValue(forKey: scope) }
        for scope in desired where next[scope] == nil {
            next[scope] = Slot(scope: scope, generation: try ExternalProviderV2GenerationFile.randomValue())
        }
        try generations.replace(next.mapValues(\.generation))
        for scope in Set(slots.keys).subtracting(desired) { broker.forget(scope) }
        for scope in desired where slots[scope] == nil {
            guard let slot = next[scope], broker.configure(scope, generation: slot.generation) else {
                broker.invalidateAll()
                throw ExternalProviderRuntimeError.stopped
            }
        }
        slots = next
        capacityLimitedScopes.formIntersection(desired)
    }

    func canAcknowledge(_ scope: ExternalProviderV2Scope) -> Bool {
        guard !channel.isStopped, let slot = slots[scope] else { return false }
        return broker.hasSeenInstance(scope, generation: slot.generation)
    }

    // This action records the user's statement that all processes belonging to
    // the chosen source/profile were fully restarted. It does not inspect them.
    @discardableResult
    func acknowledge(_ scope: ExternalProviderV2Scope, now: Date = Date()) -> Bool {
        // Do not reject a user's action just because this or another profile
        // is still receiving a reply. The broker rotates the ticket under its
        // own short lock; queued frames are rechecked against that ticket.
        _ = consume(now: now)
        guard let slot = slots[scope], canAcknowledge(scope),
              let ticket = try? ExternalProviderV2GenerationFile.randomValue(),
              broker.acknowledgeRestart(scope, generation: slot.generation, ticket: ticket) else { return false }
        for task in Slot.tasks(slot.verified, now: now) + Slot.tasks(slot.unknown, now: now) {
            slot.parked[task.id] = Self.unconfirmed(task)
        }
        if slot.parked.count > maximumSessions {
            slot.parked = Dictionary(uniqueKeysWithValues: slot.parked.values.sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maximumSessions).map { ($0.id, $0) })
        }
        slot.verified = Slot.makeStore(scope, unconfirmed: false)
        slot.unknown = Slot.makeStore(scope, unconfirmed: true)
        slot.owners.removeAll()
        slot.terminalIDs.removeAll()
        slot.trustLost = false
        capacityLimitedScopes.remove(scope)
        slot.ticket = ticket
        return true
    }

    func snapshot(now: Date = Date()) -> [MonitoredTask] {
        let ready = consume(now: now)
        lastSnapshotReady = ready
        let pending = ready ? nil : broker.scopeAwaitingReply()
        lastPendingScope = pending
        var result: [String: MonitoredTask] = [:]
        for (scope, slot) in slots {
            let blocked = !ready && (pending == nil || pending == scope)
            for item in slot.parked.values where !slot.terminalIDs.contains(item.id) { result[item.id] = item }
            for item in Slot.tasks(slot.unknown, now: now) where result[item.id] == nil && !slot.terminalIDs.contains(item.id) { result[item.id] = item }
            // Independent fresh observations replace stale cards of the same
            // session; no old fields or plan are copied into the new reducer.
            for item in Slot.tasks(slot.verified, now: now) { result[item.id] = blocked ? Self.unconfirmed(item) : item }
        }
        return Array(result.values)
    }

    // Only terminal events accepted under a current, uninterrupted ticket can
    // supersede a stale v1 card with the same identity.
    var terminalIDs: Set<String> {
        guard lastSnapshotReady || lastPendingScope != nil else { return [] }
        return slots.reduce(into: Set<String>()) { result, pair in
            if lastSnapshotReady || pair.key != lastPendingScope { result.formUnion(pair.value.terminalIDs) }
        }
    }

    @discardableResult
    private func consume(now: Date) -> Bool {
        broker.expire(now: DispatchTime.now().uptimeNanoseconds, timeout: 8_000_000_000)
        guard let notices = broker.drainIfReady() else { return false }
        for notice in notices {
            guard let slot = slots[notice.scope] else { continue }
            if notice.gap {
                if notice.generation.isEmpty || (notice.generation == slot.generation && notice.ticket == slot.ticket) {
                    slot.verified.markGap(provider: notice.scope.provider)
                    slot.trustLost = true
                    slot.terminalIDs.removeAll()
                    if notice.instance == "overflow" { capacityLimitedScopes.insert(notice.scope) }
                }
                continue
            }
            guard notice.generation == slot.generation, let event = notice.event else { continue }
            #if DEBUG
            if notice.ticket == nil { testUnconfirmedFrames += 1 }
            #endif
            let ticketed = notice.ticket != nil && notice.ticket == slot.ticket && broker.isCurrent(notice)
            // OpenCode's live-subscription barrier still needs verification in
            // supported real runtimes, so its frames remain unconfirmed.
            if notice.ticket != nil && !ticketed && notice.ticket == slot.ticket {
                slot.verified.markGap(provider: notice.scope.provider)
                slot.trustLost = true
                slot.terminalIDs.removeAll()
            }
            if ticketed, let previous = slot.owners[event.session], previous != notice.instance {
                slot.verified.markGap(provider: notice.scope.provider)
                slot.trustLost = true
                slot.terminalIDs.removeAll()
            }
            let confirmed = ticketed && !slot.trustLost && notice.scope.provider == "deepseek"
            let existing = knownIDs(now: now)
            let id = event.provider + ":" + event.session
            if !existing.contains(id) && existing.count >= maximumSessions {
                capacityLimitedScopes.insert(notice.scope)
                slot.verified.markGap(provider: notice.scope.provider)
                slot.trustLost = true
                slot.terminalIDs.removeAll()
                continue
            }
            if confirmed {
                // A first plan, heartbeat or terminal does not establish a
                // task's current owner. In particular, it cannot erase an
                // older unconfirmed card for the same session.
                if slot.owners[event.session] == nil &&
                    !["started", "active", "waiting", "tool_started"].contains(event.kind) {
                    _ = slot.unknown.apply(event, now: now)
                    continue
                }
                let ownerCount = slots.values.reduce(0) { $0 + $1.owners.count }
                if slot.owners[event.session] == nil && ownerCount >= maximumSessions {
                    capacityLimitedScopes.insert(notice.scope)
                    slot.verified.markGap(provider: notice.scope.provider)
                    slot.trustLost = true
                    slot.terminalIDs.removeAll()
                    continue
                }
                slot.owners[event.session] = notice.instance
                if slot.verified.apply(event, now: now) {
                    slot.parked.removeValue(forKey: id)
                    if ["idle", "completed", "failed", "interrupted"].contains(event.kind) { slot.terminalIDs.insert(id) }
                    else if event.kind != "heartbeat" { slot.terminalIDs.remove(id) }
                }
            } else { _ = slot.unknown.apply(event, now: now) }
        }
        return true
    }

    private func knownIDs(now: Date) -> Set<String> {
        var ids: Set<String> = []
        for slot in slots.values {
            ids.formUnion(slot.parked.keys)
            ids.formUnion(Slot.tasks(slot.verified, now: now).map(\.id))
            ids.formUnion(Slot.tasks(slot.unknown, now: now).map(\.id))
        }
        return ids
    }

    private static func unconfirmed(_ task: MonitoredTask) -> MonitoredTask {
        var copy = task
        copy.isActive = false; copy.isWaiting = false; copy.isUnconfirmed = true
        copy.progress = nil; copy.progressKind = .none; copy.steps = []; copy.planConfirmed = false
        copy.activity = tr("Статус не подтверждён", "Status unconfirmed")
        return copy
    }

    @discardableResult func stop() -> Bool { channel.stop() }
}
