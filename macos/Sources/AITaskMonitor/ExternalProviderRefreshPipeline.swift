import Foundation

struct ExternalProviderPipelineBatch {
    let capture: ExternalProviderRefreshCapture
    let providers: Set<TaskProvider>
}

// Coordinates refresh requests only. Source setup and user commands require
// their own ordered handling; they must never be silently coalesced here.
@MainActor
final class ExternalProviderRefreshPipeline<Request> {
    private let owner: ExternalProviderRefreshOwner<Request, ExternalProviderPipelineBatch>
    private let onChange: (ExternalProviderRefreshCache) -> Void
    private(set) var cache: ExternalProviderRefreshCache
    private(set) var isInFlight = false
    private(set) var isWaitingForLease = false
    private var activeProviders: Set<TaskProvider> = []
    private var pending: (request: Request, providers: Set<TaskProvider>)?
    private var delayedMarked = false
    private var closed = false

    init(lease: ExternalProviderRefreshLease<ExternalProviderPipelineBatch> = ExternalProviderRefreshLease(),
         initialCache: ExternalProviderRefreshCache = ExternalProviderRefreshCache(),
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping (Request) -> ExternalProviderPipelineBatch,
         finish: @escaping () -> ExternalProviderPipelineBatch? = { nil },
         onChange: @escaping (ExternalProviderRefreshCache) -> Void) {
        owner = ExternalProviderRefreshOwner(lease: lease, monotonicNow: monotonicNow, read: read, finish: finish)
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
                cache.markUncertain(activeProviders)
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
        let started = owner.tryRead(request) { [weak self] delivery in
            guard let self, !self.closed else { return }
            let requestedProviders = self.activeProviders
            self.isInFlight = false
            self.delayedMarked = false
            let capturedProviders = delivery.capture?.providers ?? requestedProviders
            let quality: ExternalProviderRefreshQuality = capturedProviders == requestedProviders
                ? delivery.quality : .invalidated
            self.cache.apply(delivery.capture?.capture, quality: quality,
                             providers: requestedProviders.union(capturedProviders))
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
            pending = nil
        } else {
            isWaitingForLease = true
            pending = (request, providers)
        }
    }

    func invalidate(_ request: Request, providers: Set<TaskProvider>) {
        guard !closed else { return }
        owner.invalidate()
        cache.markUncertain(isInFlight ? activeProviders : providers)
        onChange(cache)
        if isInFlight { pending = (request, providers) }
        else { poll(request, providers: providers) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        pending = nil
        owner.close()
    }
}
