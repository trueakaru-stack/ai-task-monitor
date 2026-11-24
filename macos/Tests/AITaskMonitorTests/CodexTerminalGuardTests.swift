import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexTerminalGuardTests: XCTestCase {
    private let file = CodexFileIdentity(device: 1, inode: 5)

    private func task(_ key: String, file: CodexFileIdentity? = CodexFileIdentity(device: 1, inode: 5)) -> MonitoredTask {
        MonitoredTask(id: "thread", provider: .codex, title: "Synthetic", activity: "Working",
                      isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date(),
                      startKey: key, lastActivityIdentityConfirmed: true, lastActivityFileIdentity: file)
    }

    func testDiscardedEndingKeepsSameAndDifferentTurnsUnknown() {
        let old = task("turn:old")
        var guarder = CodexTerminalGuard()
        guarder.remember([old.id], previous: [old])
        var snapshot = CodexTaskSnapshot()
        snapshot.tasks = [old]
        let same = guarder.reconcile(snapshot, previous: [old])
        XCTAssertTrue(same.tasks[0].isUnconfirmed)
        XCTAssertFalse(same.tasks[0].isActive)
        XCTAssertTrue(same.isPartial)

        let restarted = task("turn:new")
        snapshot.tasks = [restarted]
        let next = guarder.reconcile(snapshot, previous: same.tasks)
        XCTAssertFalse(next.tasks[0].isActive)
        XCTAssertTrue(next.tasks[0].isUnconfirmed)
        XCTAssertNotNil(guarder.pending[old.id])
    }

    func testOnlySameFileAndTurnCanConfirmDiscardedEnding() {
        let old = task("turn:old")
        var guarder = CodexTerminalGuard()
        guarder.remember([old.id], previous: [old])
        var snapshot = CodexTaskSnapshot()
        snapshot.terminalIDs = [old.id]
        snapshot.terminalEvidence[old.id] = CodexTerminalEvidence(
            file: CodexFileIdentity(device: 1, inode: 6), startKey: old.startKey)
        let wrongFile = guarder.reconcile(snapshot, previous: [old])
        XCTAssertTrue(wrongFile.terminalIDs.isEmpty)
        XCTAssertNotNil(guarder.pending[old.id])
        snapshot.terminalEvidence[old.id] = CodexTerminalEvidence(file: file, startKey: "turn:other")
        XCTAssertTrue(guarder.reconcile(snapshot, previous: [old]).terminalIDs.isEmpty)
        snapshot.terminalEvidence[old.id] = CodexTerminalEvidence(file: file, startKey: old.startKey)
        XCTAssertEqual(guarder.reconcile(snapshot, previous: [old]).terminalIDs, [old.id])
        XCTAssertTrue(guarder.pending.isEmpty)
    }

    func testMissingOrConflictingIdentityNeverConfirmsAnotherTurn() {
        let unknown = task("turn:old", file: nil)
        var guarder = CodexTerminalGuard()
        guarder.remember([unknown.id], previous: [unknown])
        var snapshot = CodexTaskSnapshot()
        snapshot.tasks = [task("turn:new")]
        XCTAssertTrue(guarder.reconcile(snapshot, previous: [unknown]).tasks[0].isUnconfirmed)
        snapshot.terminalIDs = [unknown.id]
        snapshot.terminalEvidence[unknown.id] = CodexTerminalEvidence(file: file, startKey: "turn:old")
        XCTAssertTrue(guarder.reconcile(snapshot, previous: [unknown]).terminalIDs.isEmpty)

        let duplicate = task("turn:old", file: CodexFileIdentity(device: 1, inode: 6))
        var conflicting = CodexTerminalGuard()
        snapshot.tasks = []
        XCTAssertTrue(conflicting.reconcile(snapshot, previous: [task("turn:old"), duplicate]).terminalIDs.isEmpty)
    }

    func testBoundedAmbiguousTurnsRemainUnknownWhenCapacityIsExceeded() {
        var guarder = CodexTerminalGuard()
        for index in 0...CodexTerminalGuard.maximumTurnsPerID {
            let old = task("turn:\(index)")
            guarder.remember([old.id], previous: [old])
        }
        XCTAssertTrue(guarder.overflowed)
        XCTAssertEqual(guarder.pending["thread"]?.count, CodexTerminalGuard.maximumTurnsPerID)
        var snapshot = CodexTaskSnapshot()
        snapshot.tasks = [task("turn:new")]
        snapshot.terminalIDs = ["other"]
        let result = guarder.reconcile(snapshot, previous: [])
        XCTAssertTrue(result.tasks[0].isUnconfirmed)
        XCTAssertTrue(result.terminalIDs.isEmpty)
        XCTAssertTrue(result.isPartial)
    }

    func testBoundedAmbiguousIDsRemainUnknownWhenCapacityIsExceeded() {
        var guarder = CodexTerminalGuard()
        for index in 0...CodexTerminalGuard.maximumPendingIDs {
            var old = task("turn:old")
            old = MonitoredTask(id: "thread-\(index)", provider: .codex, title: old.title,
                                activity: old.activity, isActive: true, progress: nil,
                                progressKind: .none, steps: [], updatedAt: old.updatedAt,
                                startKey: old.startKey, lastActivityIdentityConfirmed: true,
                                lastActivityFileIdentity: file)
            guarder.remember([old.id], previous: [old])
        }
        XCTAssertTrue(guarder.overflowed)
        XCTAssertEqual(guarder.pending.count, CodexTerminalGuard.maximumPendingIDs)
        var snapshot = CodexTaskSnapshot()
        snapshot.tasks = [task("turn:new")]
        snapshot.terminalIDs = ["thread"]
        let result = guarder.reconcile(snapshot, previous: [])
        XCTAssertTrue(result.tasks[0].isUnconfirmed)
        XCTAssertTrue(result.terminalIDs.isEmpty)
    }

    func testOverlongTurnIdentityDoesNotEnterPendingStorage() {
        let old = task(String(repeating: "x", count: CodexTerminalGuard.maximumIdentityBytes + 1))
        var guarder = CodexTerminalGuard()
        guarder.remember([old.id], previous: [old])
        XCTAssertTrue(guarder.overflowed)
        XCTAssertTrue(guarder.pending.isEmpty)
        var snapshot = CodexTaskSnapshot()
        snapshot.tasks = [task("turn:new")]
        XCTAssertTrue(guarder.reconcile(snapshot, previous: [old]).tasks[0].isUnconfirmed)
    }
}
