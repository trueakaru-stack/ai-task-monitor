import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderRefreshCacheTests: XCTestCase {
    private func task(_ id: String, _ provider: TaskProvider, turn: String = "turn-1") -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: id, activity: "Synthetic work", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: turn)
    }

    private func capture(_ tasks: [MonitoredTask], terminalIDs: [TaskProvider: Set<String>] = [:],
                         gaps: Set<TaskProvider> = [],
                         active: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:],
                         ended: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:],
                         successors: [TaskProvider: Set<ExternalProviderVerifiedSuccessor>] = [:],
                         afterTerminal: [TaskProvider: Set<ExternalProviderVerifiedTurn>] = [:],
                         complete: Set<TaskProvider> = [],
                         generations: [TaskProvider: UInt64] = [:],
                         reconciled: Set<TaskProvider> = []) -> ExternalProviderRefreshCapture {
        ExternalProviderRefreshCapture(tasks: tasks, terminalIDs: terminalIDs, gapProviders: gaps,
                                       verifiedActiveTurns: active, verifiedEndedTurns: ended,
                                       verifiedSuccessors: successors, verifiedPostTerminalActiveTurns: afterTerminal,
                                       completeProviders: complete, sourceGenerations: generations,
                                       reconciledProviders: reconciled)
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
        cache.apply(capture([neighbor], terminalIDs: [.opencode: ["one"]],
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

    func testMissingCaptureCannotConfirmAnEmptySourceEvenWhenMarkedCurrent() {
        var cache = ExternalProviderRefreshCache()
        cache.apply(nil, quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.tasks.isEmpty)
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
    }

    func testCurrentCleanSnapshotCanReplacePreviouslyConfirmedTasks() {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode), task("two", .deepseek)]),
                    quality: .current, providers: [.opencode, .deepseek])
        let ended = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]], ended: [.opencode: [ended]]),
                    quality: .current, providers: [.opencode])
        XCTAssertFalse(cache.tasks.contains { $0.provider == .opencode })
        XCTAssertTrue(cache.tasks.contains { $0.provider == .deepseek && $0.isActive })
        XCTAssertTrue(cache.pendingTerminalIDs.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testIncompleteCurrentSnapshotCannotRemovePreviouslyVisibleTask() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode)]), quality: .current, providers: [.opencode])
        cache.apply(capture([]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        XCTAssertEqual(cache.uncertainProviders, [.opencode])

        cache.apply(capture([], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.tasks.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testCompleteAbsenceCanRecoverUnconfirmedTaskWithoutStartKey() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode, turn: "")]), quality: .current, providers: [.opencode])
        cache.apply(capture([]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        cache.apply(capture([], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.tasks.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testCompleteAbsenceDoesNotEraseUnmatchedTerminalWithoutTurnProof() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode, turn: "")]), quality: .current, providers: [.opencode])
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]]), quality: .delayed, providers: [.opencode])
        cache.apply(capture([], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])
    }

    func testTerminalWithoutVisibleTaskCannotConfirmLaterActivityWithoutOrderProof() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]]),
                    quality: .current, providers: [.opencode])
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
        let next = task("one", .opencode, turn: "new-turn")
        cache.apply(capture([next], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)

        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "new-turn")
        cache.apply(capture([next], active: [.opencode: [proof]], afterTerminal: [.opencode: [proof]],
                            complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isActive)
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

    func testConflictingLiveAndTerminalEvidenceCannotRemoveOrConfirmTask() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode)
        cache.apply(capture([first]), quality: .current, providers: [.opencode])
        cache.apply(capture([first], terminalIDs: [.opencode: ["one"]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])
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
        cache.apply(capture([first], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertFalse(cache.capacityExceeded)
        XCTAssertFalse(cache.uncertainProviders.contains(.opencode))
        XCTAssertEqual(Set(cache.tasks.map(\.id)), ["one", "two"])
    }

    func testLostTerminalCapacityIsNotClearedByAnOrdinaryCompleteSnapshot() {
        var cache = ExternalProviderRefreshCache(maximumTasks: 2, maximumTerminals: 1)
        cache.apply(capture([task("one", .opencode)]), quality: .current, providers: [.opencode])
        cache.apply(capture([], terminalIDs: [.opencode: ["one", "two"]]),
                    quality: .delayed, providers: [.opencode])
        XCTAssertTrue(cache.capacityExceeded)
        cache.apply(capture([], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.capacityExceeded, "A roster cannot recover which terminal signal was dropped")
        XCTAssertTrue(cache.uncertainProviders.contains(.opencode))
        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([task("one", .opencode)], active: [.opencode: [proof]], complete: [.opencode],
                            reconciled: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.tasks.allSatisfy(\.isUnconfirmed), "Lost terminal evidence can affect any task in the source")
    }

    func testVerifiedSameTurnAfterDelayCanRestoreItsStatus() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode)
        cache.apply(capture([first]), quality: .current, providers: [.opencode])
        cache.markUncertain([.opencode])
        cache.apply(capture([first]), quality: .delayed, providers: [.opencode])

        cache.apply(capture([first], complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed,
                      "A quick snapshot and matching ID do not alone prove continuity")
        XCTAssertEqual(cache.uncertainProviders, [.opencode])

        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isActive)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testPendingTerminalCannotCloseOrConfirmADifferentTurnWithoutOrderedSuccessorProof() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode)
        cache.apply(capture([first]), quality: .current, providers: [.opencode])
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]]), quality: .delayed, providers: [.opencode])
        let next = task("one", .opencode, turn: "turn-2")
        let oldProof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        let nextProof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-2")
        cache.apply(capture([next], active: [.opencode: [oldProof, nextProof]], ended: [.opencode: [oldProof]],
                            complete: [.opencode]), quality: .current, providers: [.opencode])
        let stillOld = try XCTUnwrap(cache.tasks.first)
        XCTAssertEqual(stillOld.startKey, "turn-1")
        XCTAssertTrue(stillOld.isUnconfirmed)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])

        let transition = ExternalProviderVerifiedSuccessor(id: "one", oldStartKey: "turn-1", newStartKey: "turn-2")
        cache.apply(capture([next], active: [.opencode: [nextProof]], successors: [.opencode: [transition]],
                            complete: [.opencode]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed,
                      "A successor alone does not order an unattributed terminal")
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])

        cache.apply(capture([next], active: [.opencode: [nextProof]], successors: [.opencode: [transition]],
                            afterTerminal: [.opencode: [nextProof]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        let restored = try XCTUnwrap(cache.tasks.first)
        XCTAssertEqual(restored.startKey, "turn-2")
        XCTAssertTrue(restored.isActive)
        XCTAssertTrue(cache.pendingTerminalIDs.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testVerifiedSuccessorCanRecoverWhenNoTerminalWasLost() throws {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode)]), quality: .current, providers: [.opencode])
        cache.markUncertain([.opencode])
        let next = task("one", .opencode, turn: "turn-2")
        let nextProof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-2")
        let transition = ExternalProviderVerifiedSuccessor(id: "one", oldStartKey: "turn-1", newStartKey: "turn-2")
        cache.apply(capture([next], active: [.opencode: [nextProof]], successors: [.opencode: [transition]],
                            complete: [.opencode]), quality: .current, providers: [.opencode])
        let restored = try XCTUnwrap(cache.tasks.first)
        XCTAssertTrue(restored.isActive)
        XCTAssertEqual(restored.startKey, "turn-2")
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testVerifiedTerminalForTheRetainedTurnCanRemoveIt() {
        var cache = ExternalProviderRefreshCache()
        cache.apply(capture([task("one", .opencode)]), quality: .current, providers: [.opencode])
        cache.apply(capture([], terminalIDs: [.opencode: ["one"]]), quality: .delayed, providers: [.opencode])
        let wrong = ExternalProviderVerifiedTurn(id: "one", startKey: "different")
        cache.apply(capture([], ended: [.opencode: [wrong]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertEqual(cache.tasks.count, 1)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])

        let matching = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([], ended: [.opencode: [matching]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(cache.tasks.isEmpty)
        XCTAssertTrue(cache.pendingTerminalIDs.isEmpty)
        XCTAssertTrue(cache.uncertainProviders.isEmpty)
    }

    func testLateOrWrongProviderProofCannotRestoreState() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode)
        cache.apply(capture([first]), quality: .current, providers: [.opencode])
        cache.markUncertain([.opencode])
        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode]),
                    quality: .delayed, providers: [.opencode])
        cache.apply(capture([first], active: [.deepseek: [proof]], complete: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        XCTAssertEqual(cache.uncertainProviders, [.opencode])
    }

    func testConfirmedDisconnectAndReconnectRejectOldCapturesWithoutChangingNeighbor() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode), neighbor = task("two", .deepseek)
        let old = capture([first, neighbor], terminalIDs: [.opencode: ["obsolete"]])
        cache.apply(capture([first, neighbor]), quality: .current, providers: [.opencode, .deepseek])
        let disconnected = try XCTUnwrap(cache.confirmDisconnected(.opencode))
        XCTAssertEqual(disconnected, 1)
        cache.apply(old, quality: .current, providers: [.opencode, .deepseek])
        XCTAssertFalse(cache.tasks.contains { $0.provider == .opencode })
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        XCTAssertNil(cache.pendingTerminalIDs[.opencode])

        let reconnected = try XCTUnwrap(cache.beginReconnection(.opencode))
        XCTAssertEqual(reconnected, 2)
        cache.apply(old, quality: .current, providers: [.opencode, .deepseek])
        XCTAssertFalse(cache.tasks.contains { $0.provider == .opencode })
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["obsolete"])
        XCTAssertEqual(cache.quarantinedTaskCount, 1)
        XCTAssertTrue(cache.uncertainProviders.contains(.opencode))

        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode],
                            generations: [.opencode: reconnected]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        XCTAssertEqual(cache.quarantinedTaskCount, 1)
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode],
                            generations: [.opencode: reconnected], reconciled: [.opencode]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isActive)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        XCTAssertFalse(cache.uncertainProviders.contains(.opencode))
        XCTAssertTrue(cache.pendingTerminalIDs.isEmpty)
        XCTAssertEqual(cache.quarantinedTaskCount, 0)
        cache.markUncertain([.opencode], sourceGenerations: [.opencode: 0])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isActive,
                      "A delayed callback from the older source generation must be ignored")
    }

    func testReconnectWithoutDisconnectMarksExistingCardUnconfirmedUntilProven() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode), neighbor = task("two", .deepseek)
        cache.apply(capture([first, neighbor]), quality: .current, providers: [.opencode, .deepseek])
        let generation = try XCTUnwrap(cache.beginReconnection(.opencode))
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        cache.apply(capture([first]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode],
                            generations: [.opencode: generation]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isActive)
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        XCTAssertFalse(cache.uncertainProviders.contains(.opencode))
    }

    func testNewTaskAfterReconnectNeedsSourceProofBeforeClaimingActivity() throws {
        var cache = ExternalProviderRefreshCache()
        _ = try XCTUnwrap(cache.confirmDisconnected(.opencode))
        let generation = try XCTUnwrap(cache.beginReconnection(.opencode))
        let first = task("one", .opencode)
        cache.apply(capture([first], complete: [.opencode], generations: [.opencode: generation]),
                    quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isUnconfirmed)
        XCTAssertTrue(cache.uncertainProviders.contains(.opencode))
        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode],
                            generations: [.opencode: generation]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first).isActive)
        XCTAssertFalse(cache.uncertainProviders.contains(.opencode))
    }

    func testLateOldGenerationAfterRecoveryIsQuarantinedAndReopensUncertainty() throws {
        var cache = ExternalProviderRefreshCache()
        let first = task("one", .opencode), neighbor = task("two", .deepseek)
        cache.apply(capture([first, neighbor]), quality: .current, providers: [.opencode, .deepseek])
        let generation = try XCTUnwrap(cache.beginReconnection(.opencode))
        let proof = ExternalProviderVerifiedTurn(id: "one", startKey: "turn-1")
        cache.apply(capture([first], active: [.opencode: [proof]], complete: [.opencode],
                            generations: [.opencode: generation]), quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isActive)

        let old = capture([task("hidden", .opencode)], terminalIDs: [.opencode: ["one"]])
        cache.apply(old, quality: .current, providers: [.opencode])
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .opencode }).isUnconfirmed)
        XCTAssertFalse(cache.tasks.contains { $0.id == "hidden" })
        XCTAssertTrue(try XCTUnwrap(cache.tasks.first { $0.provider == .deepseek }).isActive)
        XCTAssertEqual(cache.pendingTerminalIDs[.opencode], ["one"])
        XCTAssertEqual(cache.quarantinedTaskCount, 1)
        XCTAssertTrue(cache.uncertainProviders.contains(.opencode))
    }
}
