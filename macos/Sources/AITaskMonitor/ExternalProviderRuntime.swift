import Foundation

enum ExternalProviderConnectionState { case disconnected, partial, connected, connectedDegraded }
enum ExternalProviderRuntimeError: Error { case stopped }

// Scope ownership is never inferred from a task name or a missing profile list.
enum ExternalProfileVisibility {
    private static let neutralPrefix = "deepseek-unassigned:"

    static func neutralDeepSeek(_ task: MonitoredTask) -> MonitoredTask? {
        guard task.provider == .deepseek else { return nil }
        let session: String
        if task.id.hasPrefix(neutralPrefix) { session = String(task.id.dropFirst(neutralPrefix.count)) }
        else if task.id.hasPrefix("deepseek:") { session = String(task.id.dropFirst("deepseek:".count)) }
        else { return nil }
        guard session.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return MonitoredTask(id: neutralPrefix + session, provider: .deepseek,
            title: tr("Задача DeepSeek Harness", "DeepSeek Harness task"),
            activity: tr("Статус не подтверждён", "Status unconfirmed"),
            isActive: false, progress: nil, progressKind: .none, steps: [],
            updatedAt: task.updatedAt, isUnconfirmed: true, isWaiting: false,
            startedAt: .distantPast, startKey: "", planConfirmed: false)
    }

    static func scopedSession(_ session: String) -> String? {
        let bytes = Array(session.utf8)
        guard (34...128).contains(bytes.count), bytes[32] == 95,
              bytes.prefix(32).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              bytes.dropFirst(33).allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return String(decoding: bytes.prefix(32), as: UTF8.self)
    }

    static func filter(_ tasks: [MonitoredTask], allowed: Set<TaskProvider>,
                       profileScopes: [TaskProvider: Set<String>],
                       uncertainScopes: [TaskProvider: Set<String>],
                       ambiguousScopes: [TaskProvider: Set<String>],
                       deepSeekDisabledScopes: Set<String> = []) -> [MonitoredTask] {
        tasks.compactMap { task in
            guard allowed.contains(task.provider) else { return nil }
            if task.provider == .deepseek, task.id.hasPrefix(neutralPrefix) {
                let session = String(task.id.dropFirst(neutralPrefix.count))
                if let scope = scopedSession(session), deepSeekDisabledScopes.contains(scope),
                   !(ambiguousScopes[.deepseek] ?? []).contains(scope) { return nil }
                return neutralDeepSeek(task)
            }
            guard [.deepseek, .kimi, .hermes].contains(task.provider) else { return task.provider == .opencode ? task : nil }
            let prefix = task.provider.rawValue + ":"
            guard task.id.hasPrefix(prefix), let scope = scopedSession(String(task.id.dropFirst(prefix.count))) else { return nil }
            let visible = (profileScopes[task.provider] ?? []).union(uncertainScopes[task.provider] ?? [])
            return visible.contains(scope) && !(ambiguousScopes[task.provider] ?? []).contains(scope) ? task : nil
        }
    }
}

// This runtime is enabled only for explicitly connected providers by its caller.
final class ExternalProviderRuntime {
    private let channel: ExternalProviderChannel
    private var store = ExternalProviderStateStore()
    private(set) var transportUnavailable = false
    var capacityLimitedProviders: Set<TaskProvider> { Set(store.capacityLimitedProviders.compactMap(TaskProvider.init(rawValue:))) }
    #if DEBUG
    var testAfterDrain: (() -> Void)?
    #endif

    init(channel: ExternalProviderChannel) { self.channel = channel }

    func adoptState(_ saved: ExternalProviderStateStore) { store = saved }

    // V1 has no producer generation: a queued old callback cannot certify the
    // current instance after the monitor has restarted.
    func markV1Unconfirmed() {
        store.markGap(provider: "opencode")
        store.markGap(provider: "deepseek")
    }

    func parkState(markTransportGap: Bool) -> ExternalProviderStateStore {
        if markTransportGap { store.markGap() }
        store.retainProviders([])
        return store
    }

    func snapshot(allowed: Set<TaskProvider>, profileScopes: [TaskProvider: Set<String>] = [:],
                  uncertainScopes: [TaskProvider: Set<String>] = [:],
                  ambiguousScopes: [TaskProvider: Set<String>] = [:],
                  deepSeekHistoryLost: Bool = false, deepSeekDisabledScopes: Set<String> = [],
                  now: Date = Date()) -> [MonitoredTask] {
        guard !channel.isStopped else { store.markGap(); transportUnavailable = true; return [] }
        let permitted = allowed.intersection([.kimi, .deepseek, .hermes, .opencode])
        channel.setAllowedProviders(Set(permitted.map(\.rawValue)))
        store.retainProviders(Set(permitted.map(\.rawValue)))
        for provider in [TaskProvider.deepseek, .kimi, .hermes] where permitted.contains(provider) {
            let scopes = profileScopes[provider] ?? []
            // DeepSeek history is not an allowance and must not exhaust the live roster.
            let retained = provider == .deepseek ? scopes : scopes.union(uncertainScopes[provider] ?? [])
            store.retainSessionScopes(provider: provider.rawValue, scopes: retained)
        }
        if permitted.contains(.deepseek) {
            store.markDeepSeekOwnershipUnknown(allowed: profileScopes[.deepseek] ?? [],
                ambiguous: ambiguousScopes[.deepseek] ?? [], historyLost: deepSeekHistoryLost,
                disabled: deepSeekDisabledScopes)
        }
        let batch = channel.drain()
        #if DEBUG
        testAfterDrain?()
        #endif
        guard !channel.isStopped else { store.markGap(); transportUnavailable = true; return [] }
        if batch.gap { store.markGap() }
        for event in batch.events {
            guard let provider = TaskProvider(rawValue: event.provider), permitted.contains(provider) else { continue }
            if provider == .deepseek {
                let scope = ExternalProfileVisibility.scopedSession(event.session)
                let ambiguous = ambiguousScopes[.deepseek] ?? []
                if let scope, deepSeekDisabledScopes.contains(scope), !ambiguous.contains(scope) { continue }
                let owned = scope.map { (profileScopes[.deepseek] ?? []).contains($0) && !ambiguous.contains($0) } ?? false
                let knownUncertain = scope.map { (uncertainScopes[.deepseek] ?? []).contains($0) && !ambiguous.contains($0) } ?? false
                if !owned && knownUncertain && !store.isDeepSeekUnassigned(event.session) { continue }
                if !owned || store.isDeepSeekUnassigned(event.session) {
                    guard let received = event.receivedAt, received <= now.addingTimeInterval(60) else {
                        if let scope { store.markSessionScopesGap(provider: "deepseek", scopes: [scope]) }
                        continue
                    }
                    _ = store.applyUnassignedDeepSeek(event, now: min(received, now))
                    continue
                }
            }
            if [.deepseek, .kimi, .hermes].contains(provider) {
                guard let scope = ExternalProfileVisibility.scopedSession(event.session),
                      (profileScopes[provider] ?? []).contains(scope),
                      !(ambiguousScopes[provider] ?? []).contains(scope) else { continue }
            }
            guard let received = event.receivedAt, received <= now.addingTimeInterval(60) else {
                store.markGap()
                continue
            }
            _ = store.apply(event, now: min(received, now))
        }
        for (provider, scopes) in uncertainScopes where permitted.contains(provider) {
            store.markSessionScopesGap(provider: provider.rawValue, scopes: scopes)
        }
        let tasks = ExternalProviderTaskMapper.tasks(store.snapshot(now: now))
        return ExternalProfileVisibility.filter(tasks, allowed: permitted, profileScopes: profileScopes,
            uncertainScopes: uncertainScopes, ambiguousScopes: ambiguousScopes, deepSeekDisabledScopes: deepSeekDisabledScopes)
    }

    @discardableResult
    func stop() -> Bool { channel.stop() }
}
