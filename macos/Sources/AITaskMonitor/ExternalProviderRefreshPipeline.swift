import Foundation

struct ExternalProviderPipelineBatch {
    let capture: ExternalProviderRefreshCapture
    let providers: Set<TaskProvider>
}

private struct ExternalProviderPipelineRequest<Request> {
    let value: Request
    let generations: [TaskProvider: UInt64]
}

// Used only on the source queue. Handoff is stamped with the generations
// under which its events were consumed, including after window teardown.
private final class ExternalProviderPipelineRunner<Request> {
    private let read: (Request) -> ExternalProviderPipelineBatch
    private let finish: () -> ExternalProviderPipelineBatch?
    private var lastGenerations: [TaskProvider: UInt64] = [:]

    init(read: @escaping (Request) -> ExternalProviderPipelineBatch,
         finish: @escaping () -> ExternalProviderPipelineBatch?) {
        self.read = read
        self.finish = finish
    }

    func run(_ request: ExternalProviderPipelineRequest<Request>) -> ExternalProviderPipelineBatch {
        lastGenerations = request.generations
        return stamp(read(request.value))
    }

    func close() -> ExternalProviderPipelineBatch? {
        finish().map(stamp)
    }

    private func stamp(_ batch: ExternalProviderPipelineBatch) -> ExternalProviderPipelineBatch {
        var capture = batch.capture
        capture.sourceGenerations = lastGenerations
        return ExternalProviderPipelineBatch(capture: capture, providers: batch.providers)
    }
}

// Coordinates refresh requests only. Source setup and user commands require
// their own ordered handling; they must never be silently coalesced here.
@MainActor
final class ExternalProviderRefreshPipeline<Request> {
    private let owner: ExternalProviderRefreshOwner<ExternalProviderPipelineRequest<Request>, ExternalProviderPipelineBatch>
    private let onChange: (ExternalProviderRefreshCache) -> Void
    private(set) var cache: ExternalProviderRefreshCache
    private(set) var isInFlight = false
    private(set) var isWaitingForLease = false
    private var activeProviders: Set<TaskProvider> = []
    private var activeGenerations: [TaskProvider: UInt64] = [:]
    private var pending: (request: Request, providers: Set<TaskProvider>)?
    private var delayedMarked = false
    private var closed = false

    init(lease: ExternalProviderRefreshLease<ExternalProviderPipelineBatch> = ExternalProviderRefreshLease(),
         initialCache: ExternalProviderRefreshCache = ExternalProviderRefreshCache(),
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping (Request) -> ExternalProviderPipelineBatch,
         finish: @escaping () -> ExternalProviderPipelineBatch? = { nil },
         onChange: @escaping (ExternalProviderRefreshCache) -> Void) {
        let runner = ExternalProviderPipelineRunner(read: read, finish: finish)
        owner = ExternalProviderRefreshOwner(lease: lease, monotonicNow: monotonicNow,
                                             read: { runner.run($0) }, finish: { runner.close() })
        cache = initialCache
        self.onChange = onChange
    }

    deinit { owner.shutdownForOwnerDeinit() }

    // Repeated refreshes are coalesced; the source operation itself is never
    // run concurrently. Only elapsed time in the worker marks a delay.
    func poll(_ request: Request, providers: Set<TaskProvider>) {
        guard !closed else { return }
        if isInFlight {
            pending = (request, providers)
            if owner.isDelayed() && !delayedMarked {
                delayedMarked = true
                cache.markUncertain(activeProviders, sourceGenerations: activeGenerations)
                onChange(cache)
            }
            return
        }
        var receivedHandoff = false
        while let delivery = owner.takeHandoff(), let batch = delivery.capture {
            cache.apply(batch.capture, quality: .invalidated, providers: batch.providers)
            receivedHandoff = true
        }
        if receivedHandoff { onChange(cache) }
        let generations = cache.sourceGenerations
        let requestWithGeneration = ExternalProviderPipelineRequest(value: request, generations: generations)
        let started = owner.tryRead(requestWithGeneration) { [weak self] delivery in
            guard let self, !self.closed else { return }
            let requestedProviders = self.activeProviders
            self.isInFlight = false
            self.delayedMarked = false
            let capturedProviders = delivery.capture?.providers ?? requestedProviders
            let quality: ExternalProviderRefreshQuality = capturedProviders == requestedProviders
                ? delivery.quality : .invalidated
            self.cache.apply(delivery.capture?.capture, quality: quality,
                             providers: requestedProviders.union(capturedProviders),
                             sourceGenerations: self.activeGenerations)
            self.onChange(self.cache)
            if let next = self.pending {
                self.pending = nil
                self.poll(next.request, providers: next.providers)
            }
        }
        if started {
            isInFlight = true
            isWaitingForLease = false
            activeProviders = providers
            activeGenerations = generations
            pending = nil
        } else {
            isWaitingForLease = true
            pending = (request, providers)
        }
    }

    func invalidate(_ request: Request, providers: Set<TaskProvider>) {
        guard !closed else { return }
        owner.invalidate()
        let generations = isInFlight ? activeGenerations : cache.sourceGenerations
        cache.markUncertain(isInFlight ? activeProviders : providers, sourceGenerations: generations)
        onChange(cache)
        if isInFlight { pending = (request, providers) }
        else { poll(request, providers: providers) }
    }

    // The caller invokes these only after an actual source connection change.
    // An old read may still finish, but its stamped generation cannot undo it.
    @discardableResult
    func confirmDisconnected(_ provider: TaskProvider) -> UInt64? {
        guard !closed, let generation = cache.confirmDisconnected(provider) else { return nil }
        onChange(cache)
        return generation
    }

    @discardableResult
    func beginReconnection(_ provider: TaskProvider) -> UInt64? {
        guard !closed, let generation = cache.beginReconnection(provider) else { return nil }
        onChange(cache)
        return generation
    }

    func close() {
        guard !closed else { return }
        closed = true
        pending = nil
        owner.close()
    }
}
