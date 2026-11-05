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
    // Filled by the local channel, not decoded from the sender.
    var receivedAt: Date?
}

fileprivate struct ExternalProviderCall: Equatable {
    let id: String
    let action: String
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
}

// Accept sanitized observer events only; raw agent payloads are never accepted here.
enum ExternalProviderEventParser {
    private static let providers: Set<String> = ["kimi", "deepseek", "hermes", "opencode"]
    private static let kinds: Set<String> = ["started", "active", "waiting", "unknown", "idle", "completed", "failed", "interrupted", "plan", "gap", "tool_started", "tool_finished", "heartbeat"]
    private static let fields: Set<String> = ["version", "provider", "session", "kind", "turn", "steps", "call", "action"]

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
        return ExternalProviderEvent(provider: provider, session: session, kind: kind, turn: turn, call: call, action: action, steps: steps)
    }
}

// All state stays in memory and is limited independently from the diagnostic journal.
final class ExternalProviderStateStore {
    private var states: [String: ExternalProviderTask] = [:]
    private var sequence: UInt64 = 0
    private let maximumSessions = 256
    private let staleAfter: TimeInterval = 1_800
    private let heartbeatLifetime: TimeInterval = 180

    @discardableResult
    func apply(_ event: ExternalProviderEvent, now: Date) -> Bool {
        if event.kind == "gap" { markGap(provider: event.provider); return true }
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
        if states[key] == nil {
            if states.count >= maximumSessions {
                let removable = states.filter { $0.value.status != "active" && $0.value.status != "waiting" }
                    .min { $0.value.updatedAt < $1.value.updatedAt }
                guard let oldest = removable?.key else { markGap(); return false }
                states.removeValue(forKey: oldest)
            }
            states[key] = ExternalProviderTask(provider: event.provider, session: event.session, status: "unknown",
                startKey: "", startedAt: .distantPast, updatedAt: now, steps: [], planConfirmed: true, turn: "")
        }
        guard var state = states[key] else { return false }
        expire(&state, now: now)
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
        for key in Array(states.keys) {
            if let provider, states[key]?.provider != provider { continue }
            if states[key]?.steps.isEmpty == false { states[key]?.planConfirmed = false }
            if let status = states[key]?.status, status == "active" || status == "waiting" {
                states[key]?.status = "unknown"
                states[key]?.calls.removeAll()
            }
            states[key]?.lastHeartbeat = nil
        }
    }

    func retainProviders(_ allowed: Set<String>) {
        states = states.filter { allowed.contains($0.value.provider) }
    }

    func retainSessionScopes(provider: String, scopes: Set<String>) {
        states = states.filter { $0.value.provider != provider || scopes.contains(Self.sessionScope($0.value.session)) }
    }

    func markSessionScopesGap(provider: String, scopes: Set<String>) {
        for key in Array(states.keys) {
            guard let state = states[key], state.provider == provider,
                  scopes.contains(Self.sessionScope(state.session)) else { continue }
            if !state.steps.isEmpty { states[key]?.planConfirmed = false }
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
