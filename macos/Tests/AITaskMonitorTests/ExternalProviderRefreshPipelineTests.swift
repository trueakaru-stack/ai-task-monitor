import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderRefreshPipelineTests: XCTestCase {
    private static let providers: Set<TaskProvider> = [.opencode, .deepseek]

    private static func task(_ id: String, _ provider: TaskProvider, turn: String = "turn-1") -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: id, activity: "Synthetic work", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: turn)
    }

    private static func batch(_ tasks: [MonitoredTask], terminals: [TaskProvider: Set<String>] = [:],
                              gaps: Set<TaskProvider> = []) -> ExternalProviderPipelineBatch {
        ExternalProviderPipelineBatch(capture: ExternalProviderRefreshCapture(tasks: tasks, terminalIDs: terminals,
                                                                               gapProviders: gaps),
                                      providers: providers)
    }

    private final class Clock {
        private let lock = NSLock()
        private var value: TimeInterval = 100
        func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ next: TimeInterval) { lock.lock(); value = next; lock.unlock() }
    }

    private final class Source {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var calls = 0
        func read(_ request: Int) -> ExternalProviderPipelineBatch {
            lock.lock(); calls += 1; lock.unlock()
            if request == 2 {
                entered.signal()
                _ = release.wait(timeout: .now() + 10)
                return ExternalProviderRefreshPipelineTests.batch(
                    [ExternalProviderRefreshPipelineTests.task("new", .opencode)],
                    terminals: [.opencode: ["one"]])
            }
            if request == 1 {
                return ExternalProviderRefreshPipelineTests.batch([
                    ExternalProviderRefreshPipelineTests.task("one", .opencode),
                    ExternalProviderRefreshPipelineTests.task("two", .deepseek)])
            }
            return ExternalProviderRefreshPipelineTests.batch([
                ExternalProviderRefreshPipelineTests.task("one", .opencode, turn: "turn-2"),
                ExternalProviderRefreshPipelineTests.task("new", .opencode),
                ExternalProviderRefreshPipelineTests.task("next", .opencode),
                ExternalProviderRefreshPipelineTests.task("two", .deepseek)])
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    }

    @MainActor
    private func wait(_ condition: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        var satisfied = condition()
        while !satisfied && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            satisfied = condition()
        }
        XCTAssertTrue(satisfied, "The synthetic refresh did not complete")
    }

    @MainActor
    func testTimerKeepsLastSnapshotThenPreservesLateEventsAsUnconfirmed() throws {
        let clock = Clock(), source = Source()
        defer { source.release.signal() }
        var changes = 0
        let pipeline = ExternalProviderRefreshPipeline<Int>(monotonicNow: { clock.now() },
            read: { source.read($0) }, onChange: { _ in changes += 1 })
        defer { pipeline.close() }
        pipeline.poll(1, providers: Self.providers)
        wait { !pipeline.isInFlight && changes > 0 }
        XCTAssertEqual(pipeline.cache.tasks.count, 2)
        XCTAssertTrue(pipeline.cache.tasks.allSatisfy { $0.isActive && !$0.isUnconfirmed })

        pipeline.poll(2, providers: Self.providers)
        XCTAssertEqual(source.entered.wait(timeout: .now() + 3), .success)
        clock.set(101.999)
        pipeline.poll(3, providers: Self.providers)
        XCTAssertTrue(pipeline.cache.uncertainProviders.isEmpty)
        XCTAssertEqual(source.count, 2, "A timer tick must not start a parallel source operation")
        clock.set(102)
        pipeline.poll(3, providers: Self.providers)
        XCTAssertEqual(pipeline.cache.uncertainProviders, Self.providers)
        XCTAssertTrue(pipeline.cache.tasks.allSatisfy(\.isUnconfirmed))
        source.release.signal()
        wait { source.count == 3 && !pipeline.isInFlight }
        XCTAssertEqual(pipeline.cache.pendingTerminalIDs[.opencode], ["one"])
        let old = try XCTUnwrap(pipeline.cache.tasks.first { $0.id == "one" })
        XCTAssertTrue(old.isUnconfirmed)
        XCTAssertEqual(old.startKey, "turn-1")
        XCTAssertTrue(try XCTUnwrap(pipeline.cache.tasks.first { $0.id == "new" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(pipeline.cache.tasks.first { $0.id == "two" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(pipeline.cache.tasks.first { $0.id == "next" }).isActive)
    }

    @MainActor
    func testReconnectWaitsForOldOwnerAndReconcilesItsHandoff() throws {
        let source = Source(), finished = DispatchSemaphore(value: 0)
        let lease = ExternalProviderRefreshLease<ExternalProviderPipelineBatch>()
        defer { source.release.signal() }
        var firstChanges = 0
        let first = ExternalProviderRefreshPipeline<Int>(lease: lease, read: { source.read($0) }, finish: {
            finished.signal()
            return Self.batch([Self.task("drained", .deepseek)], gaps: [.deepseek])
        }, onChange: { _ in firstChanges += 1 })
        first.poll(1, providers: Self.providers)
        wait { !first.isInFlight && firstChanges > 0 }
        first.poll(2, providers: Self.providers)
        XCTAssertEqual(source.entered.wait(timeout: .now() + 3), .success)
        let previous = first.cache
        first.close()
        var secondChanges = 0
        let second = ExternalProviderRefreshPipeline<Int>(lease: lease, initialCache: previous,
            read: { source.read($0) }, onChange: { _ in secondChanges += 1 })
        defer { second.close() }
        second.invalidate(3, providers: Self.providers)
        XCTAssertTrue(second.isWaitingForLease)
        XCTAssertEqual(source.count, 2)
        XCTAssertTrue(second.cache.tasks.allSatisfy(\.isUnconfirmed))

        source.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        wait {
            if second.isWaitingForLease { second.poll(3, providers: Self.providers) }
            return source.count == 3 && !second.isInFlight
        }
        XCTAssertGreaterThan(secondChanges, 0)
        XCTAssertEqual(second.cache.pendingTerminalIDs[.opencode], ["one"])
        XCTAssertTrue(try XCTUnwrap(second.cache.tasks.first { $0.id == "drained" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(second.cache.tasks.first { $0.id == "one" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(second.cache.tasks.first { $0.id == "next" }).isActive)
        XCTAssertEqual(source.count, 3, "The successor must not reread the predecessor's request")
    }

    @MainActor
    func testDeinitAfterCompletedReadReleasesLease() {
        let source = Source(), finished = DispatchSemaphore(value: 0)
        let lease = ExternalProviderRefreshLease<ExternalProviderPipelineBatch>()
        var changes = 0
        var first: ExternalProviderRefreshPipeline<Int>? = ExternalProviderRefreshPipeline<Int>(
            lease: lease, read: { source.read($0) }, finish: { finished.signal(); return nil },
            onChange: { _ in changes += 1 })
        first?.poll(1, providers: Self.providers)
        wait { first?.isInFlight == false && changes > 0 }
        weak var released = first
        first = nil
        XCTAssertNil(released)
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        let second = ExternalProviderRefreshPipeline<Int>(lease: lease, read: { source.read($0) }, onChange: { _ in })
        defer { second.close() }
        wait {
            if source.count < 2 { second.poll(3, providers: Self.providers) }
            return source.count == 2 && !second.isInFlight
        }
        XCTAssertFalse(second.isWaitingForLease)
    }

    @MainActor
    func testDeinitDuringBlockedReadKeepsLeaseAndTransfersEvidence() throws {
        let source = Source(), finished = DispatchSemaphore(value: 0)
        let lease = ExternalProviderRefreshLease<ExternalProviderPipelineBatch>()
        defer { source.release.signal() }
        var first: ExternalProviderRefreshPipeline<Int>? = ExternalProviderRefreshPipeline<Int>(
            lease: lease, read: { source.read($0) }, finish: {
                finished.signal()
                return Self.batch([Self.task("drained", .deepseek)], gaps: [.deepseek])
            }, onChange: { _ in })
        first?.poll(2, providers: Self.providers)
        XCTAssertEqual(source.entered.wait(timeout: .now() + 3), .success)
        weak var released = first
        first = nil
        XCTAssertNil(released)
        let second = ExternalProviderRefreshPipeline<Int>(lease: lease, read: { source.read($0) }, onChange: { _ in })
        defer { second.close() }
        second.poll(3, providers: Self.providers)
        XCTAssertTrue(second.isWaitingForLease)
        XCTAssertEqual(source.count, 1)
        source.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        wait {
            if second.isWaitingForLease { second.poll(3, providers: Self.providers) }
            return source.count == 2 && !second.isInFlight
        }
        XCTAssertEqual(second.cache.pendingTerminalIDs[.opencode], ["one"])
        XCTAssertTrue(try XCTUnwrap(second.cache.tasks.first { $0.id == "drained" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(second.cache.tasks.first { $0.id == "one" }).isUnconfirmed)
        XCTAssertEqual(source.count, 2)
    }
}
