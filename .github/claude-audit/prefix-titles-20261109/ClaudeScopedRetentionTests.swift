import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeScopedRetentionTests: XCTestCase {
    @MainActor
    func testSessionScopedPhaseLossRetainsOnlyAffectedHistory() {
        let oldA = MonitoredTask(id: "claude:a", provider: .claude, title: "A", activity: "", isActive: true,
                                 progress: nil, progressKind: .none,
                                 steps: [TaskStep(id: "one", title: "Old A", status: .pending)], updatedAt: Date(), planConfirmed: false)
        let oldB = MonitoredTask(id: "claude:b", provider: .claude, title: "B", activity: "", isActive: true,
                             progress: nil, progressKind: .none,
                             steps: [TaskStep(id: "one", title: "Old B", status: .pending)], updatedAt: Date(), planConfirmed: false)
        var currentA = oldA; currentA.steps = [TaskStep(id: "one", title: "New A", status: .pending)]
        var currentB = oldB; currentB.steps = [TaskStep(id: "one", title: "New B", status: .pending)]
        let result = TaskStore.preserveUncertainClaudeTitles(previous: [oldA, oldB], current: [currentA, currentB], affected: ["claude:a"])
        XCTAssertEqual(result.tasks[0].steps.map(\.title), ["Old A", "New A"])
        XCTAssertEqual(result.tasks[1].steps.map(\.title), ["New B"])
        XCTAssertFalse(result.overflow)
    }
}
