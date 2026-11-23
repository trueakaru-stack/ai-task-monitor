import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexTaskGroupingTests: XCTestCase {
    private let root = "019127f4-35ae-7c73-9e72-a10123456789"
    private let child1 = "019127f4-35ae-7c73-9e72-a10123456780"
    private let child2 = "019127f4-35ae-7c73-9e72-a10123456781"
    private let grandchild = "019127f4-35ae-7c73-9e72-a10123456782"
    private let completed = "019127f4-35ae-7c73-9e72-a10123456783"

    private func task(_ id: String, title: String = "Synthetic task", provider: TaskProvider = .codex,
                      active: Bool = true, uncertain: Bool = false) -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: title, activity: "Synthetic activity",
                      isActive: active, progress: 50, progressKind: .exact,
                      steps: [TaskStep(title: "Synthetic step", status: .active)],
                      updatedAt: Date(timeIntervalSince1970: 1_000), isUnconfirmed: uncertain)
    }

    func testGroupsObservedDescendantsPreservingParentAndExcludingCompleted() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let parent = task(root, title: "Parent")
        let one = task(child1), two = task(child2, active: false, uncertain: true)
        let grand = task(grandchild), done = task(completed, active: false)
        let links = [child1: root, child2: root, grandchild: child1, completed: child1]
        let original = [parent, one, two, grand, done, one]
        let result = CodexTaskGrouping.project(original, parents: links, titles: [:], confirmedRoots: [root])
        XCTAssertEqual(result.count, 1)
        var expected = parent
        expected.codexAgentCount = 3
        expected.codexAgentsUnconfirmed = true
        expected.codexAgents = [one, two, grand].sorted { $0.id < $1.id }.map {
            CodexAgentDetail(id: $0.id, title: $0.title, activity: $0.activity,
                             isActive: $0.isActive && !$0.isUnconfirmed,
                             isUnconfirmed: $0.isUnconfirmed, loopWarning: $0.loopWarning)
        }
        XCTAssertEqual(result.first, expected)
        XCTAssertEqual(result.first?.codexAgentCountLabel, "(3 agents, status unconfirmed)")
        let reordered = CodexTaskGrouping.project(Array(original.reversed()), parents: links, titles: [:], confirmedRoots: [root])
        XCTAssertEqual(reordered, result)
    }

    func testAssistantListUpdatesWithoutChangingParentState() throws {
        let parent = task(root, title: "Parent")
        var child = task(child1, title: "Assistant", active: false, uncertain: true)
        child.activity = "Status unconfirmed"
        child.lastKnownActivity = "Last observed action"
        child.lastActivityIdentityConfirmed = true
        let grouped = try XCTUnwrap(CodexTaskGrouping.project([parent, child], parents: [child1: root], titles: [:], confirmedRoots: [root]).first)
        XCTAssertEqual(grouped.activity, parent.activity)
        XCTAssertEqual(grouped.progress, parent.progress)
        XCTAssertEqual(grouped.codexAgents?.first?.activity, "Last observed action")
        XCTAssertTrue(try XCTUnwrap(grouped.codexAgents?.first?.isUnconfirmed))
        child.lastKnownActivity = "Later observed action"
        let updated = try XCTUnwrap(CodexTaskGrouping.project([parent, child], parents: [child1: root], titles: [:], confirmedRoots: [root]).first)
        XCTAssertNotEqual(grouped, updated)
        XCTAssertEqual(updated.codexAgents?.first?.activity, "Later observed action")
    }

    func testLastKnownActionSurvivesTemporarySourceLossWithoutClaimingWork() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        var child = task(child1, title: "Assistant")
        child.activity = "Checking files"
        let originalFile = CodexFileIdentity(device: 1, inode: 10)
        child.lastActivityFileIdentity = originalFile
        let retained = TaskSnapshotMerger.merge(previous: [child], current: [], terminalIDs: [])
        XCTAssertEqual(retained.first?.lastKnownActivity, "Checking files")
        XCTAssertEqual(retained.first?.displayedActivity, "Status unconfirmed")
        let grouped = try XCTUnwrap(CodexTaskGrouping.project([task(root)] + retained,
                                                             parents: [child1: root], titles: [:], confirmedRoots: [root]).first)
        let detail = try XCTUnwrap(grouped.codexAgents?.first)
        XCTAssertEqual(detail.activity, "Status unconfirmed")
        XCTAssertTrue(detail.isUnconfirmed)
        XCTAssertFalse(detail.isActive)

        child.activity = "Working"
        let generic = try XCTUnwrap(TaskSnapshotMerger.merge(previous: [child], current: [], terminalIDs: []).first)
        XCTAssertNil(generic.lastKnownActivity)
        XCTAssertEqual(generic.displayedActivity, "Status unconfirmed")
        let verified = try XCTUnwrap(TaskSnapshotMerger.confirmCodexActivities(retained, files: [child1: originalFile]).first)
        XCTAssertEqual(verified.displayedActivity, "Status unconfirmed. Last: Checking files")
        let changedFile = CodexFileIdentity(device: 1, inode: 11)
        let mismatch = try XCTUnwrap(TaskSnapshotMerger.confirmCodexActivities(retained, files: [child1: changedFile]).first)
        XCTAssertEqual(mismatch.displayedActivity, "Status unconfirmed")
        var replacement = child
        replacement.activity = "Status unconfirmed"
        replacement.isUnconfirmed = true
        replacement.isActive = false
        replacement.lastKnownActivity = "Action from replacement"
        replacement.lastActivityIdentityConfirmed = true
        let replaced = try XCTUnwrap(TaskSnapshotMerger.merge(previous: retained, current: [replacement], terminalIDs: []).first)
        XCTAssertEqual(replaced.displayedActivity, "Status unconfirmed. Last: Action from replacement")
        XCTAssertFalse(replaced.displayedActivity.contains("Checking files"))
    }

    func testCompletedIntermediateStillLinksObservedGrandchild() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let parent = task(root, title: "Parent")
        let result = CodexTaskGrouping.project([parent, task(grandchild)],
            parents: [child1: root, grandchild: child1], titles: [:], confirmedRoots: [root])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Parent")
        XCTAssertEqual(result.first?.codexAgentCountLabel, "(1 agent)")
        XCTAssertEqual(result.first?.activity, parent.activity)
        XCTAssertEqual(result.first?.progress, parent.progress)
    }

    func testFinishedHistoryIsExcludedAndUnknownAgentsAreNotCalledWorking() throws {
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        let history = (1...12).map { index in
            task(String(format: "00000000-0000-4000-8000-%012d", index), active: false)
        }
        let known = task(child1, active: true)
        let unknown = task(child2, active: false, uncertain: true)
        let links = Dictionary(uniqueKeysWithValues: (history + [known, unknown]).map { ($0.id, root) })
        let result = CodexTaskGrouping.project([task(root)] + history + [known, unknown],
                                               parents: links, titles: [:], confirmedRoots: [root])
        let parent = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(parent.codexAgentCount, 2)
        XCTAssertTrue(try XCTUnwrap(parent.codexAgentsUnconfirmed))
        XCTAssertEqual(Set(try XCTUnwrap(parent.codexAgents).map(\.id)), Set([child1, child2]))
        XCTAssertFalse(try XCTUnwrap(parent.codexAgentCountLabel).contains("работают"))
        XCTAssertEqual(parent.codexAgentStatusLabel, "Статус агентов не подтверждён")
    }

    func testEqualTitlesAndOtherProvidersNeverDetermineLinks() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let parentA = task(root, title: "Same")
        let parentB = task(child2, title: "Same")
        let claude = task(child1, title: "Same", provider: .claude)
        let cloud = task("codex-cloud:synthetic", title: "Same")
        let result = CodexTaskGrouping.project([parentA, parentB, task(child1), task(grandchild), claude, cloud],
            parents: [child1: root, grandchild: child2], titles: [:], confirmedRoots: [root, child2])
        XCTAssertEqual(result.count, 4)
        XCTAssertTrue(result.contains { $0.id == root && $0.title == "Same" && $0.codexAgentCountLabel == "(1 agent)" })
        XCTAssertTrue(result.contains { $0.id == child2 && $0.title == "Same" && $0.codexAgentCountLabel == "(1 agent)" })
        XCTAssertTrue(result.contains { $0.provider == .claude && $0.id == child1 })
        XCTAssertTrue(result.contains { $0.id == "codex-cloud:synthetic" })
    }

    func testMissingParentUsesKnownTitleAndUnknownStatus() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let result = CodexTaskGrouping.project([task(child1, active: false, uncertain: true), task(grandchild)],
            parents: [child1: root, grandchild: child1], titles: [root: "Parent"], confirmedRoots: [root])
        let parent = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(parent.id, "codex-group:" + root)
        XCTAssertEqual(parent.title, "Parent")
        XCTAssertEqual(parent.codexAgentCountLabel, "(2 agents, status unconfirmed)")
        XCTAssertTrue(parent.isUnconfirmed)
        XCTAssertFalse(parent.isActive)
        XCTAssertNil(parent.progress)
    }

    func testSelectionMapsChildToParentAcrossGhostAndVisibleStates() throws {
        let child = task(child1)
        let ghost = CodexTaskGrouping.makeProjection([child], parents: [child1: root], titles: [root: "Parent"], confirmedRoots: [root])
        XCTAssertEqual(ghost.displayIDBySourceID[child1], "codex-group:" + root)
        let visible = CodexTaskGrouping.makeProjection([task(root), child], parents: [child1: root], titles: [root: "Parent"], confirmedRoots: [root])
        XCTAssertEqual(visible.displayIDBySourceID[child1], root)
        XCTAssertEqual(visible.displayIDBySourceID["codex-group:" + root], root)
        XCTAssertEqual(ghost.displayIDBySourceID[root], "codex-group:" + root)
    }

    func testIncompleteChainsAndCyclesRemainSeparate() throws {
        let tasks = [task(child1), task(child2), task(grandchild)]
        let missing = CodexTaskGrouping.project(tasks, parents: [child1: root], titles: [:], confirmedRoots: [root])
        XCTAssertEqual(Set(missing.map(\.id)), Set(tasks.map(\.id)))
        let cyclic = CodexTaskGrouping.project(tasks,
            parents: [child1: child2, child2: child1, grandchild: child1], titles: [root: "Parent"], confirmedRoots: [root])
        XCTAssertEqual(Set(cyclic.map(\.id)), Set(tasks.map(\.id)))
        let selfLoop = CodexTaskGrouping.project(tasks,
            parents: [child1: child1, grandchild: child1], titles: [child1: "Parent"], confirmedRoots: [child1])
        XCTAssertEqual(Set(selfLoop.map(\.id)), Set(tasks.map(\.id)))
    }

    func testUnknownIntermediateAndTitleAloneNeverEstablishRoot() throws {
        let parent = task(root, title: "Parent")
        let intermediate = task(child1, title: "Intermediate")
        let child = task(grandchild, title: "Child")
        let links = [grandchild: child1]
        let visible = CodexTaskGrouping.project([parent, intermediate, child], parents: links,
                                                titles: [child1: "Intermediate"], confirmedRoots: [root])
        XCTAssertEqual(Set(visible.map(\.id)), Set([root, child1, grandchild]))
        let absent = CodexTaskGrouping.project([parent, child], parents: links,
                                               titles: [child1: "Intermediate"], confirmedRoots: [root])
        XCTAssertEqual(Set(absent.map(\.id)), Set([root, grandchild]))
        let complete = CodexTaskGrouping.project([parent, intermediate, child],
            parents: [child1: root, grandchild: child1], titles: [:], confirmedRoots: [root])
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete.first?.codexAgentCount, 2)
        let contradiction = CodexTaskGrouping.project([parent, intermediate, child],
            parents: [child1: root, grandchild: child1], titles: [:], confirmedRoots: [root, child1])
        XCTAssertEqual(Set(contradiction.map(\.id)), Set([root, child1, grandchild]))
    }

    func testRussianAndEnglishAgentCounts() throws {
        let counts = [1, 2, 5, 11, 21]
        let russian = ["агент", "агента", "агентов", "агентов", "агент"]
        defer { AppLanguage.previewOverride = nil }
        for (offset, count) in counts.enumerated() {
            let children = (1...count).map { index in
                task(String(format: "00000000-0000-4000-8000-%012d", index))
            }
            let links = Dictionary(uniqueKeysWithValues: children.map { ($0.id, root) })
            AppLanguage.previewOverride = .ru
            let ru = try XCTUnwrap(CodexTaskGrouping.project([task(root, title: "Root")] + children,
                                                             parents: links, titles: [:], confirmedRoots: [root]).first)
            XCTAssertEqual(ru.title, "Root")
            XCTAssertEqual(ru.codexAgentCountLabel, "(\(count) \(russian[offset]))")
            var uncertain = ru
            uncertain.codexAgentsUnconfirmed = true
            XCTAssertEqual(uncertain.codexAgentStatusLabel,
                           count == 1 ? "Статус агента не подтверждён" : "Статус агентов не подтверждён")
            AppLanguage.previewOverride = .en
            let en = try XCTUnwrap(CodexTaskGrouping.project([task(root, title: "Root")] + children,
                                                             parents: links, titles: [:], confirmedRoots: [root]).first)
            XCTAssertEqual(en.title, "Root")
            XCTAssertEqual(en.codexAgentCountLabel, "(\(count) \(count == 1 ? "agent" : "agents"))")
        }
    }

    func testIncompleteBatchKeepsUnexaminedCardsUntilLinksArrive() throws {
        let parent = task(root)
        let children = (1...50).map { index in
            task(String(format: "00000000-0000-4000-8000-%012d", index), active: false, uncertain: true)
        }
        let firstLinks = Dictionary(uniqueKeysWithValues: children.prefix(16).map { ($0.id, root) })
        let partial = CodexTaskGrouping.project([parent] + children, parents: firstLinks, titles: [:], confirmedRoots: [root])
        XCTAssertEqual(partial.count, 35)
        XCTAssertEqual(partial.first(where: { $0.id == root })?.codexAgentCount, 16)
        XCTAssertEqual(Set(partial.filter { $0.id != root }.map(\.id)), Set(children.dropFirst(16).map(\.id)))

        let allLinks = Dictionary(uniqueKeysWithValues: children.map { ($0.id, root) })
        let complete = CodexTaskGrouping.project([parent] + children, parents: allLinks, titles: [:], confirmedRoots: [root])
        XCTAssertEqual(complete.count, 1)
        XCTAssertEqual(complete.first?.codexAgentCount, 50)
        XCTAssertTrue(try XCTUnwrap(complete.first?.codexAgentsUnconfirmed))
    }
}
