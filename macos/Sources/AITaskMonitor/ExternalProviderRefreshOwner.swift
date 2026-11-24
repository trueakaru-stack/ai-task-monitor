import Foundation

// The caller must keep its last published snapshot while a read is pending.
// A delayed or invalidated capture still carries its evidence to the caller;
// it must not by itself confirm statuses or discard terminal events.
enum ExternalProviderRefreshQuality: Equatable {
    case current
    case delayed
    case invalidated
}

struct ExternalProviderRefreshDelivery<Capture> {
    let capture: Capture?
    let quality: ExternalProviderRefreshQuality
}

// Owners of the same endpoints must share this lease. Undelivered captures
// remain here until the next owner takes them as unconfirmed evidence.
final class ExternalProviderRefreshLease<Capture> {
    private let lock = NSLock()
    private var holder: UUID?
    private var pending: [Capture] = []

    fileprivate func claim(_ owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if holder == nil { holder = owner }
        return holder == owner
    }

    fileprivate func hasPending(_ owner: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return holder == owner && !pending.isEmpty
    }

    fileprivate func append(_ value: Capture, owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        precondition(holder == owner && pending.count < 2)
        pending.append(value)
    }

    fileprivate func take(_ owner: UUID) -> Capture? {
        lock.lock(); defer { lock.unlock() }
        guard holder == owner && !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    fileprivate func release(_ owner: UUID) {
        lock.lock(); defer { lock.unlock() }
        if holder == owner { holder = nil }
    }
}

// This queue is the sole owner of the supplied source operations. `read` must
// return a capture even on partial failure, including any events it already
// consumed and an explicit gap when their completeness cannot be proved. The
// finish operation must similarly return events drained during shutdown or a
// capture indicating a gap. Resources must be opened only after lease claim.
// The caller must close the owner, including from its own deinitialization.
final class ExternalProviderRefreshOwner<Request, Capture> {
    private let queue = DispatchQueue(label: "ai-task-monitor.external-source", qos: .utility)
    private let control = NSLock()
    private let read: (Request) -> Capture
    private let finish: () -> Capture?
    private let monotonicNow: () -> TimeInterval
    private let pollInterval: TimeInterval
    private let lease: ExternalProviderRefreshLease<Capture>
    private let identity = UUID()
    private var busy = false
    private var closed = false
    private var ownsLease = false
    private var generation: UInt64 = 0
    private var startedAt: TimeInterval?

    init(lease: ExternalProviderRefreshLease<Capture> = ExternalProviderRefreshLease(),
         pollInterval: TimeInterval = 2,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping (Request) -> Capture,
         finish: @escaping () -> Capture? = { nil }) {
        precondition(pollInterval.isFinite && pollInterval > 0)
        self.pollInterval = pollInterval
        self.lease = lease
        self.monotonicNow = monotonicNow
        self.read = read
        self.finish = finish
    }

    @MainActor
    @discardableResult
    func tryRead(_ request: Request, completion: @escaping @MainActor (ExternalProviderRefreshDelivery<Capture>) -> Void) -> Bool {
        control.lock()
        guard !closed && !busy else { control.unlock(); return false }
        guard lease.claim(identity) else { control.unlock(); return false }
        ownsLease = true
        guard !lease.hasPending(identity) else { control.unlock(); return false }
        busy = true
        startedAt = nil
        let requested = generation
        control.unlock()
        queue.async {
            self.control.lock()
            let mayStart = !self.closed && self.generation == requested
            let start = self.monotonicNow()
            if mayStart { self.startedAt = start }
            self.control.unlock()
            let capture = mayStart ? self.read(request) : nil
            if let capture { self.lease.append(capture, owner: self.identity) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.control.lock()
                guard !self.closed else { self.control.unlock(); return }
                let now = self.monotonicNow()
                let quality: ExternalProviderRefreshQuality
                if self.generation != requested || !mayStart {
                    quality = .invalidated
                } else if !now.isFinite || !start.isFinite || now < start || now - start >= self.pollInterval {
                    quality = .delayed
                } else {
                    quality = .current
                }
                self.busy = false
                self.startedAt = nil
                let delivered = mayStart ? self.lease.take(self.identity) : nil
                self.control.unlock()
                completion(ExternalProviderRefreshDelivery(capture: delivered, quality: quality))
            }
        }
        return true
    }

    // A callback from another source does not by itself imply a timeout.
    @MainActor
    func isDelayed() -> Bool {
        control.lock(); defer { control.unlock() }
        guard busy, let start = startedAt else { return false }
        let now = monotonicNow()
        return !now.isFinite || !start.isFinite || now < start || now - start >= pollInterval
    }

    @MainActor
    func invalidate() {
        control.lock(); generation &+= 1; control.unlock()
    }

    // This evidence was consumed by an earlier owner but not delivered. It
    // must be reconciled before a successor starts reading the same channels.
    @MainActor
    func takeHandoff() -> ExternalProviderRefreshDelivery<Capture>? {
        control.lock(); defer { control.unlock() }
        guard !closed && !busy, lease.claim(identity) else { return nil }
        ownsLease = true
        guard let capture = lease.take(identity) else { return nil }
        return ExternalProviderRefreshDelivery(capture: capture, quality: .invalidated)
    }

    // Closing never waits for source I/O. Resource cleanup remains ordered
    // after the in-flight operation and must not race another owner.
    @MainActor
    func close() { shutdown() }

    func shutdownForOwnerDeinit() { shutdown() }

    private func shutdown() {
        control.lock()
        guard !closed else { control.unlock(); return }
        closed = true
        generation &+= 1
        let releaseLease = ownsLease
        control.unlock()
        guard releaseLease else { return }
        queue.async {
            if let remaining = self.finish() { self.lease.append(remaining, owner: self.identity) }
            self.lease.release(self.identity)
        }
    }
}
