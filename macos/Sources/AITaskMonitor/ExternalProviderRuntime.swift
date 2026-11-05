import Foundation

enum ExternalProviderConnectionState { case disconnected, partial, connected, connectedDegraded }

// This runtime is enabled only for explicitly connected providers by its caller.
final class ExternalProviderRuntime {
    private let channel: ExternalProviderChannel
    private let store = ExternalProviderStateStore()

    init(channel: ExternalProviderChannel) { self.channel = channel }

    func snapshot(allowed: Set<TaskProvider>, profileScopes: [TaskProvider: Set<String>] = [:],
                  uncertainScopes: [TaskProvider: Set<String>] = [:], now: Date = Date()) -> [MonitoredTask] {
        let permitted = allowed.intersection([.kimi, .deepseek, .hermes, .opencode])
        channel.setAllowedProviders(Set(permitted.map(\.rawValue)))
        store.retainProviders(Set(permitted.map(\.rawValue)))
        for (provider, scopes) in profileScopes where permitted.contains(provider) {
            store.retainSessionScopes(provider: provider.rawValue, scopes: scopes.union(uncertainScopes[provider] ?? []))
        }
        let batch = channel.drain()
        if batch.gap { store.markGap() }
        for event in batch.events {
            guard let provider = TaskProvider(rawValue: event.provider), permitted.contains(provider) else { continue }
            if let scopes = profileScopes[provider], !scopes.contains(ExternalProviderStateStore.sessionScope(event.session)) { continue }
            guard let received = event.receivedAt, received <= now.addingTimeInterval(60) else {
                store.markGap()
                continue
            }
            _ = store.apply(event, now: min(received, now))
        }
        for (provider, scopes) in uncertainScopes where permitted.contains(provider) {
            store.markSessionScopesGap(provider: provider.rawValue, scopes: scopes)
        }
        return ExternalProviderTaskMapper.tasks(store.snapshot(now: now))
    }

    @discardableResult
    func stop() -> Bool { channel.stop() }
}
