import CoreFoundation
import Foundation

struct ExternalProviderStep: Equatable {
    let title: String
    let status: String
}

struct ExternalProviderEvent {
    let provider: String
    let session: String
    let kind: String
    let turn: String
    let call: String
    let action: String
    let steps: [ExternalProviderStep]?
    let tick: Int64
    let epoch: Int64
    let request: String
    // Filled by the local channel, not decoded from the sender.
    var receivedAt: Date?
}

fileprivate struct ExternalProviderCall: Equatable {
    let id: String
    let action: String
}

fileprivate struct ExternalProviderHermesRequest: Equatable {
    var tick: Int64
    var open: Bool
}

struct ExternalProviderTask: Equatable {
    let provider: String
    let session: String
    var status: String
    var startKey: String
    var startedAt: Date
    var updatedAt: Date
    var steps: [ExternalProviderStep]
    var planConfirmed: Bool
    var activity: String = ""
    var longRunning: Bool = false
    // Ownership cannot be reconstructed from a v1 event after ambiguity.
    var deepSeekUnassigned = false
    fileprivate var turn: String
    fileprivate var calls: [ExternalProviderCall] = []
    fileprivate var lastHeartbeat: Date?
    fileprivate var hermesTick: Int64 = 0
    fileprivate var hermesEpoch: Int64 = 0
    fileprivate var hermesTerminalEpoch: Int64 = 0
    fileprivate var hermesAmbiguousEpoch: Int64 = 0
    fileprivate var hermesResolvedTick: Int64 = 0
    fileprivate var hermesOrdinaryStatus = ""
    fileprivate var hermesUncertain = false
    fileprivate var hermesRequests: [String: ExternalProviderHermesRequest] = [:]
    fileprivate var hermesTerminalTurns: [String: Int64] = [:]
}

// Accept sanitized observer events only; raw agent payloads are never accepted here.
enum ExternalProviderEventParser {
    private static let providers: Set<String> = ["kimi", "deepseek", "hermes", "opencode"]
    private static let kinds: Set<String> = ["started", "active", "waiting", "unknown", "idle", "completed", "failed", "interrupted", "plan", "gap", "tool_started", "tool_finished", "heartbeat"]
    private static let fields: Set<String> = ["version", "provider", "session", "kind", "turn", "steps", "call", "action", "tick", "epoch", "request"]

    private static func validID(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil
    }

    static func parse(_ data: Data) -> ExternalProviderEvent? {
        guard !data.isEmpty, data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any], Set(values.keys).isSubset(of: fields),
              let version = values["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              let provider = values["provider"] as? String, providers.contains(provider),
              let session = values["session"] as? String, validID(session),
              let kind = values["kind"] as? String, kinds.contains(kind) else { return nil }
        let turn = values["turn"] as? String ?? ""
        if values["turn"] != nil && !validID(turn) { return nil }
        var tick: Int64 = 0
        if let value = values["tick"] {
            guard provider == "hermes", let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  number.int64Value > 0 else { return nil }
            tick = number.int64Value
        }
        var epoch: Int64 = 0
        if let value = values["epoch"] {
            guard provider == "hermes", let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  number.int64Value > 0, number.int64Value <= tick else { return nil }
            epoch = number.int64Value
        }
        let request = values["request"] as? String ?? ""
        if values["request"] != nil && (provider != "hermes" || tick == 0 ||
            !["waiting", "unknown"].contains(kind) || !validID(request)) { return nil }
        if kind == "heartbeat" && values.count != 4 { return nil }
        if kind != "plan" && values["steps"] != nil { return nil }
        let isToolEvent = kind == "tool_started" || kind == "tool_finished"
        let call = values["call"] as? String ?? ""
        let action = values["action"] as? String ?? ""
        if isToolEvent && !validID(call) { return nil }
        if !isToolEvent && (values["call"] != nil || values["action"] != nil) { return nil }
        if kind == "tool_started" && !["command", "read", "edit", "search", "other"].contains(action) { return nil }
        if kind == "tool_finished" && values["action"] != nil { return nil }
        var steps: [ExternalProviderStep]?
        if kind == "plan" {
            guard let entries = values["steps"] as? [[String: Any]], entries.count <= 100 else { return nil }
            var parsed: [ExternalProviderStep] = []
            for item in entries {
                guard Set(item.keys) == Set(["title", "status"]),
                      let title = item["title"] as? String,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf16.count <= 512,
                      let status = item["status"] as? String, ["pending", "active", "done"].contains(status) else { return nil }
                parsed.append(ExternalProviderStep(title: title, status: status))
            }
            steps = parsed
        }
        return ExternalProviderEvent(provider: provider, session: session, kind: kind, turn: turn, call: call, action: action, steps: steps, tick: tick, epoch: epoch, request: request)
    }
}

// All state stays in memory and is limited independently from the diagnostic journal.
final class ExternalProviderStateStore {
    private var states: [String: ExternalProviderTask] = [:]
    private var sequence: UInt64 = 0
    private var hermesBarrier: Int64 = 0
    private var hermesAllowed = false
    private var providerRosterInitialized = false
    private var openCodeAllowed = false
    private var openCodeUnconfirmed = false
    private var deepSeekAllowed = false
    private var deepSeekScopesInitialized = false
    private var deepSeekScopeOverflow = false
    private var deepSeekScopes: Set<String> = []
    // Only the initial verified roster can retain legacy confidence. Once a
    // scope is affected, removing it is permanent for this store lifetime.
    private var deepSeekInitiallyTrustedScopes: Set<String> = []
    private var deepSeekUnassignedScopes: Set<String> = []
    private var deepSeekOwnershipOverflow = false
    private var hermesScopeBarriers: [String: Int64] = [:]
    private var hermesScopes: Set<String> = []
    private var hermesUncertainScopes: Set<String> = []
    private(set) var capacityLimitedProviders: Set<String> = []
    private let maximumSessions = 256
    private let staleAfter: TimeInterval = 1_800
    private let heartbeatLifetime: TimeInterval = 180

    @discardableResult
    func apply(_ event: ExternalProviderEvent, now: Date) -> Bool {
        if event.provider == "hermes", event.tick == 0 || event.epoch == 0 { return false }
        if event.provider == "hermes", event.tick <= hermesBarrier || event.epoch <= hermesBarrier { return false }
        let scope = Self.sessionScope(event.session)
        if event.provider == "hermes", let barrier = hermesScopeBarriers[scope] {
            if event.tick <= barrier || event.epoch <= barrier { return false }
        }
        let currentTick = Self.monotonicNanoseconds()
        if event.provider == "hermes", event.tick > currentTick, event.tick - currentTick > 2_000_000_000 {
            markGap(provider: "hermes")
            return false
        }
        if event.kind == "gap" {
            if event.provider == "hermes", scope.utf8.count == 32,
               scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                markHermesScopeGap(scope)
                return true
            }
            // A v1 DeepSeek callback is not evidence about other profiles.
            if event.provider == "deepseek" {
                if scope.utf8.count == 32,
                   scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                    markSessionScopesGap(provider: "deepseek", scopes: [scope])
                }
                return true
            }
            markGap(provider: event.provider)
            return true
        }
        let key = event.provider + ":" + event.session
        if event.provider == "deepseek", isDeepSeekUnassigned(event.session) {
            return applyUnassignedDeepSeek(event, now: now)
        }
        let unconfirmedV1 = (event.provider == "opencode" && openCodeUnconfirmed) ||
            (event.provider == "deepseek" && (!Self.validDeepSeekScope(scope) || deepSeekScopeOverflow || !deepSeekInitiallyTrustedScopes.contains(scope)))
        // A late terminal or heartbeat cannot create or remove an unconfirmed card.
        if unconfirmedV1 && ["idle", "completed", "failed", "interrupted", "heartbeat"].contains(event.kind) {
            if var state = states[key] {
                markUnconfirmedV1(&state)
                states[key] = state
            }
            return true
        }
        // A heartbeat alone never creates or revives a task.
        if event.kind == "heartbeat" {
            if var state = states[key] {
                expire(&state, now: now)
                if state.status == "active" || state.status == "waiting" { state.lastHeartbeat = now }
                states[key] = state
            }
            return true
        }
        let created = states[key] == nil
        if created {
            if states.count >= maximumSessions {
                // A stale v1 card is evidence, and cannot be displaced by another source.
                if event.provider == "opencode" || event.provider == "deepseek" {
                    return rejectAtCapacity(provider: event.provider, scope: scope)
                }
                let removable = states.filter { _, value in
                    value.status != "active" && value.status != "waiting" &&
                    !(value.status == "unknown" && (value.provider == "opencode" || value.provider == "deepseek"))
                }.min { $0.value.updatedAt < $1.value.updatedAt }
                guard let oldest = removable?.key else { return rejectAtCapacity(provider: event.provider, scope: scope) }
                if states[oldest]?.provider == "hermes" { markGap(provider: "hermes") }
                states.removeValue(forKey: oldest)
            }
            states[key] = ExternalProviderTask(provider: event.provider, session: event.session, status: "unknown",
                startKey: "", startedAt: .distantPast, updatedAt: now, steps: [], planConfirmed: true, turn: "")
            if event.provider == "hermes" && hermesBarrier > 0 { states[key]?.hermesUncertain = true }
        }
        guard var state = states[key] else { return false }
        expire(&state, now: now)
        if event.provider == "hermes" {
            let result = applyHermes(event, state: &state, now: now, created: created)
            states[key] = state
            return result
        }
        if unconfirmedV1 {
            if state.startKey.isEmpty { start(&state, now: now, turn: event.turn) }
            if state.provider != "opencode", event.kind == "plan", let steps = event.steps, !steps.isEmpty { state.steps = steps }
            markUnconfirmedV1(&state)
            state.updatedAt = now
            states[key] = state
            return true
        }
        if event.provider == "kimi" {
            // Kimi's passive hooks can be delayed or lost and do not reliably
            // report successful turn completion.
            if event.kind == "started" && (state.startKey.isEmpty || event.turn != state.turn) {
                start(&state, now: now, turn: event.turn)
            }
            state.status = "unknown"
            state.steps = []
            state.planConfirmed = false
            state.calls.removeAll()
            state.lastHeartbeat = nil
            state.updatedAt = now
            states[key] = state
            return true
        }
        if event.kind == "started" {
            let newTurn = state.status != "active" || event.turn.isEmpty || event.turn != state.turn
            if newTurn { start(&state, now: now, turn: event.turn) }
            state.status = "active"
        } else if event.kind == "active" {
            if ["idle", "completed", "failed", "interrupted"].contains(state.status) || state.startKey.isEmpty {
                start(&state, now: now, turn: "")
            }
            state.status = "active"
        } else if event.kind == "plan" {
            guard let steps = event.steps else { return false }
            state.steps = steps
            state.planConfirmed = true
        } else if event.kind == "tool_started" {
            if ["idle", "completed", "failed", "interrupted"].contains(state.status) || state.startKey.isEmpty {
                start(&state, now: now, turn: "")
            }
            if state.status != "waiting" { state.status = "active" }
            state.calls.removeAll { $0.id == event.call }
            if state.calls.count >= 32 { state.calls.removeAll() }
            state.calls.append(ExternalProviderCall(id: event.call, action: event.action))
        } else if event.kind == "tool_finished" {
            state.calls.removeAll { $0.id == event.call }
        } else if event.kind == "waiting" {
            if ["idle", "completed", "failed", "interrupted"].contains(state.status) || state.startKey.isEmpty {
                start(&state, now: now, turn: "")
            }
            state.status = "waiting"
            state.calls.removeAll()
        } else {
            state.status = event.kind
            if state.status != "active" { state.calls.removeAll() }
            if state.status != "waiting" { state.lastHeartbeat = nil }
        }
        state.updatedAt = now
        states[key] = state
        return true
    }

    private func rejectAtCapacity(provider: String, scope: String) -> Bool {
        capacityLimitedProviders.insert(provider)
        if provider == "deepseek" && Self.validDeepSeekScope(scope) {
            markSessionScopesGap(provider: provider, scopes: [scope])
        } else if provider == "hermes" && Self.validDeepSeekScope(scope) {
            markHermesScopeGap(scope)
        } else {
            markGap(provider: provider)
        }
        return false
    }

    private func markUnconfirmedV1(_ state: inout ExternalProviderTask) {
        state.status = "unknown"
        state.planConfirmed = false
        if state.provider == "opencode" || state.deepSeekUnassigned { state.steps = [] }
        state.calls.removeAll()
        state.lastHeartbeat = nil
    }

    // Accept only minimal evidence from an unowned v1 event. In particular,
    // terminal and heartbeat records cannot create or dismiss a neutral card.
    @discardableResult
    func applyUnassignedDeepSeek(_ event: ExternalProviderEvent, now: Date) -> Bool {
        guard event.provider == "deepseek" else { return false }
        let scope = Self.sessionScope(event.session)
        if Self.validDeepSeekScope(scope) {
            rememberUnassignedDeepSeekScope(scope)
            markSessionScopesGap(provider: "deepseek", scopes: [scope])
        }
        let key = event.provider + ":" + event.session
        if ["gap", "idle", "completed", "failed", "interrupted", "heartbeat", "tool_finished"].contains(event.kind) {
            if var state = states[key] {
                state.deepSeekUnassigned = true
                markUnconfirmedV1(&state)
                states[key] = state
            }
            return true
        }
        if states[key] == nil {
            guard states.count < maximumSessions else { return rejectAtCapacity(provider: "deepseek", scope: scope) }
            states[key] = ExternalProviderTask(provider: event.provider, session: event.session, status: "unknown",
                startKey: "", startedAt: .distantPast, updatedAt: now, steps: [], planConfirmed: false, turn: "")
        }
        guard var state = states[key] else { return false }
        state.deepSeekUnassigned = true
        markUnconfirmedV1(&state)
        state.updatedAt = now
        states[key] = state
        return true
    }

    // Mark only scopes whose ownership is ambiguous; a continuously verified
    // neighbour must retain its own state.
    func markDeepSeekOwnershipUnknown(allowed: Set<String>, ambiguous: Set<String>,
                                      historyLost: Bool, disabled: Set<String>) {
        var affected: Set<String> = []
        for key in Array(states.keys) {
            guard var state = states[key], state.provider == "deepseek" else { continue }
            let scope = Self.sessionScope(state.session)
            let unknown = ambiguous.contains(scope) ||
                (historyLost && !allowed.contains(scope) && !disabled.contains(scope))
            guard unknown else { continue }
            state.deepSeekUnassigned = true
            markUnconfirmedV1(&state)
            states[key] = state
            if Self.validDeepSeekScope(scope) { affected.insert(scope) }
        }
        for scope in affected { rememberUnassignedDeepSeekScope(scope) }
        markSessionScopesGap(provider: "deepseek", scopes: affected)
    }

    func isDeepSeekUnassigned(_ session: String) -> Bool {
        let scope = Self.sessionScope(session)
        return deepSeekOwnershipOverflow || deepSeekUnassignedScopes.contains(scope) ||
            states["deepseek:" + session]?.deepSeekUnassigned == true
    }

    private func rememberUnassignedDeepSeekScope(_ scope: String) {
        guard !deepSeekOwnershipOverflow, Self.validDeepSeekScope(scope),
              !deepSeekUnassignedScopes.contains(scope) else { return }
        guard deepSeekUnassignedScopes.count < maximumSessions else {
            deepSeekOwnershipOverflow = true
            deepSeekUnassignedScopes.removeAll()
            deepSeekInitiallyTrustedScopes.removeAll()
            capacityLimitedProviders.insert("deepseek")
            for key in Array(states.keys) where states[key]?.provider == "deepseek" {
                if var state = states[key] {
                    state.deepSeekUnassigned = true
                    markUnconfirmedV1(&state)
                    states[key] = state
                }
            }
            return
        }
        deepSeekUnassignedScopes.insert(scope)
        for key in Array(states.keys) {
            guard var state = states[key], state.provider == "deepseek",
                  Self.sessionScope(state.session) == scope else { continue }
            state.deepSeekUnassigned = true
            markUnconfirmedV1(&state)
            states[key] = state
        }
    }

    private static func validDeepSeekScope(_ scope: String) -> Bool {
        scope.utf8.count == 32 && scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }

    private func markDeepSeekScopesUnconfirmed(_ scopes: Set<String>) {
        for scope in scopes where Self.validDeepSeekScope(scope) {
            deepSeekInitiallyTrustedScopes.remove(scope)
        }
    }

    func markGap(provider: String? = nil) {
        if provider == nil || provider == "opencode" { openCodeUnconfirmed = true }
        if provider == nil || provider == "deepseek" {
            deepSeekScopesInitialized = true
            let observed = Set(states.values.filter { $0.provider == "deepseek" }.map { Self.sessionScope($0.session) })
            markDeepSeekScopesUnconfirmed(deepSeekScopes.union(observed))
        }
        if provider == nil || provider == "hermes" { hermesBarrier = max(hermesBarrier, Self.monotonicNanoseconds()) }
        for key in Array(states.keys) {
            if let provider, states[key]?.provider != provider { continue }
            if states[key]?.provider == "opencode" || states[key]?.provider == "deepseek" {
                if var state = states[key] { markUnconfirmedV1(&state); states[key] = state }
                continue
            }
            if states[key]?.provider == "hermes" {
                states[key]?.hermesUncertain = true
                states[key]?.hermesRequests.removeAll()
            }
            if states[key]?.steps.isEmpty == false { states[key]?.planConfirmed = false }
            if let status = states[key]?.status, status == "active" || status == "waiting" {
                states[key]?.status = "unknown"
                states[key]?.calls.removeAll()
            }
            states[key]?.lastHeartbeat = nil
        }
    }

    func retainProviders(_ allowed: Set<String>) {
        capacityLimitedProviders.formIntersection(allowed)
        let nextOpenCodeAllowed = allowed.contains("opencode"), nextDeepSeekAllowed = allowed.contains("deepseek")
        if !providerRosterInitialized && !nextDeepSeekAllowed { deepSeekScopesInitialized = true }
        if providerRosterInitialized && nextOpenCodeAllowed != openCodeAllowed { openCodeUnconfirmed = true }
        if providerRosterInitialized && deepSeekAllowed && !nextDeepSeekAllowed {
            let observed = Set(states.values.filter { $0.provider == "deepseek" }.map { Self.sessionScope($0.session) })
            markDeepSeekScopesUnconfirmed(deepSeekScopes.union(observed))
        }
        providerRosterInitialized = true
        openCodeAllowed = nextOpenCodeAllowed
        deepSeekAllowed = nextDeepSeekAllowed
        let nowAllowed = allowed.contains("hermes")
        if nowAllowed != hermesAllowed {
            hermesBarrier = max(hermesBarrier, Self.monotonicNanoseconds())
        }
        if !nowAllowed && hermesAllowed {
            hermesScopeBarriers.removeAll()
            hermesScopes.removeAll()
            hermesUncertainScopes.removeAll()
        }
        hermesAllowed = nowAllowed
        for key in Array(states.keys) {
            guard var state = states[key], !allowed.contains(state.provider) else { continue }
            if state.provider == "opencode" || state.provider == "deepseek" {
                markUnconfirmedV1(&state); states[key] = state
            } else { states.removeValue(forKey: key) }
        }
    }

    private static func monotonicNanoseconds() -> Int64 {
        Int64(clamping: DispatchTime.now().uptimeNanoseconds)
    }

    private func updateHermesScopeBarriers(_ changed: Set<String>) {
        let barrier = Self.monotonicNanoseconds()
        for scope in changed {
            if hermesScopeBarriers.count >= maximumSessions && hermesScopeBarriers[scope] == nil {
                markGap(provider: "hermes")
                hermesScopeBarriers.removeAll()
            }
            hermesScopeBarriers[scope] = barrier
        }
    }

    private func applyHermes(_ event: ExternalProviderEvent, state: inout ExternalProviderTask, now: Date, created: Bool) -> Bool {
        if state.hermesEpoch > event.epoch { return false }
        let terminal = ["idle", "completed", "failed", "interrupted"].contains(event.kind)
        if terminal {
            if event.turn.isEmpty {
                if state.hermesTerminalEpoch == event.epoch &&
                    ["idle", "completed", "failed", "interrupted"].contains(state.status) { return false }
                state.hermesAmbiguousEpoch = max(state.hermesAmbiguousEpoch, event.epoch)
                state.hermesEpoch = max(state.hermesEpoch, event.epoch)
                state.hermesUncertain = true
                state.status = "unknown"
                state.updatedAt = now
                return true
            }
            if let closed = state.hermesTerminalTurns[event.turn], closed >= event.epoch { return false }
            if state.hermesTerminalTurns[event.turn] == nil && state.hermesTerminalTurns.count >= 64 {
                state.hermesAmbiguousEpoch = max(state.hermesAmbiguousEpoch, event.epoch)
                state.hermesUncertain = true
                state.status = "unknown"
                state.updatedAt = now
                return true
            }
            state.hermesTerminalTurns[event.turn] = event.epoch
            state.hermesEpoch = max(state.hermesEpoch, event.epoch)
            if !state.turn.isEmpty && state.turn != event.turn { return true }
            if state.turn.isEmpty { state.turn = event.turn }
            state.hermesTick = max(state.hermesTick, event.tick)
            let pending = state.hermesRequests.values.contains { $0.open }
            if created && !pending {
                state.status = event.kind
                state.hermesTerminalEpoch = event.epoch
            } else if pending || state.hermesUncertain || state.hermesAmbiguousEpoch >= event.epoch {
                state.hermesUncertain = true
                state.status = "unknown"
            } else {
                state.status = event.kind
                state.hermesTerminalEpoch = event.epoch
            }
            state.updatedAt = now
            return true
        }
        if !event.turn.isEmpty, let closed = state.hermesTerminalTurns[event.turn], event.epoch <= closed { return false }
        if state.hermesAmbiguousEpoch >= event.epoch || (event.turn.isEmpty &&
            state.hermesTerminalTurns.values.contains { $0 >= event.epoch }) {
            if ["idle", "completed", "failed", "interrupted"].contains(state.status) { return false }
            state.hermesUncertain = true
            state.status = "unknown"
            state.updatedAt = now
            return true
        }
        if !event.request.isEmpty {
            if !event.turn.isEmpty && !state.turn.isEmpty && event.turn != state.turn &&
                ["active", "waiting"].contains(state.status) { state.hermesUncertain = true }
            if event.kind == "waiting" && event.epoch > state.hermesEpoch && state.hermesUncertain &&
                !state.hermesRequests.values.contains(where: { $0.open }) {
                state.hermesUncertain = false
                state.hermesRequests.removeAll()
            }
            var request = state.hermesRequests[event.request] ?? ExternalProviderHermesRequest(tick: 0, open: false)
            if state.hermesRequests[event.request] == nil && state.hermesRequests.count >= 64 {
                state.hermesUncertain = true
                state.status = "unknown"
                state.updatedAt = now
                return true
            }
            guard event.tick > request.tick else { return false }
            state.hermesEpoch = max(state.hermesEpoch, event.epoch)
            request.tick = event.tick
            request.open = event.kind == "waiting"
            if !request.open { state.hermesResolvedTick = max(state.hermesResolvedTick, event.tick) }
            if request.open && state.startKey.isEmpty { start(&state, now: now, turn: "") }
            state.hermesRequests[event.request] = request
            let pending = state.hermesRequests.values.contains { $0.open }
            if state.hermesUncertain { state.status = "unknown" }
            else if pending { state.status = "waiting" }
            else if state.hermesTick > state.hermesResolvedTick && state.hermesOrdinaryStatus == "active" { state.status = "active" }
            else { state.status = "unknown" }
            state.updatedAt = now
            return true
        }
        guard event.tick > state.hermesTick else { return false }
        if event.kind == "plan" {
            guard let steps = event.steps else { return false }
            state.hermesTick = event.tick
            state.steps = steps
            state.planConfirmed = !state.hermesUncertain
            state.updatedAt = now
            return true
        }
        if event.kind == "active" && !event.turn.isEmpty && !state.turn.isEmpty && event.turn != state.turn &&
            ["active", "waiting"].contains(state.status) {
            state.hermesUncertain = true
            state.status = "unknown"
            state.updatedAt = now
            return true
        }
        let newTurn = ["started", "active"].contains(event.kind) && !event.turn.isEmpty && event.turn != state.turn
        let newObserver = event.kind == "started" && event.epoch > state.hermesEpoch
        let pending = state.hermesRequests.values.contains { $0.open }
        if ((newTurn && event.kind == "started") || newObserver) && state.hermesUncertain && !pending && event.epoch > state.hermesAmbiguousEpoch {
            state.hermesUncertain = false
            state.hermesRequests.removeAll()
        }
        state.hermesEpoch = max(state.hermesEpoch, event.epoch)
        state.hermesTick = event.tick
        if newTurn || state.startKey.isEmpty { start(&state, now: now, turn: event.turn) }
        let status = event.kind == "started" ? "active" : event.kind
        state.hermesOrdinaryStatus = status
        if state.hermesUncertain { state.status = "unknown" }
        else if pending && ["unknown", "idle", "failed", "interrupted"].contains(status) {
            state.hermesUncertain = true
            state.status = "unknown"
        } else if !pending && status == "active" && state.hermesResolvedTick >= event.tick {
            state.status = "unknown"
        } else { state.status = pending ? "waiting" : status }
        if !state.hermesUncertain && !pending {
            if ["idle", "failed", "interrupted", "completed"].contains(status) {
                state.hermesTerminalEpoch = event.epoch
            } else if status == "active" { state.hermesTerminalEpoch = 0 }
        }
        state.updatedAt = now
        return true
    }

    func retainSessionScopes(provider: String, scopes: Set<String>) {
        if provider == "deepseek" {
            var valid = Set(scopes.filter(Self.validDeepSeekScope))
            if valid.count > maximumSessions {
                deepSeekScopeOverflow = true
                deepSeekInitiallyTrustedScopes.removeAll()
                for key in Array(states.keys) where states[key]?.provider == "deepseek" {
                    if var state = states[key] { markUnconfirmedV1(&state); states[key] = state }
                }
                valid.removeAll()
            }
            if !deepSeekScopesInitialized && !deepSeekScopeOverflow {
                deepSeekInitiallyTrustedScopes.formUnion(valid)
            } else if deepSeekScopesInitialized {
                markSessionScopesGap(provider: "deepseek", scopes: deepSeekScopes.symmetricDifference(scopes))
            }
            deepSeekScopes = valid
            deepSeekScopesInitialized = true
        }
        if provider == "hermes" {
            updateHermesScopeBarriers(hermesScopes.symmetricDifference(scopes))
            hermesScopes = scopes
        }
        for key in Array(states.keys) {
            guard let state = states[key], state.provider == provider,
                  !scopes.contains(Self.sessionScope(state.session)) else { continue }
            if provider == "deepseek" {
                var copy = state; markUnconfirmedV1(&copy); states[key] = copy
            } else { states.removeValue(forKey: key) }
        }
    }

    func markSessionScopesGap(provider: String, scopes: Set<String>) {
        if provider == "deepseek" && !scopes.isEmpty { deepSeekScopesInitialized = true; markDeepSeekScopesUnconfirmed(scopes) }
        if provider == "hermes" {
            updateHermesScopeBarriers(hermesUncertainScopes.symmetricDifference(scopes))
            hermesUncertainScopes = scopes
        }
        for key in Array(states.keys) {
            guard let state = states[key], state.provider == provider,
                  scopes.contains(Self.sessionScope(state.session)) else { continue }
            if provider == "deepseek" {
                var copy = state; markUnconfirmedV1(&copy); states[key] = copy
                continue
            }
            if provider == "hermes" {
                states[key]?.hermesUncertain = true
                states[key]?.hermesRequests.removeAll()
            }
            if !state.steps.isEmpty { states[key]?.planConfirmed = false }
            if state.status == "active" || state.status == "waiting" {
                states[key]?.status = "unknown"
                states[key]?.calls.removeAll()
            }
            states[key]?.lastHeartbeat = nil
        }
    }

    private func markHermesScopeGap(_ scope: String) {
        updateHermesScopeBarriers([scope])
        for key in Array(states.keys) {
            guard let state = states[key], state.provider == "hermes",
                  Self.sessionScope(state.session) == scope else { continue }
            states[key]?.hermesUncertain = true
            states[key]?.hermesRequests.removeAll()
            if states[key]?.steps.isEmpty == false { states[key]?.planConfirmed = false }
            if state.status == "active" || state.status == "waiting" {
                states[key]?.status = "unknown"
                states[key]?.calls.removeAll()
            }
            states[key]?.lastHeartbeat = nil
        }
    }

    static func sessionScope(_ session: String) -> String {
        guard session.utf8.count > 32 else { return "" }
        let bytes = Array(session.utf8)
        guard bytes[32] == 95 else { return "" }
        return String(decoding: bytes.prefix(32), as: UTF8.self)
    }

    func snapshot(now: Date) -> [ExternalProviderTask] {
        states.values.compactMap { state in
            guard ["active", "waiting", "unknown"].contains(state.status) else { return nil }
            var copy = state
            copy.longRunning = copy.status == "active" && now.timeIntervalSince(copy.updatedAt) >= staleAfter && hasFreshHeartbeat(copy, now: now)
            expire(&copy, now: now)
            if copy.status == "unknown" && now.timeIntervalSince(copy.updatedAt) >= staleAfter && !copy.steps.isEmpty {
                copy.planConfirmed = false
            }
            copy.activity = copy.status == "active" ? (copy.calls.last?.action ?? "") : ""
            return copy
        }
    }

    private func hasFreshHeartbeat(_ state: ExternalProviderTask, now: Date) -> Bool {
        guard let heartbeat = state.lastHeartbeat else { return false }
        let age = now.timeIntervalSince(heartbeat)
        return age >= 0 && age <= heartbeatLifetime
    }

    private func expire(_ state: inout ExternalProviderTask, now: Date) {
        guard ["active", "waiting"].contains(state.status),
              now.timeIntervalSince(state.updatedAt) >= staleAfter,
              !hasFreshHeartbeat(state, now: now) else { return }
        state.status = "unknown"
        state.calls.removeAll()
        state.lastHeartbeat = nil
        if !state.steps.isEmpty { state.planConfirmed = false }
    }

    private func start(_ state: inout ExternalProviderTask, now: Date, turn: String) {
        sequence &+= 1
        state.startKey = String(sequence)
        state.startedAt = now
        state.turn = turn
        state.calls.removeAll()
        state.lastHeartbeat = nil
        if !state.steps.isEmpty { state.planConfirmed = false }
    }
}
