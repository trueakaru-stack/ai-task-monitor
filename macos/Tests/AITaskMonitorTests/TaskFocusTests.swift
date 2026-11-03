import Foundation
import XCTest
@testable import AITaskMonitor

final class TaskFocusTests: XCTestCase {
    private func task(_ id: String, active: Bool, key: String, start: TimeInterval, update: TimeInterval? = nil) -> MonitoredTask {
        MonitoredTask(id: id, provider: .codex, title: id, activity: "", isActive: active,
                      progress: nil, progressKind: .none, steps: [],
                      updatedAt: Date(timeIntervalSince1970: update ?? start),
                      startedAt: Date(timeIntervalSince1970: start), startKey: key)
    }

    func testNewAndResumedTasksTakeFocusWithoutReactingToNormalUpdates() {
        var tracker = TaskFocusTracker()
        let old = task("old", active: true, key: "turn-1", start: 1)
        let uncertain = task("uncertain", active: false, key: "turn-x", start: 2)
        let first = tracker.reconcile(current: [uncertain, old], previous: [], selectedID: nil)
        XCTAssertEqual(first.selectedID, "old")
        XCTAssertEqual(first.tasks.first?.id, "old")

        let new = task("new", active: true, key: "turn-2", start: 3)
        let added = tracker.reconcile(current: [old, uncertain, new], previous: [old, uncertain], selectedID: "old")
        XCTAssertEqual(added.selectedID, "new")
        XCTAssertEqual(added.tasks.first?.id, "new")

        let updated = task("old", active: true, key: "turn-1", start: 1, update: 9)
        let stable = tracker.reconcile(current: [updated, uncertain, new], previous: [old, uncertain, new], selectedID: "old")
        XCTAssertEqual(stable.selectedID, "old")
        XCTAssertEqual(stable.tasks.first?.id, "new")

        let resumed = task("old", active: true, key: "turn-3", start: 10)
        let restarted = tracker.reconcile(current: [resumed, uncertain, new], previous: [updated, uncertain, new], selectedID: "new")
        XCTAssertEqual(restarted.selectedID, "old")
        XCTAssertEqual(restarted.tasks.first?.id, "old")

        let recovered = task("uncertain", active: true, key: "turn-x", start: 2, update: 11)
        let recovery = tracker.reconcile(current: [resumed, recovered, new], previous: [resumed, uncertain, new], selectedID: "old")
        XCTAssertEqual(recovery.selectedID, "old")
    }

    func testSimultaneousDiscoveriesPreferTheLatestStart() {
        var tracker = TaskFocusTracker()
        let earlier = task("earlier", active: true, key: "one", start: 20, update: 99)
        let later = task("later", active: true, key: "two", start: 21)
        let result = tracker.reconcile(current: [earlier, later], previous: [], selectedID: nil)
        XCTAssertEqual(result.selectedID, "later")
        XCTAssertEqual(result.tasks.first?.id, "later")
    }

    func testNewUnconfirmedStartTakesFocusWithoutPretendingItIsActive() {
        var tracker = TaskFocusTracker()
        let monitorStart = Date(timeIntervalSince1970: 5)
        let active = task("active", active: true, key: "one", start: 1)
        _ = tracker.reconcile(current: [active], previous: [], selectedID: nil, monitoringStartedAt: monitorStart)
        var unknown = task("unknown", active: false, key: "two", start: 6)
        unknown.isUnconfirmed = true
        let added = tracker.reconcile(current: [active, unknown], previous: [active], selectedID: "active", monitoringStartedAt: monitorStart)
        XCTAssertEqual(added.selectedID, "unknown")
        XCTAssertEqual(added.tasks.first?.id, "unknown")
        XCTAssertFalse(added.tasks[0].isActive)
        let stable = tracker.reconcile(current: [active, unknown], previous: [active, unknown], selectedID: "active", monitoringStartedAt: monitorStart)
        XCTAssertEqual(stable.selectedID, "active")
        var resumed = task("unknown", active: false, key: "three", start: 7)
        resumed.isUnconfirmed = true
        let restarted = tracker.reconcile(current: [active, resumed], previous: [active, unknown], selectedID: "active", monitoringStartedAt: monitorStart)
        XCTAssertEqual(restarted.selectedID, "unknown")
        XCTAssertEqual(restarted.tasks.first?.id, "unknown")
    }
}
