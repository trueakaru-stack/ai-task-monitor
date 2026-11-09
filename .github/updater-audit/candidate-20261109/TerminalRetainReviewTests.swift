import Foundation
import XCTest
@testable import AITaskMonitor

private final class ReviewClock {
    var elapsed: TimeInterval = 0
    var value: ReleaseRetryClock {
        ReleaseRetryClock(wall: { Date(timeIntervalSince1970: 1_000_000 + self.elapsed) },
                          monotonic: { self.elapsed },
                          sharedMonotonic: { UInt64(self.elapsed * 1_000_000_000) })
    }
}

private final class ReviewManualRequest: ReleaseRequesting {
    let completion: (ReleaseRequestOutcome) -> Void
    private var collector: ReleaseResponseCollector?
    private(set) var cancelled = false
    init(_ completion: @escaping (ReleaseRequestOutcome) -> Void) { self.completion = completion }
    func attachResponseCollector(_ collector: ReleaseResponseCollector) { self.collector = collector }
    func start() throws {}
    func cancel() { cancelled = true } // Intentionally withhold terminal callback.
    func hint(_ response: ReleaseHTTPResponse) {
        if collector?.beginCapture() == true { collector?.finishCapture(response) }
    }
    func finish() { completion(.cancelled) }
}

@MainActor
final class TerminalRetainReviewTests: XCTestCase {
    private func drain() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    func testDeinitRetainsThenReleasesRequestAndScheduleWithoutExternalOwners() throws {
        let suite = "AITaskMonitor.synthetic-independent-retain." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-independent-lease-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ReviewClock()
        var schedule: ReleaseRetrySchedule? = ReleaseRetrySchedule(defaults: defaults, clock: clock.value,
                                                                    fileStore: ReleaseScheduleFileStore(directory: dir))
        weak var weakSchedule = schedule
        weak var weakRequest: ReviewManualRequest?
        let factory: ReleaseRequestFactory = { completion in
            let request = ReviewManualRequest(completion)
            weakRequest = request
            return request
        }
        var deliveries = 0
        var coordinator: ReleaseUpdateCoordinator? = ReleaseUpdateCoordinator(schedule: try XCTUnwrap(schedule),
            makeRequest: factory, scheduleDeadline: { _ in return {} }, executeStorage: { $0() },
            executeParser: { $0() }) { _ in deliveries += 1 }
        coordinator?.check(); drain()
        XCTAssertNotNil(weakRequest)
        weak var weakCoordinator = coordinator
        coordinator = nil
        schedule = nil
        drain()
        XCTAssertNil(weakCoordinator)
        XCTAssertNotNil(weakRequest, "Only the terminal gate should retain the request now.")
        XCTAssertTrue(weakRequest?.cancelled == true)
        XCTAssertNotNil(weakSchedule, "Only the retained finalizer should hold the schedule and lease.")
        clock.elapsed += 3_601
        let observer = ReleaseRetrySchedule(defaults: defaults, clock: clock.value,
                                             fileStore: ReleaseScheduleFileStore(directory: dir))
        XCTAssertFalse(observer.beginIfDue())
        weakRequest?.hint(ReleaseHTTPResponse(status: 200, retryAfter: "172800"))
        weakRequest?.finish(); drain()
        XCTAssertEqual(deliveries, 0)
        XCTAssertNil(weakRequest, "Terminal must break the retention cycle.")
        XCTAssertNil(weakSchedule, "Terminal and completed storage must release the original schedule.")
        XCTAssertFalse(observer.beginIfDue(), "Late retry hint must remain effective after lease release.")
        clock.elapsed += 172_801
        XCTAssertTrue(observer.beginIfDue())
        observer.abandon()
    }
}
