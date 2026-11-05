import Foundation
import XCTest
@testable import AITaskMonitor

private final class UpdateFixtureClock {
    var wall = Date(timeIntervalSince1970: 1_000_000)
    var monotonic: TimeInterval = 0
    var clock: ReleaseRetryClock { ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic }) }
    var sharedClock: ReleaseRetryClock {
        ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic },
                          sharedMonotonic: { UInt64(self.monotonic * 1_000_000_000) })
    }
    func advance(_ amount: TimeInterval) {
        wall = wall.addingTimeInterval(amount)
        monotonic += amount
    }
}

private enum UpdateFixtureFailure: Error { case start }

private final class UpdateFixtureRequest: ReleaseRequesting {
    let completion: (ReleaseRequestOutcome) -> Void
    var didStart = false
    var didCancel = false
    var failStart = false
    var startObserver: (() -> Void)?
    init(_ completion: @escaping (ReleaseRequestOutcome) -> Void) { self.completion = completion }
    func start() throws { didStart = true; startObserver?(); if failStart { throw UpdateFixtureFailure.start } }
    func cancel() { didCancel = true }
    func emit(_ outcome: ReleaseRequestOutcome) { completion(outcome) }
}

private final class UpdateFixtureTransport {
    var requests: [UpdateFixtureRequest] = []
    var failNextStart = false
    var startObserver: (() -> Void)?
    func make(_ completion: @escaping (ReleaseRequestOutcome) -> Void) -> any ReleaseRequesting {
        let request = UpdateFixtureRequest(completion)
        request.failStart = failNextStart
        request.startObserver = startObserver
        failNextStart = false
        requests.append(request)
        return request
    }
}

private final class UpdateFixtureDeadlines {
    final class Ticket {
        let fire: () -> Void
        var cancelled = false
        init(_ fire: @escaping () -> Void) { self.fire = fire }
    }
    var tickets: [Ticket] = []
    func schedule(_ fire: @escaping () -> Void) -> () -> Void {
        let ticket = Ticket(fire)
        tickets.append(ticket)
        return { ticket.cancelled = true }
    }
}

private final class UpdateFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class ReleaseUpdateCoordinatorTests: XCTestCase {
    private let updateJSON = Data(#"[{"tag_name":"v9.0.0","draft":false,"assets":[{"name":"app.dmg","browser_download_url":"https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v9.0.0/app.dmg"}]}]"#.utf8)

    private func drainMainQueue() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    private func withFixture(_ body: (ReleaseRetrySchedule, UpdateFixtureClock, UpdateFixtureTransport) throws -> Void) throws {
        let suite = "AITaskMonitor.synthetic-update." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = UpdateFixtureClock()
        try body(ReleaseRetrySchedule(defaults: defaults, clock: clock.clock), clock, UpdateFixtureTransport())
    }

    func testSyntheticSharedClockAdvancesWithWallAndMonotonic() throws {
        let fixture = UpdateFixtureClock()
        let clock = fixture.sharedClock
        let initialWall = clock.wall()
        let initialMonotonic = clock.monotonic()
        let shared = try XCTUnwrap(clock.sharedMonotonic)
        let initialShared = shared()
        fixture.advance(123.5)
        XCTAssertEqual(clock.wall().timeIntervalSince(initialWall), 123.5)
        XCTAssertEqual(clock.monotonic() - initialMonotonic, 123.5)
        XCTAssertEqual(shared() - initialShared, 123_500_000_000)
    }

    func testProductionMonotonicAndSharedClockUseSameTimebase() throws {
        let clock = ReleaseRetryClock.system()
        let shared = try XCTUnwrap(clock.sharedMonotonic)
        let before = shared()
        let monotonic = clock.monotonic()
        let after = shared()
        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertGreaterThanOrEqual(monotonic, Double(before) / 1_000_000_000 - 0.001)
        XCTAssertLessThanOrEqual(monotonic, Double(after) / 1_000_000_000 + 0.001)
    }

    func testSharedCheckpointNeedsSharedClockAndRespectsDeadline() throws {
        let suite = "AITaskMonitor.synthetic-clock-restore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("release-clock-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let withoutShared = UpdateFixtureClock()
        let first = ReleaseRetrySchedule(defaults: defaults, clock: withoutShared.clock,
                                         fileStore: ReleaseScheduleFileStore(directory: directory.appendingPathComponent("without")))
        XCTAssertTrue(first.beginIfDue())
        first.failed()
        withoutShared.advance(3_600)
        XCTAssertTrue(first.isDue)
        XCTAssertFalse(first.beginIfDue(), "A checkpoint without a shared clock conservatively restores the full delay.")
        XCTAssertEqual(first.delay, 3_600)

        let secondSuite = suite + ".shared"
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
        let withShared = UpdateFixtureClock()
        let second = ReleaseRetrySchedule(defaults: secondDefaults, clock: withShared.sharedClock,
                                          fileStore: ReleaseScheduleFileStore(directory: directory.appendingPathComponent("with")))
        XCTAssertTrue(second.beginIfDue())
        second.failed()
        withShared.advance(3_599)
        XCTAssertFalse(second.isDue)
        XCTAssertFalse(second.beginIfDue(), "The retry must not begin before the deadline.")
        withShared.advance(1)
        XCTAssertFalse(second.isDue, "The shared clock rounds elapsed time down conservatively.")
        withShared.advance(1)
        XCTAssertTrue(second.isDue)
        XCTAssertTrue(second.beginIfDue(), "A shared checkpoint must permit retry after the deadline.")
        second.abandon()
    }

    func testMalformedAndStructurallyInvalidBodiesRetryWhileEmptyArraySucceeds() throws {
        XCTAssertFalse(ReleaseSelector.inspect(data: Data("not json".utf8), currentVersion: "0.3.7-alpha").valid)
        XCTAssertFalse(ReleaseSelector.inspect(data: Data("[{}]".utf8), currentVersion: "0.3.7-alpha").valid)
        XCTAssertTrue(ReleaseSelector.inspect(data: Data("[]".utf8), currentVersion: "0.3.7-alpha").valid)
        try withFixture { schedule, clock, transport in
            var observed: [String] = []
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { update in
                if let update { observed.append(update.version) }
            }
            coordinator.check()
            drainMainQueue()
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 1)
            transport.requests[0].emit(.success(Data("not json".utf8)))
            drainMainQueue()
            XCTAssertEqual(schedule.delay, 3_600)
            clock.advance(3_599)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 1)
            clock.advance(1)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2)
            transport.requests[1].emit(.success(Data("[{}]".utf8)))
            drainMainQueue()
            XCTAssertEqual(schedule.delay, 3_600)
            clock.advance(3_600)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 3)
            transport.requests[2].emit(.success(Data("[]".utf8)))
            drainMainQueue()
            XCTAssertEqual(schedule.delay, 86_400)
            XCTAssertTrue(observed.isEmpty)
        }
    }

    func testFailedStartCancelsRequestAndIgnoresItsLateCompletion() throws {
        try withFixture { schedule, clock, transport in
            var deliveries = 0
            transport.failNextStart = true
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in
                deliveries += 1
            }
            coordinator.check()
            drainMainQueue()
            let failed = try XCTUnwrap(transport.requests.first)
            XCTAssertTrue(failed.didStart)
            XCTAssertTrue(failed.didCancel)
            XCTAssertEqual(schedule.delay, 3_600)
            failed.emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(deliveries, 0)
            clock.advance(3_600)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testLateOutcomeAfterTimeoutCannotOverrideTheNextRequest() throws {
        try withFixture { schedule, clock, transport in
            var observed: [String] = []
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { update in
                if let update { observed.append(update.version) }
            }
            coordinator.check()
            drainMainQueue()
            let first = try XCTUnwrap(transport.requests.first)
            XCTAssertTrue(first.didStart)
            first.emit(.transportFailure)
            drainMainQueue()
            clock.advance(3_600)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2)
            first.emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertTrue(observed.isEmpty)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2, "The later request must remain in flight.")
            transport.requests[1].emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(observed, ["9.0.0"])
            XCTAssertEqual(schedule.delay, 86_400)
        }
    }

    func testStopOrDeallocationCancelsAndIgnoresLateOutcomes() throws {
        try withFixture { schedule, _, transport in
            var deliveries = 0
            var coordinator: ReleaseUpdateCoordinator? = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in
                deliveries += 1
            }
            coordinator?.check()
            drainMainQueue()
            let first = try XCTUnwrap(transport.requests.first)
            coordinator?.stop()
            XCTAssertTrue(first.didCancel)
            first.emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(deliveries, 0)
            coordinator?.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 1)
            weak var weakCoordinator = coordinator
            coordinator = nil
            XCTAssertNil(weakCoordinator)
            first.emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(deliveries, 0)
        }
        try withFixture { schedule, _, transport in
            var coordinator: ReleaseUpdateCoordinator? = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in }
            coordinator?.check()
            drainMainQueue()
            let pending = try XCTUnwrap(transport.requests.first)
            weak var weakCoordinator = coordinator
            coordinator = nil
            XCTAssertNil(weakCoordinator)
            XCTAssertTrue(pending.didCancel)
        }
    }

    func testRateLimitWaitAndMonotonicTimeDespiteWallClockChange() throws {
        try withFixture { schedule, clock, transport in
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in }
            coordinator.check()
            drainMainQueue()
            transport.requests[0].emit(.httpFailure(ReleaseHTTPResponse(status: 403, retryAfter: "7200")))
            drainMainQueue()
            XCTAssertGreaterThanOrEqual(schedule.delay, 7_200)
            clock.wall = clock.wall.addingTimeInterval(100_000)
            clock.monotonic += 7_199
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 1)
            clock.monotonic += 2
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2)
        }
    }

    func testDeadlineCancelsHungRequestRetriesAndRejectsLateOutcome() throws {
        try withFixture { schedule, clock, transport in
            let deadlines = UpdateFixtureDeadlines()
            var delivered = 0
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        scheduleDeadline: deadlines.schedule, executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in
                delivered += 1
            }
            coordinator.check()
            drainMainQueue()
            let first = try XCTUnwrap(transport.requests.first)
            XCTAssertEqual(deadlines.tickets.count, 1)
            deadlines.tickets[0].fire()
            drainMainQueue()
            XCTAssertTrue(first.didCancel)
            XCTAssertTrue(deadlines.tickets[0].cancelled)
            XCTAssertEqual(schedule.delay, 3_600)
            clock.advance(3_600)
            coordinator.check()
            drainMainQueue()
            XCTAssertEqual(transport.requests.count, 2)
            first.emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(delivered, 0)
            transport.requests[1].emit(.success(updateJSON))
            drainMainQueue()
            XCTAssertEqual(delivered, 1)
            XCTAssertTrue(deadlines.tickets[1].cancelled)
            XCTAssertEqual(deadlines.tickets.count, 3)
            XCTAssertTrue(deadlines.tickets[2].cancelled)
        }
    }

    func testBlockedStorageDoesNotBlockStopOrStartARequestAfterStop() throws {
        try withFixture { schedule, _, transport in
            let queue = DispatchQueue(label: "synthetic blocked updater storage")
            let gate = DispatchSemaphore(value: 0)
            let entered = expectation(description: "storage worker entered")
            let drained = expectation(description: "storage worker drained")
            var firstOperation = true
            let executor: ReleaseStorageExecutor = { work in
                queue.async {
                    if firstOperation {
                        firstOperation = false
                        entered.fulfill()
                        gate.wait()
                    }
                    work()
                }
            }
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        executeStorage: executor) { _ in }
            coordinator.check()
            wait(for: [entered], timeout: 2)
            coordinator.stop()
            gate.signal()
            queue.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            drainMainQueue()
            XCTAssertTrue(transport.requests.isEmpty)
            XCTAssertTrue(schedule.isDue)
        }
    }

    func testStorageFailureDoesNotStartARequest() throws {
        let suite = "AITaskMonitor.synthetic-storage-failure." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("release-not-directory-" + UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let clock = UpdateFixtureClock()
        let schedule = ReleaseRetrySchedule(defaults: defaults, clock: clock.clock,
                                            fileStore: ReleaseScheduleFileStore(directory: file))
        let transport = UpdateFixtureTransport()
        let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                    executeStorage: { $0() }, executeParser: { $0() }, currentVersion: "0.3.7-alpha") { _ in }
        coordinator.check()
        drainMainQueue()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(schedule.delay, 86_400)
        XCTAssertEqual(try Data(contentsOf: file), Data([1]))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        for _ in 0..<5 {
            coordinator.check()
            drainMainQueue()
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathComponent("release-update.lock").path))
        clock.advance(86_401)
        coordinator.check()
        drainMainQueue()
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathComponent("release-update.lock").path))
    }

    func testStopWhileSavingAcceptedRateLimitKeepsLimitWithoutStartingAgain() throws {
        try withFixture { schedule, _, transport in
            let queue = DispatchQueue(label: "synthetic blocked updater save")
            let gate = DispatchSemaphore(value: 0)
            let began = expectation(description: "request started")
            let saving = expectation(description: "rate-limit save queued")
            let drained = expectation(description: "storage queue drained")
            transport.startObserver = { began.fulfill() }
            var operation = 0
            let executor: ReleaseStorageExecutor = { work in
                queue.async {
                    operation += 1
                    if operation == 2 { saving.fulfill(); gate.wait() }
                    work()
                }
            }
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        executeStorage: executor) { _ in }
            coordinator.check()
            wait(for: [began], timeout: 2)
            let request = try XCTUnwrap(transport.requests.first)
            request.emit(.httpFailure(ReleaseHTTPResponse(status: 429, retryAfter: "7200")))
            wait(for: [saving], timeout: 2)
            coordinator.stop()
            gate.signal()
            queue.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            drainMainQueue()
            XCTAssertGreaterThanOrEqual(schedule.delay, 7_200)
            coordinator.check()
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testSlowParserKeepsMainQueueResponsiveAndCoalescesChecks() throws {
        try withFixture { schedule, _, transport in
            let entered = expectation(description: "parser entered")
            let finished = expectation(description: "parser returned")
            let delivered = expectation(description: "update delivered")
            let firstCheck = expectation(description: "first concurrent check")
            let secondCheck = expectation(description: "second concurrent check")
            let gate = DispatchSemaphore(value: 0)
            let parser: ReleaseDataParser = { data in
                XCTAssertFalse(Thread.isMainThread)
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 10)
                let result = ReleaseSelector.inspect(data: data, currentVersion: "0.3.7-alpha")
                finished.fulfill()
                return result
            }
            var observed: [String] = []
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        executeStorage: { $0() }, parseData: parser) { update in
                if let update { observed.append(update.version) }
                delivered.fulfill()
            }
            defer { gate.signal(); coordinator.stop() }
            coordinator.check()
            drainMainQueue()
            let request = try XCTUnwrap(transport.requests.first)
            request.emit(.success(updateJSON))
            wait(for: [entered], timeout: 2)
            DispatchQueue.main.async { coordinator.check(); firstCheck.fulfill() }
            DispatchQueue.main.async { coordinator.check(); secondCheck.fulfill() }
            wait(for: [firstCheck, secondCheck], timeout: 2)
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertTrue(observed.isEmpty)
            gate.signal()
            wait(for: [finished, delivered], timeout: 2)
            XCTAssertEqual(observed, ["9.0.0"])
            XCTAssertEqual(schedule.delay, 86_400)
        }
    }

    func testStopDuringSlowParserReleasesLeaseAndRejectsLateResult() throws {
        let suite = "AITaskMonitor.synthetic-parse-stop." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("release-parse-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UpdateFixtureClock()
        let schedule = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                            fileStore: ReleaseScheduleFileStore(directory: directory))
        let observer = ReleaseScheduleFileStore(directory: directory)
        let transport = UpdateFixtureTransport()
        let started = expectation(description: "request started")
        let entered = expectation(description: "parser entered")
        let returned = expectation(description: "parser returned after stop")
        let storageDrained = expectation(description: "lease release completed")
        let gate = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "synthetic parse stop storage")
        let executor: ReleaseStorageExecutor = { work in queue.async(execute: work) }
        let parser: ReleaseDataParser = { data in
            let result = ReleaseSelector.inspect(data: data, currentVersion: "0.3.7-alpha")
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 10)
            returned.fulfill()
            return result
        }
        var deliveries = 0
        transport.startObserver = { started.fulfill() }
        let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                    executeStorage: executor, parseData: parser) { _ in deliveries += 1 }
        defer { gate.signal(); coordinator.stop() }
        coordinator.check()
        wait(for: [started], timeout: 2)
        let request = try XCTUnwrap(transport.requests.first)
        request.emit(.success(updateJSON))
        wait(for: [entered], timeout: 2)
        XCTAssertNil(try observer.acquire(), "The active parse must retain the lease.")
        coordinator.stop()
        queue.async { storageDrained.fulfill() }
        wait(for: [storageDrained], timeout: 2)
        var probe = try observer.acquire()
        XCTAssertNotNil(probe, "Stopping must release the lease without waiting for the parser.")
        probe = nil
        XCTAssertEqual(schedule.delay, 3_600)
        XCTAssertFalse(schedule.isDue)
        clock.advance(3_599)
        XCTAssertFalse(schedule.isDue)
        clock.advance(1)
        XCTAssertFalse(schedule.isDue, "Shared elapsed time is rounded down conservatively.")
        clock.advance(1)
        XCTAssertTrue(schedule.isDue)
        gate.signal()
        wait(for: [returned], timeout: 2)
        drainMainQueue()
        XCTAssertEqual(deliveries, 0)
        probe = try observer.acquire()
        XCTAssertNotNil(probe, "A late parser result must not reacquire the lease.")
        probe = nil
    }

    func testParserDeadlineReleasesLeaseAndDoesNotQueueAnotherParser() throws {
        let suite = "AITaskMonitor.synthetic-parse-timeout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("release-parse-timeout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = UpdateFixtureClock()
        let schedule = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                            fileStore: ReleaseScheduleFileStore(directory: directory))
        let observer = ReleaseScheduleFileStore(directory: directory)
        let transport = UpdateFixtureTransport()
        let deadlines = UpdateFixtureDeadlines()
        let entered = expectation(description: "parser entered")
        let returned = expectation(description: "parser returned after timeout")
        let parserDrained = expectation(description: "timed-out parser finished")
        let delivered = expectation(description: "later update delivered")
        let gate = DispatchSemaphore(value: 0)
        let parserQueue = DispatchQueue(label: "synthetic timed-out parser")
        let calls = UpdateFixtureCounter()
        let parser: ReleaseDataParser = { data in
            let result = ReleaseSelector.inspect(data: data, currentVersion: "0.3.7-alpha")
            if calls.increment() == 1 {
                entered.fulfill()
                _ = gate.wait(timeout: .now() + 10)
                returned.fulfill()
            }
            return result
        }
        var deliveries = 0
        let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                    scheduleDeadline: deadlines.schedule,
                                                    executeStorage: { $0() },
                                                    executeParser: { work in parserQueue.async(execute: work) },
                                                    parseData: parser) { _ in deliveries += 1; delivered.fulfill() }
        defer { gate.signal(); coordinator.stop() }
        coordinator.check()
        drainMainQueue()
        transport.requests[0].emit(.success(updateJSON))
        wait(for: [entered], timeout: 2)
        XCTAssertEqual(deadlines.tickets.count, 2)
        XCTAssertNil(try observer.acquire())
        deadlines.tickets[1].fire()
        drainMainQueue()
        XCTAssertEqual(schedule.delay, 3_600)
        var probe = try observer.acquire()
        XCTAssertNotNil(probe)
        probe = nil
        clock.advance(3_601)
        coordinator.check()
        drainMainQueue()
        XCTAssertEqual(transport.requests.count, 2)
        try XCTUnwrap(transport.requests.dropFirst().first).emit(.success(updateJSON))
        drainMainQueue()
        XCTAssertEqual(schedule.delay, 3_600)
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(calls.count, 1)
        gate.signal()
        parserQueue.async { parserDrained.fulfill() }
        wait(for: [returned, parserDrained], timeout: 2)
        drainMainQueue()
        XCTAssertEqual(deliveries, 0)
        clock.advance(3_601)
        coordinator.check()
        drainMainQueue()
        XCTAssertEqual(transport.requests.count, 3)
        try XCTUnwrap(transport.requests.dropFirst(2).first).emit(.success(updateJSON))
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(schedule.delay, 86_400)
    }

    func testStopAfterParseCompletionWasQueuedRejectsUpdate() throws {
        try withFixture { schedule, clock, transport in
            var pendingParse: (@Sendable () -> Void)?
            var deliveries = 0
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        executeStorage: { $0() }, executeParser: { pendingParse = $0 },
                                                        currentVersion: "0.3.7-alpha") { _ in deliveries += 1 }
            coordinator.check()
            drainMainQueue()
            transport.requests[0].emit(.success(updateJSON))
            drainMainQueue()
            try XCTUnwrap(pendingParse)()
            coordinator.stop()
            drainMainQueue()
            XCTAssertEqual(deliveries, 0)
            XCTAssertEqual(schedule.delay, 3_600)
            XCTAssertFalse(schedule.isDue)
            clock.advance(3_599)
            XCTAssertFalse(schedule.isDue)
            clock.advance(1)
            XCTAssertTrue(schedule.isDue)
        }
    }

    func testExistingNoticeSurvivesEmptyAndMalformedCoordinatorResults() throws {
        try withFixture { schedule, clock, transport in
            let store = TaskStore.preview()
            store.setPreviewUpdate()
            let existing = try XCTUnwrap(store.availableUpdate)
            let coordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: transport.make,
                                                        executeStorage: { $0() }, executeParser: { $0() },
                                                        currentVersion: "0.3.7-alpha") { update in
                store.acceptReleaseUpdate(update)
            }
            coordinator.check()
            drainMainQueue()
            transport.requests[0].emit(.success(Data("[]".utf8)))
            drainMainQueue()
            XCTAssertEqual(store.availableUpdate, existing)
            XCTAssertEqual(schedule.delay, 86_400)
            clock.advance(86_400)
            coordinator.check()
            drainMainQueue()
            transport.requests[1].emit(.success(Data("[{}]".utf8)))
            drainMainQueue()
            XCTAssertEqual(store.availableUpdate, existing)
            XCTAssertEqual(schedule.delay, 3_600)
        }
    }
}
