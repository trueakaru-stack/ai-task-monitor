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

// This queue is the sole owner of the supplied source operations. `read` must
// return a capture even on partial failure, including any events it already
// consumed and an explicit gap when their completeness cannot be proved.
// The caller must close the owner when it stops using the source.
final class ExternalProviderRefreshOwner<Request, Capture> {
    private let queue = DispatchQueue(label: "ai-task-monitor.external-source", qos: .utility)
    private let control = NSLock()
    private let read: (Request) -> Capture
    private let finish: () -> Void
    private let monotonicNow: () -> TimeInterval
    private let pollInterval: TimeInterval
    private var busy = false
    private var closed = false
    private var generation: UInt64 = 0
    private var startedAt: TimeInterval?

    init(pollInterval: TimeInterval = 2,
         monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         read: @escaping (Request) -> Capture,
         finish: @escaping () -> Void = {}) {
        precondition(pollInterval.isFinite && pollInterval > 0)
        self.pollInterval = pollInterval
        self.monotonicNow = monotonicNow
        self.read = read
        self.finish = finish
    }

    @MainActor
    @discardableResult
    func tryRead(_ request: Request, completion: @escaping @MainActor (ExternalProviderRefreshDelivery<Capture>) -> Void) -> Bool {
        control.lock()
        guard !closed && !busy else { control.unlock(); return false }
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
                self.control.unlock()
                completion(ExternalProviderRefreshDelivery(capture: capture, quality: quality))
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
        control.unlock()
        queue.async { self.finish() }
    }
}
