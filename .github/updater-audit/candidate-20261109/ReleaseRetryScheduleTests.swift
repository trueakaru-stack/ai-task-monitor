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
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: overflow, now: now), .infinity)
    }

    func testPaddedAndUnrepresentableNumericHintsThroughHTTPResponse() throws {
        let now = Date(timeIntervalSince1970: 0)
        let serverDate = "Thu, 01 Jan 1970 00:00:00 GMT"
        func response(_ fields: [String: String], status: Int = 429) throws -> ReleaseHTTPResponse {
            let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
            return ReleaseHTTPResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                                                                      httpVersion: "HTTP/1.1", headerFields: fields)))
        }

        for padding in [0, 120, 251, 500] {
            let padded = String(repeating: "0", count: padding) + "172800"
            let relative = try response(["Retry-After": padded])
            let relativeDelay = ReleaseRetryHeaders.minimumDelay(for: relative, now: now)
            XCTAssertGreaterThanOrEqual(relativeDelay, 172_800)
            XCTAssertLessThan(relativeDelay, 172_801)
            let absolute = try response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": padded,
                                         "Date": serverDate])
            let absoluteDelay = ReleaseRetryHeaders.minimumDelay(for: absolute, now: now)
            XCTAssertGreaterThanOrEqual(absoluteDelay, 172_800)
            XCTAssertLessThan(absoluteDelay, 172_801)
        }

        for numeric in [String(repeating: "9", count: 309), String(repeating: "0", count: 500) + String(repeating: "9", count: 400)] {
            let retry = try response(["Retry-After": numeric])
            XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: retry, now: now), .infinity)
            let reset = try response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": numeric, "Date": serverDate])
            XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: reset, now: now), .infinity)
            let noLimit = try response(["X-RateLimit-Remaining": "1", "X-RateLimit-Reset": numeric, "Date": serverDate])
            XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: noLimit, now: now), 0)
            let nonRate = try response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": numeric, "Date": serverDate], status: 503)
            XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: nonRate, now: now), 0)
        }

        for invalid in ["-1", "1.5", "broken", String(repeating: "9", count: 400) + "x"] {
            let malformed = try response(["Retry-After": invalid])
            XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: malformed, now: now), 86_400)
        }
        let zeros = try response(["Retry-After": String(repeating: "0", count: 500)])
        XCTAssertLessThan(ReleaseRetryHeaders.minimumDelay(for: zeros, now: now), 1)
        let direct = ReleaseHTTPResponse(status: 429, retryAfter: String(repeating: "0", count: 500) + "172800")
        XCTAssertLessThan(ReleaseRetryHeaders.minimumDelay(for: direct, now: now), 172_801)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: direct, now: now), 172_800)
    }

    func testCombinedHintsPreserveLongerValueAndHttpDateCommas() throws {
        let now = Date(timeIntervalSince1970: 0)
        let serverDate = "Thu, 01 Jan 1970 00:00:00 GMT"
        func response(_ fields: [String: String]) throws -> ReleaseHTTPResponse {
            let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
            return ReleaseHTTPResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429,
                                                                      httpVersion: "HTTP/1.1", headerFields: fields)))
        }
        let hints = [
            "3600, 172800",
            "Sat, 03 Jan 1970 00:00:00 GMT, 3600",
            "3600, Sat, 03 Jan 1970 00:00:00 GMT",
            "Thursday, 01-Jan-70 02:00:00 GMT, 172800",
            "Thu Jan  1 02:00:00 1970, 172800",
            "Mon, 172800",
            "Mon, invalid, 172800",
            "broken, 172800",
            String(repeating: "0", count: 251) + "172800, 3600"
        ]
        for hint in hints {
            let result = try response(["Retry-After": hint, "Date": serverDate])
            let delay = ReleaseRetryHeaders.minimumDelay(for: result, now: now)
            XCTAssertGreaterThanOrEqual(delay, 172_800, "\(hint)")
            XCTAssertLessThan(delay, 172_801, "\(hint)")
        }
        let splitReset = try response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "3600, 172800", "Date": serverDate])
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: splitReset, now: now), 172_800)
        let enormous = String(repeating: "9", count: 400)
        let retryOverflow = try response(["Retry-After": "3600, " + enormous, "Date": serverDate])
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: retryOverflow, now: now), .infinity)
        let resetOverflow = try response(["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "3600, " + enormous, "Date": serverDate])
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: resetOverflow, now: now), .infinity)
        let invalid = try response(["Retry-After": "-1, +1, 1.5, invalid", "Date": serverDate])
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: invalid, now: now), 86_400)
        let tooMany = try response(["Retry-After": Array(repeating: "invalid", count: 513).joined(separator: ", ")])
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: tooMany, now: now), .infinity)
        let uninspectable = try response(["Retry-After": String(repeating: "x", count: ReleaseRetryHeaders.maximumHeaderBytes + 1)])
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: uninspectable, now: now), .infinity)
    }

    func testHugePositiveRemainingDoesNotApplyOverflowReset() throws {
        let now = Date(timeIntervalSince1970: 0)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
        func response(remaining: String) throws -> ReleaseHTTPResponse {
            let fields = ["X-RateLimit-Remaining": remaining,
                          "X-RateLimit-Reset": String(repeating: "9", count: 400),
                          "Date": "Thu, 01 Jan 1970 00:00:00 GMT"]
            return ReleaseHTTPResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429,
                                                                      httpVersion: "HTTP/1.1", headerFields: fields)))
        }
        let positive = try response(remaining: String(repeating: "9", count: 400))
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: positive, now: now), 0)
        let paddedPositive = try response(remaining: String(repeating: "0", count: 500) + "1")
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: paddedPositive, now: now), 0)
        let combinedPositive = try response(remaining: String(repeating: "9", count: 400) + ", 1")
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: combinedPositive, now: now), 0)
        let combinedWithZero = try response(remaining: "1, 0")
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: combinedWithZero, now: now), .infinity)
        let zero = try response(remaining: String(repeating: "0", count: 500))
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: zero, now: now), .infinity)
    }

    func testHttp200ZeroRemainingHonorsResetAndPositiveRemainingDoesNot() throws {
        let now = Date(timeIntervalSince1970: 0)
        let date = "Thu, 01 Jan 1970 00:00:00 GMT"
        let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
        func response(_ remaining: String?, _ reset: String) throws -> ReleaseHTTPResponse {
            var fields = ["X-RateLimit-Reset": reset, "Date": date]
            if let remaining { fields["X-RateLimit-Remaining"] = remaining }
            return ReleaseHTTPResponse(try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                                      httpVersion: "HTTP/1.1", headerFields: fields)))
        }
        for remaining in ["0", "000", "1, 0"] {
            let hint = try response(remaining, "172800")
            let wait = ReleaseRetryHeaders.minimumDelay(for: hint, now: now)
            XCTAssertGreaterThanOrEqual(wait, 172_800)
            XCTAssertLessThan(wait, 172_801)
        }
        let absent = try response(nil, "172800")
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: absent, now: now), 172_800)
        let positive = try response("1", String(repeating: "9", count: 400))
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: positive, now: now), 0)
        let hugePositive = try response(String(repeating: "9", count: 400), String(repeating: "9", count: 400))
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: hugePositive, now: now), 0)
        let invalid = try response("bad", "172800")
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: invalid, now: now), 172_800)
    }

    func testOversizedHeadersFailClosedBeforeTrimming() throws {
        let now = Date(timeIntervalSince1970: 0)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/"))
        let limit = ReleaseRetryHeaders.maximumHeaderBytes
        let within = String(repeating: "0", count: limit - 6) + "172800"
        let larger = "0" + within
        let boundedResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                           httpVersion: "HTTP/1.1", headerFields: ["Retry-After": within]))
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: ReleaseHTTPResponse(boundedResponse), now: now), 172_800)
        XCTAssertLessThan(ReleaseRetryHeaders.minimumDelay(for: ReleaseHTTPResponse(boundedResponse), now: now), 172_801)
        let largeResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                         httpVersion: "HTTP/1.1", headerFields: ["Retry-After": larger]))
        let hint = ReleaseHTTPResponse(largeResponse)
        XCTAssertTrue(hint.retryAfterRequiresBlock)
        XCTAssertNil(hint.retryAfter)
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: hint, now: now), .infinity)
        let direct = ReleaseHTTPResponse(status: 200, retryAfter: larger)
        XCTAssertEqual(ReleaseRetryHeaders.minimumDelay(for: direct, now: now), .infinity)
        let remainingResponse = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                                               headerFields: ["X-RateLimit-Remaining": larger, "X-RateLimit-Reset": "172800",
                                                                              "Date": "Thu, 01 Jan 1970 00:00:00 GMT"]))
        let remainingHint = ReleaseHTTPResponse(remainingResponse)
        XCTAssertTrue(remainingHint.oversizedHeader)
        XCTAssertNil(remainingHint.remaining)
        XCTAssertGreaterThanOrEqual(ReleaseRetryHeaders.minimumDelay(for: remainingHint, now: now), 172_800)
    }

    func testSharedWriteFailureAttemptsIndependentCopyForInfiniteAndFiniteDelays() throws {
        enum SyntheticWriteError: Error { case failure }
        for hint in ["172800", String(repeating: "9", count: 309)] {
            try withDefaults { defaults in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-failed-write-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: dir) }
                let clock = SyntheticReleaseClock()
                var shouldFail = false
                var first: ReleaseRetrySchedule? = ReleaseRetrySchedule(
                    defaults: defaults, clock: clock.sharedClock, fileStore: ReleaseScheduleFileStore(directory: dir),
                    writeShared: { lease, data in
                        if shouldFail { throw SyntheticWriteError.failure }
                        try lease.write(data)
                    })
                XCTAssertTrue(try XCTUnwrap(first).beginIfDue())
                shouldFail = true
                first?.failed(ReleaseHTTPResponse(status: 429, retryAfter: hint))
                let saved = try JSONDecoder().decode(ReleaseRetryCheckpoint.self,
                                                      from: XCTUnwrap(defaults.data(forKey: ReleaseRetrySchedule.defaultsKey)))
                if hint == "172800" { XCTAssertGreaterThanOrEqual(saved.delay, 172_800) }
                else { XCTAssertEqual(saved.blockAutomaticRetry, true) }
                XCTAssertFalse(try XCTUnwrap(first).beginIfDue())
                first = nil // Release the synthetic file lease before a new instance.
                clock.advance(86_400)
                let restored = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                                    fileStore: ReleaseScheduleFileStore(directory: dir))
                XCTAssertFalse(restored.beginIfDue())
                if hint == "172800" {
                    clock.advance(86_401)
                    XCTAssertTrue(restored.beginIfDue())
                    restored.abandon()
                } else {
                    XCTAssertTrue(restored.blockedByUnrepresentableHint)
                }
            }
        }
    }

    func testBusyInstanceReloadsDefaultsAfterSharedWriteFailure() throws {
        enum SyntheticWriteError: Error { case failure }
        for hint in ["172800", String(repeating: "9", count: 309)] {
            try withDefaults { defaults in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-busy-failure-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: dir) }
                let clock = SyntheticReleaseClock()
                var shouldFail = false
                var first: ReleaseRetrySchedule? = ReleaseRetrySchedule(
                    defaults: defaults, clock: clock.sharedClock, fileStore: ReleaseScheduleFileStore(directory: dir),
                    writeShared: { lease, data in
                        if shouldFail { throw SyntheticWriteError.failure }
                        try lease.write(data)
                    })
                let second = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                                  fileStore: ReleaseScheduleFileStore(directory: dir))
                XCTAssertTrue(try XCTUnwrap(first).beginIfDue())
                XCTAssertFalse(second.beginIfDue(), "The first instance still holds the file lease.")
                shouldFail = true
                first?.failed(ReleaseHTTPResponse(status: 429, retryAfter: hint))
                XCTAssertFalse(second.beginIfDue(), "A stale defaults snapshot must not be published while the lease is busy.")
                let saved = try JSONDecoder().decode(ReleaseRetryCheckpoint.self,
                                                      from: XCTUnwrap(defaults.data(forKey: ReleaseRetrySchedule.defaultsKey)))
                if hint == "172800" { XCTAssertGreaterThanOrEqual(saved.delay, 172_800) }
                else { XCTAssertEqual(saved.blockAutomaticRetry, true) }
                first = nil
                clock.advance(86_400)
                XCTAssertFalse(second.beginIfDue())
                if hint == "172800" {
                    clock.advance(86_401)
                    XCTAssertTrue(second.beginIfDue())
                    second.abandon()
                } else {
                    XCTAssertTrue(second.blockedByUnrepresentableHint)
                }
            }
        }
    }

    func testUnrepresentableHintBlocksAcrossRestartsAndSharedCheckpoint() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-unrepresentable-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                             fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertTrue(first.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, retryAfter: String(repeating: "9", count: 309)))
            XCTAssertTrue(first.blockedByUnrepresentableHint)
            XCTAssertFalse(first.isDue)

            let data = try XCTUnwrap(defaults.data(forKey: ReleaseRetrySchedule.defaultsKey))
            let saved = try JSONDecoder().decode(ReleaseRetryCheckpoint.self, from: data)
            XCTAssertEqual(saved.blockAutomaticRetry, true)
            XCTAssertEqual(saved.delay, TimeInterval.greatestFiniteMagnitude)
            let lease = try XCTUnwrap(ReleaseScheduleFileStore(directory: dir).acquire())
            let fileData = try XCTUnwrap(lease.read())
            XCTAssertEqual(try JSONDecoder().decode(ReleaseRetryCheckpoint.self, from: fileData).blockAutomaticRetry, true)
        }
    }

    func testUnrepresentableHintSurvivesDefaultsOnlyRestart() throws {
        try withDefaults { defaults in
            let clock = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.clock)
            XCTAssertTrue(first.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, retryAfter: String(repeating: "9", count: 309)))
            clock.advance(86_400 * 1_000)
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: clock.clock)
            XCTAssertFalse(restored.beginIfDue())
            XCTAssertTrue(restored.blockedByUnrepresentableHint)
            XCTAssertFalse(restored.isDue)
        }
    }

    func testOlderSharedCheckpointCannotClearKnownBlock() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-stale-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = SyntheticReleaseClock()
            let store = ReleaseScheduleFileStore(directory: dir)
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock, fileStore: store)
            XCTAssertTrue(first.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, retryAfter: String(repeating: "9", count: 309)))
            do {
                let lease = try XCTUnwrap(store.acquire())
                let old = ReleaseRetryCheckpoint(wallStarted: 1_000, delay: 3_600, rateFailures: 1)
                try lease.write(JSONEncoder().encode(old))
            }
            clock.advance(86_400 * 1_000)
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock, fileStore: store)
            XCTAssertFalse(restored.beginIfDue())
            XCTAssertTrue(restored.blockedByUnrepresentableHint)
        }
    }

    func testBlockSurvivesFreshInstancesAndClockChanges() throws {
        try withDefaults { defaults in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("retry-restart-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let clock = SyntheticReleaseClock()
            let first = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                             fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertTrue(first.beginIfDue())
            first.failed(ReleaseHTTPResponse(status: 429, remaining: "0", reset: String(repeating: "9", count: 309)))
            defaults.removeObject(forKey: ReleaseRetrySchedule.defaultsKey)
            clock.advance(86_400 * 1_000)
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                                fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertFalse(restored.beginIfDue())
            XCTAssertTrue(restored.blockedByUnrepresentableHint)
            restored.succeeded()
            XCTAssertFalse(restored.isDue)
            clock.wall = Date(timeIntervalSince1970: 10_000_000_000)
            clock.monotonic = 1
            let afterReboot = ReleaseRetrySchedule(defaults: defaults, clock: clock.sharedClock,
                                                   fileStore: ReleaseScheduleFileStore(directory: dir))
            XCTAssertFalse(afterReboot.beginIfDue())
            XCTAssertTrue(afterReboot.blockedByUnrepresentableHint)
        }
    }

    func testLegacyCheckpointWithoutBlockKeepsNormalRetry() throws {
        try withDefaults { defaults in
            let legacy = Data("{\"wallStarted\":1000,\"delay\":7200,\"rateFailures\":1}".utf8)
            defaults.set(legacy, forKey: ReleaseRetrySchedule.defaultsKey)
            let clock = SyntheticReleaseClock()
            let restored = ReleaseRetrySchedule(defaults: defaults, clock: clock.clock)
            XCTAssertFalse(restored.beginIfDue())
            XCTAssertFalse(restored.blockedByUnrepresentableHint)
            clock.advance(7_201)
            XCTAssertTrue(restored.beginIfDue())
        }
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
