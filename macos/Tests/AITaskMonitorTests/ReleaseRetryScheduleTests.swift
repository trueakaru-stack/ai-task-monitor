import XCTest
@testable import AITaskMonitor

private final class SyntheticReleaseClock {
    var wall = Date(timeIntervalSince1970: 1_000)
    var monotonic: TimeInterval = 0

    var clock: ReleaseRetryClock {
        ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic })
    }

    var sharedClock: ReleaseRetryClock {
        ReleaseRetryClock(wall: { self.wall }, monotonic: { self.monotonic },
                          sharedMonotonic: { UInt64(self.monotonic * 1_000_000_000) })
    }

    func advance(_ seconds: TimeInterval) {
        wall = wall.addingTimeInterval(seconds)
        monotonic += seconds
    }
}

final class ReleaseRetryScheduleTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "AITaskMonitor.ReleaseRetryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    func testFailureRetriesAfterOneHourAndSuccessAfterOneDay() throws {
        try withDefaults { defaults in
            let time = SyntheticReleaseClock()
            let schedule = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertTrue(schedule.beginIfDue())
            XCTAssertFalse(schedule.beginIfDue())
            schedule.failed()
            time.advance(3_599)
            XCTAssertFalse(schedule.isDue)
            time.advance(1)
            XCTAssertTrue(schedule.beginIfDue())
            schedule.succeeded()
            time.advance(86_399)
            XCTAssertFalse(schedule.isDue)
            time.advance(1)
            XCTAssertTrue(schedule.isDue)
            XCTAssertEqual(schedule.rateFailures, 0)
        }
    }

    func testRateLimitBackoffAndLongServerDelay() throws {
        try withDefaults { defaults in
            let time = SyntheticReleaseClock()
            let schedule = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            for expected in [TimeInterval(3_600), 7_200, 14_400, 28_800, 57_600, 86_400, 86_400] {
                XCTAssertTrue(schedule.beginIfDue())
                schedule.failed(ReleaseHTTPResponse(status: 403))
                XCTAssertEqual(schedule.delay, expected)
                time.advance(expected)
            }
            XCTAssertTrue(schedule.beginIfDue())
            schedule.failed(ReleaseHTTPResponse(status: 429, retryAfter: "2592000"))
            XCTAssertGreaterThanOrEqual(schedule.delay, 2_592_000)
            XCTAssertEqual(schedule.rateFailures, 6)
        }
    }

    func testRestartAndWallClockJumpsAreBounded() throws {
        try withDefaults { defaults in
            let time = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertTrue(first.beginIfDue())
            first.failed()
            time.advance(600)
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertFalse(restored.beginIfDue())
            XCTAssertGreaterThanOrEqual(restored.delay, 3_000)
            XCTAssertLessThan(restored.delay, 3_000.001)
            time.wall = Date(timeIntervalSince1970: -1_000_000)
            time.monotonic += 2_999
            XCTAssertFalse(restored.isDue)
            time.monotonic += 2
            XCTAssertTrue(restored.isDue)

            let backwards = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertFalse(backwards.beginIfDue())
            XCTAssertLessThanOrEqual(backwards.delay, 3_600)
            XCTAssertGreaterThan(backwards.delay, 0)
            time.wall = time.wall.addingTimeInterval(300)
            let rebased = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertFalse(rebased.beginIfDue())
            XCTAssertLessThan(rebased.delay, backwards.delay)
        }
    }

    func testLegacyCheckpointWithoutSharedClockCanFollowForwardWallJump() throws {
        try withDefaults { defaults in
            let time = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertTrue(first.beginIfDue())
            time.wall = time.wall.addingTimeInterval(100_000)
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: time.clock)
            XCTAssertTrue(restored.beginIfDue())
        }
    }

    func testCorruptCheckpointUsesFiniteConservativeDelay() throws {
        try withDefaults { defaults in
            defaults.set("not scheduling data", forKey: ReleaseRetrySchedule.defaultsKey)
            let schedule = ReleaseRetrySchedule(defaults: defaults, clock: SyntheticReleaseClock().clock)
            XCTAssertFalse(schedule.beginIfDue())
            XCTAssertEqual(schedule.delay, 86_400)
            XCTAssertFalse(schedule.isDue)
        }
    }

    func testHttpHintsAndConservativeFallback() {
        let now = Date(timeIntervalSince1970: 500_000)
        let serverDate = "Thu, 01 Jan 1970 00:00:00 GMT"
        let hints = ReleaseHTTPResponse(status: 403, retryAfter: "3600", remaining: "0", reset: "7200", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: hints, now: now), 7_200)
        let httpDate = ReleaseHTTPResponse(status: 429, retryAfter: "Thu, 01 Jan 1970 02:00:00 GMT", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: httpDate, now: now), 7_200)
        let obsolete = ReleaseHTTPResponse(status: 503, retryAfter: "Thursday, 01-Jan-70 02:00:00 GMT", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: obsolete, now: now), 7_200)
        let asctime = ReleaseHTTPResponse(status: 503, retryAfter: "Thu Jan  1 02:00:00 1970", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: asctime, now: now), 7_200)
        let ignoredReset = ReleaseHTTPResponse(status: 403, remaining: "1", reset: "7200", serverDate: serverDate)
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: ignoredReset, now: now), 0)
        let paddedZero = ReleaseHTTPResponse(status: 403, remaining: "000", reset: "7200", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: paddedZero, now: now), 7_200)
        let invalidRemaining = ReleaseHTTPResponse(status: 403, remaining: "", reset: "2592000", serverDate: serverDate)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: invalidRemaining, now: now), 2_592_000)
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: ReleaseHTTPResponse(status: 503, retryAfter: "broken"), now: now), 86_400)
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: ReleaseHTTPResponse(status: 429, oversizedHeader: true), now: now), 86_400)
        let mixed = ReleaseHTTPResponse(status: 429, retryAfter: "2592000", oversizedHeader: true)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: mixed, now: now), 2_592_000)
        let enormous = ReleaseHTTPResponse(status: 429, retryAfter: "1" + String(repeating: "0", count: 128))
        XCTAssertGreaterThan(ReleaseRetryHeaders.minimumDelay(for: enormous, now: now), 1e127)
        let overflow = ReleaseHTTPResponse(status: 429, retryAfter: String(repeating: "9", count: 309))
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: overflow, now: now), 86_400)
    }

    func testAbsoluteHintsWithMissingOrInvalidServerDateWaitAtLeastOneDay() {
        let now = Date(timeIntervalSince1970: 500_000)
        let badDate = ReleaseHTTPResponse(status: 429, retryAfter: "Thu, 01 Jan 1970 02:00:00 GMT", serverDate: "invalid")
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: badDate, now: now), 86_400)
        let noDate = ReleaseHTTPResponse(status: 429, remaining: "0", reset: "7200")
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: noDate, now: now), 86_400)
        let relative = ReleaseHTTPResponse(status: 429, retryAfter: "7200")
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: relative, now: now), 7_200)
        XCTAssertLessThan(ReleaseRetryHeaders.minimumDelay(for: relative, now: now), 7_201)
    }

    func testSharedLeasePreservesRateLimitAcrossIndependentSchedules() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-synthetic-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                             fileStore: ReleaseScheduleFileStore(directory: dir))
            let second = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                              fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertTrue(first.beginIfDue())
            XCTAssertFalse(second.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, retryAfter: "7200"))
            clock.wall = clock.wall.addingTimeInterval(100_000)
            XCTAssertFalse(second.beginIfDue())
            clock.advance(3_600)
            XCTAssertFalse(second.beginIfDue())
            clock.advance(3_601)
            XCTAssertTrue(second.beginIfDue())
            second.abandon()
        }
    }

    func testSharedClockResetAfterRebootExtendsRatherThanShortensWait() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-reboot-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = SyntheticReleaseClock()
            clock.monotonic = 10_000
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                             fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertTrue(first.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, retryAfter: "7200"))
            clock.wall = clock.wall.addingTimeInterval(100_000)
            clock.monotonic = 5
            let restarted = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                                 fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertFalse(restarted.beginIfDue())
            clock.advance(3_600)
            XCTAssertFalse(restarted.beginIfDue())
            clock.advance(3_601)
            XCTAssertTrue(restarted.beginIfDue())
            restarted.abandon()
        }
    }

    func testBusyLeaseIsRetriedImmediatelyAfterItIsReleased() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("release-busy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let fileStore = ReleaseScheduleFileStore(directory: dir)
            var held: ReleaseScheduleFileStore.Lease? = try XCTUnwrap(fileStore.acquire())
            let clock = SyntheticReleaseClock()
            let schedule = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock, fileStore: fileStore)
            XCTAssertFalse(schedule.beginIfDue())
            XCTAssertNotNil(held)
            held = nil
            XCTAssertTrue(schedule.beginIfDue(), "Contention must not incur the storage-error delay.")
            schedule.abandon()
        }
    }
}
