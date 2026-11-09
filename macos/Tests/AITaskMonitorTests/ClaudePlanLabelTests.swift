import Foundation
import XCTest
@testable import AITaskMonitor

@MainActor
final class ClaudePlanLabelTests: XCTestCase {
    private func task(count: Int = 1, provider: TaskProvider = .claude,
                      planConfirmed: Bool = true, isUnconfirmed: Bool = false) -> MonitoredTask {
        let steps = (0..<count).map { TaskStep(id: "step-\($0)", title: "Synthetic", status: .pending) }
        return MonitoredTask(id: "synthetic", provider: provider, title: "Synthetic", activity: "",
                             isActive: true, progress: 0, progressKind: .exact, steps: steps,
                             updatedAt: Date(), isUnconfirmed: isUnconfirmed, planConfirmed: planConfirmed)
    }

    func testStepCountLabelsInBothLanguages() {
        defer { AppLanguage.previewOverride = nil }
        AppLanguage.previewOverride = .ru
        for (count, expected) in [(1,"1 этап"), (2,"2 этапа"), (4,"4 этапа"), (5,"5 этапов"),
                                  (11,"11 этапов"), (14,"14 этапов"), (21,"21 этап"), (22,"22 этапа")] {
            XCTAssertEqual(task(count: count).stepCountLabel, expected)
        }
        AppLanguage.previewOverride = .en
        XCTAssertEqual(task(count: 1).stepCountLabel, "1 step")
        XCTAssertEqual(task(count: 2).stepCountLabel, "2 steps")
    }

    func testPlanNotesMatchObservedAndUnconfirmedStates() {
        defer { AppLanguage.previewOverride = nil }
        AppLanguage.previewOverride = .ru
        XCTAssertEqual(task().planStatusNote, "По известным этапам, возможна неточность")
        AppLanguage.previewOverride = .en
        XCTAssertEqual(task().planStatusNote, "Based on observed steps; may be inaccurate")
        XCTAssertEqual(task(planConfirmed: false).planStatusNote, "Plan unconfirmed")
        XCTAssertEqual(task(isUnconfirmed: true).planStatusNote, "Plan unconfirmed")
        XCTAssertNil(task(count: 0).planStatusNote)
        XCTAssertNil(task(provider: .codex).planStatusNote)
        XCTAssertEqual(task(provider: .codex, planConfirmed: false).planStatusNote, "Plan unconfirmed")
    }
}
