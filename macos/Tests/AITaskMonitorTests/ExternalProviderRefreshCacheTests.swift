import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderRefreshCacheTests: XCTestCase {
    private func task(_ id: String, _ provider: TaskProvider, turn: String = "turn-1") -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: id, activity: "Synthetic work", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: turn)
    }

    private func capture(_ tasks: [MonitoredTask], terminalIDs: [TaskProvider: Set<String>] = [:],
                         gaps: Set<TaskProvider> = []) -> ExternalProviderRefreshCapture {
        ExternalProviderRefreshCapture(tasks: tasks, terminalIDs: terminalIDs, gapProviders: gaps)
    }

    func testDelayedSourceRetainsTasksAndBothLateEventTypesWithoutTaintingNeighbor() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("shared", .opencode), neighbor = task("shared", .deepseek)
        cache.apply(capture([first, neighbor]), quality: .current, providers: [.opencode, .deepseek])
        XCTAssertTrue(cache.tasks.allSatisfy { $0.isActive && !$0.isUnconfirmed })

        cache.markUncertain([.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        let new = task("new", .opencode)
        cache.apply(capture([new], terminalIDs: [.opencode: ["shared"]]),
                    quality: .delayed, providers: [.opencode])
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["shared"])
        XCTAssertNil(cache.pendingTerminalIDs[.deepseek])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode && $0.id == "shared" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode && $0.id == "new" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)

        let conflictingTurn = task("shared", .opencode, turn: "turn-2")
        let next = task("next", .opencode)
        cache.apply(capture([conflictingTurn, new, next]), quality: .current, providers: [.opencode])
        let retained = try XCTUnwrap(cache.tasks.first { $0.provider == .opencode && $0.id == "shared" })
        XCTAssertTrue(retained.isUnconfirmed)
        XCTAssertEqual(retained.startKey, "turn-1", "An ID alone must not bind a later turn to old terminal evidence")
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode && $0.id == "new" }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode && $0.id == "next" }).isActive)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
    }

    func testCurrentGapOnlyPoisonsAffectedProviderAndRetainsExistingTask() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode), neighbor = task("two", .deepseek)
        cache.apply(capture([first, neighbor]), quality: .current, providers: [.opencode, .deepseek])
        cache.apply(capture([neighbor], terminalIDs: [.opencode: ["one"], .deepseek: ["two"]],
                            gaps: [.opencode]), quality: .current, providers: [.opencode, .deepseek])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])
        XCTAssertNil(cache.pendingTerminalIDs[.deepseek])
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
    }

    func testInvalidationBeforeFirstReadCannotBecomeAConfirmedEmptySource() {
        var cache = ExternalProviderRefreshCache()
        cache.apply(nil, quality: .invalidated, providers: [.opencode])
        XCTAssertTrue(cache.tasks.isEmpty)
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
    }

    func testCurrentCleanSnapshotCanReplacePreviouslyConfirmedTasks() {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode), task("two", .deepseek)]),
                    quality: .current, providers: [.opencode, .deepseek])
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]]),
                    quality: .current, providers: [.opencode])
        XCTAssertFalse(cache.tasks.contains { $0.provider == .opencode })
        XCTAssertTrue(cache.tasks.contains { $0.provider == .deepseek && $0.isActive })
        XCTAssertTrue(cache.pendingTerminalIDs.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testDuplicateIdentityKeepsPriorCardUnconfirmed() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode)]), quality: .current, providers: [.opencode])
        cache.apply(capture([task("one", .opencode, turn: "second"), task("one", .opencode, turn: "third")]),
                    quality: .current, providers: [.opencode])
        let retained = try XCTUnwrap(cache.tasks.first)
        XCTAssertEqual(cache.tasks.count, 1)
        XCTAssertEqual(retained.startKey, "turn-1")
        XCTAssertTrue(retained.isUnconfirmed)
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
    }

    func testCapacityKeepsPreviouslyVisibleTasksBeforeNewOnes() {
        var cache = ExternalProviderRefreshCache(maximumTasks: 2, maximumTerminals: 1)
        let first = task("one", .opencode), second = task("two", .deepseek)
        cache.apply(capture([first, second]), quality: .current, providers: [.opencode, .deepseek])
        cache.apply(capture([task("zero", .opencode), first, second]),
                    quality: .current, providers: [.opencode, .deepseek])
        XCTAssertEqual(Set(cache.tasks.map(\.id)), ["one", "two"])
        XCTAssertTrue(cache.capacityExceeded)
        XCTAssertTrue(cache.uncertainProviders.contains(.opencode))
    }
}
