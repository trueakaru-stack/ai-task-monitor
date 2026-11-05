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

/// Coordinates one update request at a time and ignores outcomes from older requests.
@MainActor
final class ReleaseUpdateCoordinator {
    private enum ScheduleOutcome {
        case succeeded, failed(ReleaseHTTPResponse?), abandoned
    }

    private let schedule: ReleaseRetrySchedule
    private let makeRequest: ReleaseRequestFactory
    private let parseData: ReleaseDataParser
    private let parser: ReleaseParseWorker
    private let acceptUpdate: (AvailableUpdate?) -> Void
    private let scheduleDeadline: ReleaseDeadlineScheduler
    private let executeStorage: ReleaseStorageExecutor
    private var request: (any ReleaseRequesting)?
    private var cancelDeadline: (() -> Void)?
    private var preparation: ReleasePreparationToken?
    private var parsing: ReleasePreparationToken?
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
    private func finish(_ outcome: ScheduleOutcome, generation expected: UInt64) {
        operationPending = true
        let schedule = self.schedule
        executeStorage { [weak self] in
            switch outcome {
            case .succeeded: schedule.succeeded()
            case .failed(let response): schedule.failed(response)
            case .abandoned: schedule.abandon()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.generation == expected else { return }
                self.operationPending = false
            }
        }
    }

    private func deadlineExpired(_ expected: UInt64) {
        guard !stopped, generation == expected, let pending = request else { return }
        generation &+= 1
        let newGeneration = generation
        operationPending = true
        request = nil
        clearDeadline()
        pending.cancel()
        finish(.failed(nil), generation: newGeneration)
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
        do {
            let nextRequest = try makeRequest { [weak self] outcome in
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.generation == currentGeneration,
                          self.request != nil else { return }
                    self.operationPending = true
                    self.request = nil
                    self.clearDeadline()
                    let result: ScheduleOutcome
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
            request = nextRequest
            cancelDeadline = scheduleDeadline { [weak self] in
                DispatchQueue.main.async { self?.deadlineExpired(currentGeneration) }
            }
            try nextRequest.start()
            operationPending = false
        } catch {
            let failedRequest = request
            request = nil
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
        clearDeadline()
        pending?.cancel()
        let schedule = self.schedule
        executeStorage { schedule.abandon() }
    }

    deinit {
        preparation?.cancel()
        parsing?.cancel()
        cancelDeadline?()
        request?.cancel()
        let schedule = self.schedule
        executeStorage { schedule.abandon() }
    }
}
