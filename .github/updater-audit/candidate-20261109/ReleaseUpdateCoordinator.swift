import Foundation

typealias ReleaseDeadlineScheduler = (@escaping () -> Void) -> () -> Void
typealias ReleaseStorageExecutor = (@escaping () -> Void) -> Void
typealias ReleaseDataParser = @Sendable (Data) -> (valid: Bool, update: AvailableUpdate?)
typealias ReleaseParseExecutor = (@escaping @Sendable () -> Void) -> Void

private final class ReleasePreparationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// A timed-out parser may still be running. Do not queue more work behind it.
private final class ReleaseParseWorker: @unchecked Sendable {
    private let lock = NSLock()
    private let execute: ReleaseParseExecutor
    private var busy = false

    init(execute: @escaping ReleaseParseExecutor) { self.execute = execute }

    func submit(_ work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        execute { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            work()
        }
        return true
    }
}

private enum ReleaseScheduleOutcome {
    case succeeded, failed(ReleaseHTTPResponse?), abandoned
}

/// Retains the canceled request and its pending finalizer until the task's
/// terminal callback. If it never arrives, the lease is deliberately retained.
private final class ReleaseTerminalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private var waiting: (() -> Void)?
    private var retainedRequest: (any ReleaseRequesting)?
    private var retainSelf: ReleaseTerminalGate?

    func afterTerminal(retaining request: any ReleaseRequesting, _ action: @escaping () -> Void) {
        lock.lock()
        if terminal { lock.unlock(); action(); return }
        precondition(waiting == nil)
        waiting = action
        retainedRequest = request
        retainSelf = self
        lock.unlock()
    }

    func signalTerminal() {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let action = waiting
        let request = retainedRequest
        waiting = nil
        retainedRequest = nil
        retainSelf = nil
        lock.unlock()
        withExtendedLifetime(request) { action?() }
    }
}

// These closures are created outside the main actor: receipt callbacks can
// arrive on the URLSession delegate queue. Storage remains on its serial queue.
private func makeResponseCollector(schedule: ReleaseRetrySchedule,
                                   execute: @escaping ReleaseStorageExecutor) -> ReleaseResponseCollector {
    ReleaseResponseCollector { hint in execute { schedule.recordHint(hint) } }
}

private func persistCapturedOutcome(_ outcome: ReleaseScheduleOutcome, collector: ReleaseResponseCollector?,
                                    schedule: ReleaseRetrySchedule, execute: @escaping ReleaseStorageExecutor,
                                    onMain: @escaping @MainActor () -> Void) {
    let save: ([ReleaseHTTPResponse]) -> Void = { hints in
        execute {
            switch outcome {
            case .succeeded: schedule.succeeded(hints)
            case .failed(let response): schedule.failed(response, hints: hints)
            case .abandoned: schedule.abandon(hints)
            }
            DispatchQueue.main.async { onMain() }
        }
    }
    if let collector { collector.seal(save) } else { save([]) }
}

/// Coordinates one update request at a time and ignores outcomes from older requests.
@MainActor
final class ReleaseUpdateCoordinator {
    private let schedule: ReleaseRetrySchedule
    private let makeRequest: ReleaseRequestFactory
    private let parseData: ReleaseDataParser
    private let parser: ReleaseParseWorker
    private let acceptUpdate: (AvailableUpdate?) -> Void
    private let scheduleDeadline: ReleaseDeadlineScheduler
    private let executeStorage: ReleaseStorageExecutor
    private var request: (any ReleaseRequesting)?
    private var terminalGate: ReleaseTerminalGate?
    private var cancelDeadline: (() -> Void)?
    private var preparation: ReleasePreparationToken?
    private var parsing: ReleasePreparationToken?
    private var responseCollector: ReleaseResponseCollector?
    private var finalizing = false
    private var operationPending = false
    private var generation: UInt64 = 0
    private var stopped = false

    init(schedule: ReleaseRetrySchedule, makeRequest: @escaping ReleaseRequestFactory,
         scheduleDeadline: ReleaseDeadlineScheduler? = nil,
         executeStorage: ReleaseStorageExecutor? = nil,
         executeParser: ReleaseParseExecutor? = nil,
         currentVersion: String = AppVersion.current,
         parseData: ReleaseDataParser? = nil,
         acceptUpdate: @escaping (AvailableUpdate?) -> Void) {
        self.schedule = schedule
        self.makeRequest = makeRequest
        self.scheduleDeadline = scheduleDeadline ?? { fire in
            let task = Task {
                do { try await Task.sleep(for: .seconds(20), clock: .continuous) }
                catch { return }
                fire()
            }
            return { task.cancel() }
        }
        let queue = DispatchQueue(label: "AI Task Monitor updater storage", qos: .utility)
        self.executeStorage = executeStorage ?? { work in queue.async(execute: work) }
        let parserQueue = DispatchQueue(label: "AI Task Monitor updater parser", qos: .utility)
        self.parser = ReleaseParseWorker(execute: executeParser ?? { work in parserQueue.async(execute: work) })
        self.parseData = parseData ?? { data in ReleaseSelector.inspect(data: data, currentVersion: currentVersion) }
        self.acceptUpdate = acceptUpdate
    }

    private func clearDeadline() {
        cancelDeadline?()
        cancelDeadline = nil
    }

    /// Every schedule read, write, fsync and lease release uses one serial queue.
    private func finish(_ outcome: ReleaseScheduleOutcome, generation expected: UInt64) {
        guard !finalizing else { return }
        finalizing = true
        operationPending = true
        let collector = responseCollector
        responseCollector = nil
        persistCapturedOutcome(outcome, collector: collector, schedule: schedule, execute: executeStorage) { [weak self] in
            guard let self else { return }
            self.finalizing = false
            guard !self.stopped, self.generation == expected else { return }
            self.operationPending = false
        }
    }

    private func finishAfterTerminal(_ outcome: ReleaseScheduleOutcome, generation expected: UInt64,
                                     request pending: any ReleaseRequesting, gate: ReleaseTerminalGate) {
        guard !finalizing else { return }
        finalizing = true
        operationPending = true
        let collector = responseCollector
        responseCollector = nil
        let schedule = self.schedule, executor = executeStorage
        let onMain: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.finalizing = false
            guard !self.stopped, self.generation == expected else { return }
            self.operationPending = false
        }
        gate.afterTerminal(retaining: pending) {
            persistCapturedOutcome(outcome, collector: collector, schedule: schedule, execute: executor, onMain: onMain)
        }
    }

    private func deadlineExpired(_ expected: UInt64) {
        guard !stopped, generation == expected, let pending = request, let gate = terminalGate else { return }
        generation &+= 1
        let newGeneration = generation
        operationPending = true
        request = nil
        terminalGate = nil
        clearDeadline()
        finishAfterTerminal(.failed(nil), generation: newGeneration, request: pending, gate: gate)
        pending.cancel()
    }

    private func parserDeadlineExpired(_ expected: UInt64) {
        guard !stopped, generation == expected, let token = parsing else { return }
        generation &+= 1
        let newGeneration = generation
        token.cancel()
        parsing = nil
        clearDeadline()
        finish(.failed(nil), generation: newGeneration)
    }

    private func startParsing(_ data: Data, generation expected: UInt64) {
        let token = ReleasePreparationToken()
        parsing = token
        cancelDeadline = scheduleDeadline { [weak self] in
            DispatchQueue.main.async { self?.parserDeadlineExpired(expected) }
        }
        let parse = parseData
        let accepted = parser.submit { [weak self] in
            guard !token.isCancelled else { return }
            let result = parse(data)
            guard !token.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.generation == expected,
                      self.parsing === token else { return }
                self.parsing = nil
                self.clearDeadline()
                if result.valid {
                    self.acceptUpdate(result.update)
                    guard !self.stopped, self.generation == expected else { return }
                    self.finish(.succeeded, generation: expected)
                } else {
                    self.finish(.failed(nil), generation: expected)
                }
            }
        }
        if !accepted {
            token.cancel()
            parsing = nil
            clearDeadline()
            finish(.failed(nil), generation: expected)
        }
    }

    func check() {
        guard !stopped, !operationPending, request == nil else { return }
        operationPending = true
        generation &+= 1
        let currentGeneration = generation
        let token = ReleasePreparationToken()
        preparation = token
        let schedule = self.schedule
        let executor = self.executeStorage
        executor { [weak self] in
            guard !token.isCancelled else { return }
            let allowed = schedule.beginIfDue()
            if token.isCancelled {
                if allowed { schedule.abandon() }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.generation == currentGeneration else {
                    if allowed { executor { schedule.abandon() } }
                    return
                }
                self.preparation = nil
                guard allowed else { self.operationPending = false; return }
                self.startRequest(generation: currentGeneration)
            }
        }
    }

    private func startRequest(generation currentGeneration: UInt64) {
        let collector = makeResponseCollector(schedule: schedule, execute: executeStorage)
        responseCollector = collector
        let gate = ReleaseTerminalGate()
        do {
            let nextRequest = try makeRequest { [weak self] outcome in
                gate.signalTerminal()
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.generation == currentGeneration,
                          self.request != nil else { return }
                    self.operationPending = true
                    self.request = nil
                    self.terminalGate = nil
                    self.clearDeadline()
                    let result: ReleaseScheduleOutcome
                    switch outcome {
                    case .success(let data):
                        self.startParsing(data, generation: currentGeneration)
                        return
                    case .httpFailure(let response): result = .failed(response)
                    case .transportFailure, .oversized: result = .failed(nil)
                    case .cancelled: result = .abandoned
                    }
                    self.finish(result, generation: currentGeneration)
                }
            }
            nextRequest.attachResponseCollector(collector)
            request = nextRequest
            terminalGate = gate
            cancelDeadline = scheduleDeadline { [weak self] in
                DispatchQueue.main.async { self?.deadlineExpired(currentGeneration) }
            }
            try nextRequest.start()
            operationPending = false
        } catch {
            let failedRequest = request
            request = nil
            terminalGate = nil
            generation &+= 1
            let newGeneration = generation
            clearDeadline()
            failedRequest?.cancel()
            finish(.failed(nil), generation: newGeneration)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        parsing?.cancel()
        parsing = nil
        let pending = request
        request = nil
        let gate = terminalGate
        terminalGate = nil
        clearDeadline()
        if let pending, let gate {
            finishAfterTerminal(.abandoned, generation: generation, request: pending, gate: gate)
            pending.cancel()
        } else if !finalizing { finish(.abandoned, generation: generation) }
    }

    deinit {
        preparation?.cancel()
        parsing?.cancel()
        cancelDeadline?()
        if let pending = request, let gate = terminalGate, !finalizing {
            let collector = responseCollector, schedule = self.schedule, executor = executeStorage
            gate.afterTerminal(retaining: pending) {
                persistCapturedOutcome(.abandoned, collector: collector, schedule: schedule, execute: executor, onMain: {})
            }
            pending.cancel()
        } else if !finalizing {
            persistCapturedOutcome(.abandoned, collector: responseCollector,
                                   schedule: schedule, execute: executeStorage, onMain: {})
        }
    }
}
