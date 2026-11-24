import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderRefreshOwnerTests: XCTestCase {
    private struct Capture: Equatable {
        let v1Events: [String]
        let v2Events: [String]
        let gap: Bool
    }

    private final class Gate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var invocations = 0
        func read(_ request: Int) -> Capture {
            lock.lock(); invocations += 1; lock.unlock()
            if request == 1 {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                return Capture(v1Events: ["v1-started"], v2Events: ["v2-finished"], gap: true)
            }
            return Capture(v1Events: ["v1-new"], v2Events: ["v2-new"], gap: false)
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return invocations }
    }

    private final class Clock {
        private let lock = NSLock()
        private var current: TimeInterval = 100
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return current }
        func set(_ next: TimeInterval) { lock.lock(); current = next; lock.unlock() }
    }

    @MainActor
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var satisfied = condition()
        while !satisfied && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            satisfied = condition()
        }
        XCTAssertTrue(satisfied, "The synthetic owner did not deliver its result")
    }

    @MainActor
    func testInvalidatedCaptureRetainsBothEventBatchesWithoutParallelRead() throws {
        let gate = Gate(), clock = Clock()
        defer { gate.release.signal() }
        let owner = ExternalProviderRefreshOwner<Int, Capture>(monotonicNow: { clock.now() }, read: { gate.read($0) })
        defer { owner.close() }
        var deliveries: [ExternalProviderRefreshDelivery<Capture>] = []
        XCTAssertTrue(owner.tryRead(1) { deliveries.append($0) })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        owner.invalidate()
        XCTAssertFalse(owner.tryRead(2) { _ in XCTFail("A second source owner must not run concurrently") })
        XCTAssertEqual(gate.count, 1)
        gate.release.signal()
        wait { deliveries.count == 1 }
        let invalidated = try XCTUnwrap(deliveries.first)
        XCTAssertEqual(invalidated.quality, .invalidated)
        XCTAssertEqual(invalidated.capture, Capture(v1Events: ["v1-started"], v2Events: ["v2-finished"], gap: true),
                       "The caller must receive all evidence even when this result cannot confirm state")

        XCTAssertTrue(owner.tryRead(2) { deliveries.append($0) })
        wait { deliveries.count == 2 }
        XCTAssertEqual(deliveries[1].quality, .current)
        XCTAssertEqual(deliveries[1].capture, Capture(v1Events: ["v1-new"], v2Events: ["v2-new"], gap: false))
        XCTAssertEqual(gate.count, 2)
    }

    @MainActor
    func testOnlyElapsedPollIntervalMarksBlockedCaptureDelayed() throws {
        let gate = Gate(), clock = Clock()
        defer { gate.release.signal() }
        let owner = ExternalProviderRefreshOwner<Int, Capture>(monotonicNow: { clock.now() }, read: { gate.read($0) })
        defer { owner.close() }
        var delivery: ExternalProviderRefreshDelivery<Capture>?
        XCTAssertTrue(owner.tryRead(1) { delivery = $0 })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        XCTAssertFalse(owner.isDelayed())
        clock.set(101.999)
        XCTAssertFalse(owner.isDelayed(), "Callbacks before the complete polling interval are not a timeout")
        clock.set(102)
        XCTAssertTrue(owner.isDelayed())
        gate.release.signal()
        wait { delivery != nil }
        let delayed = try XCTUnwrap(delivery)
        XCTAssertEqual(delayed.quality, .delayed)
        XCTAssertEqual(delayed.capture?.v1Events, ["v1-started"])
        XCTAssertEqual(delayed.capture?.v2Events, ["v2-finished"])
        XCTAssertTrue(delayed.capture?.gap == true)
        XCTAssertFalse(owner.isDelayed())
    }

    @MainActor
    func testCloseDoesNotWaitAndFinishesAfterBlockedReadWithoutPublishing() {
        let gate = Gate(), finished = DispatchSemaphore(value: 0)
        defer { gate.release.signal() }
        let owner = ExternalProviderRefreshOwner<Int, Capture>(read: { gate.read($0) }, finish: {
            finished.signal()
            return nil
        })
        var published = false
        XCTAssertTrue(owner.tryRead(1) { _ in published = true })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let started = ProcessInfo.processInfo.systemUptime
        owner.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        XCTAssertFalse(owner.tryRead(2) { _ in XCTFail("A closed owner cannot restart") })
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)
        gate.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(published)
    }

    @MainActor
    func testReconnectedOwnerWaitsAndReceivesPriorEvidenceBeforeReading() throws {
        let gate = Gate(), finished = DispatchSemaphore(value: 0)
        let lease = ExternalProviderRefreshLease<Capture>()
        defer { gate.release.signal() }
        let first = ExternalProviderRefreshOwner<Int, Capture>(lease: lease, read: { gate.read($0) }, finish: {
            finished.signal()
            return Capture(v1Events: ["v1-drained"], v2Events: ["v2-drained"], gap: false)
        })
        let second = ExternalProviderRefreshOwner<Int, Capture>(lease: lease, read: { gate.read($0) })
        defer { second.close() }
        var oldPublished = false
        XCTAssertTrue(first.tryRead(1) { _ in oldPublished = true })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        first.close()
        XCTAssertFalse(second.tryRead(2) { _ in XCTFail("The old owner still holds the endpoints") })
        XCTAssertNil(second.takeHandoff())
        XCTAssertEqual(gate.count, 1)

        gate.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        var handoff: [ExternalProviderRefreshDelivery<Capture>] = []
        wait {
            if let value = second.takeHandoff() { handoff.append(value) }
            return !handoff.isEmpty
        }
        let received = try XCTUnwrap(handoff.first)
        XCTAssertEqual(received.quality, .invalidated)
        XCTAssertEqual(received.capture,
                       Capture(v1Events: ["v1-started"], v2Events: ["v2-finished"], gap: true))
        XCTAssertFalse(second.tryRead(2) { _ in XCTFail("Shutdown evidence must be reconciled first") })
        let drained = try XCTUnwrap(second.takeHandoff())
        XCTAssertEqual(drained.quality, .invalidated)
        XCTAssertEqual(drained.capture,
                       Capture(v1Events: ["v1-drained"], v2Events: ["v2-drained"], gap: false))

        var next: ExternalProviderRefreshDelivery<Capture>?
        XCTAssertTrue(second.tryRead(2) { next = $0 })
        wait { next != nil }
        XCTAssertEqual(next?.quality, .current)
        XCTAssertEqual(next?.capture, Capture(v1Events: ["v1-new"], v2Events: ["v2-new"], gap: false))
        XCTAssertEqual(gate.count, 2, "Neither owner may consume the same request twice")
        XCTAssertFalse(oldPublished)
    }
}
