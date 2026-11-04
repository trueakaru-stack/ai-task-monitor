import Foundation

// This runtime is enabled only for explicitly connected providers by its caller.
final class ExternalProviderRuntime {
    private let channel: ExternalProviderChannel
    private let store = ExternalProviderStateStore()

    init(channel: ExternalProviderChannel) { self.channel = channel }

    func snapshot(allowed: Set<TaskProvider>, now: Date = Date()) -> [MonitoredTask] {
        let permitted = allowed.intersection([.kimi, .deepseek, .hermes, .opencode])
        channel.setAllowedProviders(Set(permitted.map(\.rawValue)))
        store.retainProviders(Set(permitted.map(\.rawValue)))
        let batch = channel.drain()
        if batch.gap { store.markGap() }
        for event in batch.events {
            guard let provider = TaskProvider(rawValue: event.provider), permitted.contains(provider) else { continue }
            guard let received = event.receivedAt, received <= now.addingTimeInterval(60) else {
                store.markGap()
                continue
            }
            _ = store.apply(event, now: min(received, now))
        }
        return ExternalProviderTaskMapper.tasks(store.snapshot(now: now))
    }

    @discardableResult
    func stop() -> Bool { channel.stop() }
}
