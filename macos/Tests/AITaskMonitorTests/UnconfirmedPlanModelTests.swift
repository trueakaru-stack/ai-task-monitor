import Foundation
import XCTest
@testable import AITaskMonitor

final class UnconfirmedPlanModelTests: XCTestCase {
    func testSourceLossKeepsStepTitlesButClearsConfirmedProgress() {
        let task = MonitoredTask(id: "codex", provider: .codex, title: "Synthetic task", activity: "Working",
                                 isActive: true, progress: 50, progressKind: .exact,
                                 steps: [TaskStep(id: "one", title: "First", status: .done),
                                         TaskStep(id: "two", title: "Second", status: .active)],
                                 updatedAt: Date())
        let retained = TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(retained[0].isUnconfirmed)
        XCTAssertFalse(retained[0].planConfirmed)
        XCTAssertNil(retained[0].progress)
        XCTAssertEqual(retained[0].progressKind, .none)
        XCTAssertEqual(retained[0].steps.map(\.title), ["First", "Second"])
        XCTAssertEqual(TaskSnapshotMerger.merge(previous: retained, current: [task], terminalIDs: []), [task])
    }

    func testConfirmedTaskCanStillShowItsActualOverallPercentage() {
        let task = MonitoredTask(id: "codex", provider: .codex, title: "Synthetic task", activity: "Working",
                                 isActive: true, progress: 55, progressKind: .exact,
                                 steps: [TaskStep(id: "one", title: "First", status: .pending)],
                                 updatedAt: Date(), planConfirmed: false, progressBasis: .task)
        XCTAssertEqual(task.progressLabel, "55%")
    }

    func testUnconfirmedTaskDoesNotShowOverallPercentage() {
        let task = MonitoredTask(id: "codex", provider: .codex, title: "Synthetic task", activity: "",
                                 isActive: false, progress: 55, progressKind: .exact, steps: [],
                                 updatedAt: Date(), isUnconfirmed: true, progressBasis: .task)
        XCTAssertNil(task.progressLabel)
    }
}
