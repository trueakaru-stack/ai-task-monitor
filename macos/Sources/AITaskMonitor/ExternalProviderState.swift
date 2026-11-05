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
    private var hermesScopeBarriers: [String: Int64] = [:]
    private var hermesScopes: Set<String> = []
    private var hermesUncertainScopes: Set<String> = []
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
            markGap(provider: event.provider)
            return true
        }
        let key = event.provider + ":" + event.session
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
                let removable = states.filter { $0.value.status != "active" && $0.value.status != "waiting" }
                    .min { $0.value.updatedAt < $1.value.updatedAt }
                guard let oldest = removable?.key else { markGap(); return false }
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

    func markGap(provider: String? = nil) {
        if provider == nil || provider == "hermes" { hermesBarrier = max(hermesBarrier, Self.monotonicNanoseconds()) }
        for key in Array(states.keys) {
            if let provider, states[key]?.provider != provider { continue }
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
        states = states.filter { allowed.contains($0.value.provider) }
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
        if provider == "hermes" {
            updateHermesScopeBarriers(hermesScopes.symmetricDifference(scopes))
            hermesScopes = scopes
        }
        states = states.filter { $0.value.provider != provider || scopes.contains(Self.sessionScope($0.value.session)) }
    }

    func markSessionScopesGap(provider: String, scopes: Set<String>) {
        if provider == "hermes" {
            updateHermesScopeBarriers(hermesUncertainScopes.symmetricDifference(scopes))
            hermesUncertainScopes = scopes
        }
        for key in Array(states.keys) {
            guard let state = states[key], state.provider == provider,
                  scopes.contains(Self.sessionScope(state.session)) else { continue }
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
