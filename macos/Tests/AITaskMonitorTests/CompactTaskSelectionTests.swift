import Foundation
import XCTest
@testable import AITaskMonitor

final class CompactTaskSelectionTests: XCTestCase {
    private func task(_ id: String, title: String = "Task", provider: TaskProvider = .codex,
                      start: TimeInterval = 1) -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: title, activity: "Current action",
                      isActive: true, progress: nil, progressKind: .none, steps: [],
                      updatedAt: Date(timeIntervalSince1970: start),
                      startedAt: Date(timeIntervalSince1970: start), startKey: "turn-\(id)")
    }

    @MainActor
    func testCompactHidesVerifiedChildAndMapsVisibleSelection() {
        let root = "019127f4-35ae-7c73-9e72-a10123456789"
        let child = "019127f4-35ae-7c73-9e72-a10123456780"
        let derived = "019127f4-35ae-7c73-9e72-a10123456781"
        let unknown = "019127f4-35ae-7c73-9e72-a10123456782"
        let other = "claude:synthetic"
        let childFile = CodexFileIdentity(device: 1, inode: 10)
        let derivedFile = CodexFileIdentity(device: 1, inode: 11)
        var childTask = task(child)
        childTask.lastActivityFileIdentity = childFile
        var disputed = task(derived, title: "Parent (agent Curie)")
        disputed.usesDerivedCodexParentTitle = true
        disputed.lastActivityFileIdentity = derivedFile
        let source = [childTask, task(root, title: "Parent"), disputed,
                      task(unknown, title: "Parent (agent Curie)"), task(other, provider: .claude)]
        var snapshot = CodexTaskSnapshot()
        snapshot.subagentParents = [child: root, derived: root]
        snapshot.tasks = [childTask, disputed]
        snapshot.verifiedActivityFiles = [child: childFile, derived: derivedFile]

        XCTAssertEqual(CodexTaskGrouping.compactVisibleIndices(source, confirmedChildren: [child: childFile, derived: derivedFile]), [1, 3, 4])
        // Identical text without a current structural observation remains visible.
        XCTAssertEqual(source.count, 5)
        let store = TaskStore(previewTasks: source)
        store.testSetCompactSnapshot(snapshot)
        XCTAssertEqual(store.compactTasks.map(\.id), [root, unknown, other])
        XCTAssertEqual(store.compactTasks.first?.displayedActivity, "Current action")
        store.selectCompactTask(dot: store.compactDots[1])
        XCTAssertEqual(store.compactIndex, 3)
        XCTAssertEqual(store.compactSelectedIndex, 1)
        let missing = TaskStore(previewTasks: [task("missing")]).compactDots[0]
        store.selectCompactTask(dot: missing)
        XCTAssertEqual(store.compactIndex, 3)

        let onlyAssistant = TaskStore(previewTasks: [source[0]])
        onlyAssistant.testSetCompactSnapshot(snapshot)
        XCTAssertTrue(onlyAssistant.compactTasks.isEmpty)
        XCTAssertEqual(onlyAssistant.compactEmptyMessage,
                       tr("Список задач Codex может быть неполным", "The Codex task list may be incomplete"))
        XCTAssertEqual(onlyAssistant.tasks.count, 1, "The full view still has the assistant card")

        // A remembered derived title alone is not current identity evidence.
        XCTAssertEqual(CodexTaskGrouping.compactVisibleIndices([disputed], confirmedChildren: [:]), [0])
        let lost = TaskSnapshotMerger.merge(previous: [disputed], current: [], terminalIDs: [])
        XCTAssertNotEqual(lost.first?.usesDerivedCodexParentTitle, true)
        XCTAssertEqual(CodexTaskGrouping.compactVisibleIndices(lost, confirmedChildren: [:]), [0])
    }

    @MainActor
    func testAssistantIdentitySurvivesParentConflictButNotSourceLoss() {
        let child = "019127f4-35ae-7c73-9e72-a10123456780"
        let firstParent = "019127f4-35ae-7c73-9e72-a10123456789"
        let otherParent = "019127f4-35ae-7c73-9e72-a10123456788"
        let childFile = CodexFileIdentity(device: 1, inode: 10)
        var confirmedChild = task(child)
        confirmedChild.lastActivityFileIdentity = childFile
        let store = TaskStore(previewTasks: [confirmedChild])
        var snapshot = CodexTaskSnapshot()
        // No parent title or nickname is needed to establish child identity.
        snapshot.subagentParents = [child: firstParent]
        snapshot.tasks = [confirmedChild]
        snapshot.verifiedActivityFiles = [child: childFile]
        store.testSetCompactSnapshot(snapshot)
        XCTAssertEqual(store.testGroupingParent(child), firstParent)
        XCTAssertTrue(store.compactTasks.isEmpty)

        snapshot.subagentParents = [child: otherParent]
        store.testSetCompactSnapshot(snapshot)
        XCTAssertNil(store.testGroupingParent(child), "A conflicting parent must not group tasks")
        XCTAssertTrue(store.compactTasks.isEmpty, "A current child observation still identifies an assistant")
        XCTAssertEqual(store.compactEmptyMessage,
                       tr("Список задач Codex может быть неполным", "The Codex task list may be incomplete"))

        store.testSetCompactSnapshot(CodexTaskSnapshot())
        XCTAssertEqual(store.compactTasks.map(\.id), [child], "Missing current evidence must not hide the task")
        store.testSetCompactSnapshot(snapshot)
        XCTAssertTrue(store.compactTasks.isEmpty)
        store.testClearCompactSnapshot()
        XCTAssertEqual(store.compactTasks.map(\.id), [child], "A lost source clears the current child classification")
    }

    @MainActor
    func testRetainedRootIsNotHiddenByAssistantMetadataForAnotherFile() {
        let id = "019127f4-35ae-7c73-9e72-a10123456780"
        let parent = "019127f4-35ae-7c73-9e72-a10123456789"
        let rootFile = CodexFileIdentity(device: 1, inode: 10)
        let childFile = CodexFileIdentity(device: 1, inode: 11)
        var retainedRoot = task(id, title: "Root task")
        retainedRoot.lastActivityFileIdentity = rootFile
        retainedRoot.isActive = false
        retainedRoot.isUnconfirmed = true
        let store = TaskStore(previewTasks: [retainedRoot])
        var snapshot = CodexTaskSnapshot()
        snapshot.subagentParents = [id: parent]
        snapshot.verifiedActivityFiles = [id: childFile]
        store.testSetCompactSnapshot(snapshot)
        XCTAssertEqual(store.compactTasks.map(\.id), [id], "Metadata for an absent child is not a live task")

        var otherChild = task(id, title: "Assistant")
        otherChild.lastActivityFileIdentity = childFile
        snapshot.tasks = [otherChild]
        store.testSetCompactSnapshot(snapshot)
        XCTAssertEqual(store.compactTasks.map(\.id), [id], "A retained task from a different file must remain visible")
        XCTAssertEqual(store.compactTasks.first?.title, "Root task")

        let childStore = TaskStore(previewTasks: [otherChild])
        childStore.testSetCompactSnapshot(snapshot)
        XCTAssertTrue(childStore.compactTasks.isEmpty, "The matching, currently verified child remains hidden")
    }

    func testHiddenNewAssistantsDoNotStealCompactSelection() {
        var tracker = TaskFocusTracker()
        let first = task("first", start: 1)
        let second = task("second", start: 2)
        let selectable: Set<CompactTaskSelectionKey> = [first.compactSelectionKey, second.compactSelectionKey]
        _ = tracker.reconcile(current: [first, second], previous: [], selectedID: nil,
                              selectableKeys: selectable)
        let hidden = (0..<4).map { task("assistant-\($0)", start: 3 + Double($0)) }
        let result = tracker.reconcile(current: hidden + [first, second], previous: [first, second],
                                       selectedID: "second", selectableKeys: selectable)
        XCTAssertEqual(result.selectedID, "second")
        XCTAssertEqual(result.tasks.count, 6, "The full list retains its tasks")
    }

    func testHiddenAssistantWithRootIDDoesNotChangeFocusOrVisibleOrder() {
        var tracker = TaskFocusTracker()
        var root = task("same-id", start: 1)
        root.lastActivityFileIdentity = CodexFileIdentity(device: 1, inode: 10)
        let first = task("first", start: 2)
        let second = task("second", start: 3)
        let selectable: Set<CompactTaskSelectionKey> = [root.compactSelectionKey, first.compactSelectionKey,
                                                        second.compactSelectionKey]
        let original = [root, first, second]
        let initial = tracker.reconcile(current: original, previous: [], selectedID: nil, selectableKeys: selectable)
        let initialVisibleOrder = initial.tasks.filter { selectable.contains($0.compactSelectionKey) }.map(\.id)

        var hidden = task("same-id", start: 4)
        hidden.lastActivityFileIdentity = CodexFileIdentity(device: 1, inode: 11)
        hidden.startKey = "new-assistant-turn"
        let result = tracker.reconcile(current: [root, hidden, first, second], previous: original,
                                       selectedID: first.id, selectableKeys: selectable)
        XCTAssertEqual(result.selectedID, first.id)
        XCTAssertEqual(result.tasks.filter { selectable.contains($0.compactSelectionKey) }.map(\.id), initialVisibleOrder)
    }

    func testLosingStartOrFileEvidenceDoesNotStealFocus() {
        var tracker = TaskFocusTracker()
        var tracked = task("tracked", start: 1)
        tracked.lastActivityFileIdentity = CodexFileIdentity(device: 1, inode: 10)
        let selected = task("selected", start: 2)
        let initial = [tracked, selected]
        _ = tracker.reconcile(current: initial, previous: [], selectedID: nil)

        var lostStart = tracked
        lostStart.startKey = ""
        let startResult = tracker.reconcile(current: [lostStart, selected], previous: initial, selectedID: selected.id)
        XCTAssertEqual(startResult.selectedID, selected.id)

        var lostFile = tracked
        lostFile.lastActivityFileIdentity = nil
        let fileResult = tracker.reconcile(current: [lostFile, selected], previous: initial, selectedID: selected.id)
        XCTAssertEqual(fileResult.selectedID, selected.id)
    }

    @MainActor
    func testTapUsesTaskIDAfterReorderAndIgnoresRemovedTask() {
        let first = task("first")
        let second = task("second")
        let third = task("third")
        let store = TaskStore(previewTasks: [first, second, third])
        let tapped = store.compactDots[1]
        store.testReplacePreviewTasks([second, third, first])
        store.selectCompactTask(dot: tapped)
        XCTAssertEqual(store.tasks[store.compactIndex].id, second.id)

        store.testReplacePreviewTasks([third, first])
        let previouslySelected = store.compactIndex
        store.selectCompactTask(dot: tapped)
        XCTAssertEqual(store.compactIndex, previouslySelected, "A removed task must not select a different card")
    }

    @MainActor
    func testSameIDWithDifferentFilesCanBeSelectedAfterReorder() {
        let id = "019127f4-35ae-7c73-9e72-a10123456780"
        var first = task(id, title: "First")
        var second = task(id, title: "Second")
        first.lastActivityFileIdentity = CodexFileIdentity(device: 1, inode: 10)
        second.lastActivityFileIdentity = CodexFileIdentity(device: 1, inode: 11)
        let store = TaskStore(previewTasks: [first, second])
        let firstDot = store.compactDots[0]
        let secondDot = store.compactDots[1]
        XCTAssertNotEqual(firstDot.id, secondDot.id)
        store.testReplacePreviewTasks([second, first])
        store.selectCompactTask(dot: firstDot)
        XCTAssertEqual(store.tasks[store.compactIndex].title, "First")
        store.selectCompactTask(dot: secondDot)
        XCTAssertEqual(store.tasks[store.compactIndex].title, "Second")
        XCTAssertEqual(CodexTaskGrouping.compactSelectionSourceIndex([second, first], confirmedChildren: [:],
            chosenID: id, previous: first, previousVisibleIndex: 0), 1)
        var firstWithoutStart = first
        firstWithoutStart.startKey = ""
        XCTAssertEqual(CodexTaskGrouping.compactSelectionSourceIndex([second, firstWithoutStart], confirmedChildren: [:],
            chosenID: id, previous: first, previousVisibleIndex: 0), 1)
    }

    @MainActor
    func testSameKeyDotsWorkOnlyWhileTheirSnapshotIsUnchanged() {
        let first = task("same", title: "First")
        let second = task("same", title: "Second")
        let store = TaskStore(previewTasks: [first, second])
        let dots = store.compactDots
        XCTAssertNotEqual(dots[0].id, dots[1].id)
        store.selectCompactTask(dot: dots[0])
        XCTAssertEqual(store.compactIndex, 0)
        store.selectCompactTask(dot: dots[1])
        XCTAssertEqual(store.compactIndex, 1)

        store.testReplacePreviewTasks([second, first])
        let previous = store.compactIndex
        store.selectCompactTask(dot: dots[0])
        XCTAssertEqual(store.compactIndex, previous, "A stale ambiguous dot cannot select another task")
        store.selectCompactTask(dot: store.compactDots[0])
        XCTAssertEqual(store.compactIndex, 0)

        store.testReplacePreviewTasks([first, first])
        store.selectCompactTask(dot: store.compactDots[1])
        XCTAssertEqual(store.compactIndex, 1, "Even identical cards remain selectable in a stable snapshot")
    }

    func testSnapshotGenerationOnlyChangesForRelevantIdentityOrAmbiguousChanges() {
        let first = task("first")
        let second = task("second")
        var updated = first
        updated.activity = "A new action"
        XCTAssertFalse(CodexTaskGrouping.compactSnapshotChanged([first, second], [updated, second], confirmedChildren: [:]))
        XCTAssertTrue(CodexTaskGrouping.compactSnapshotChanged([first, second], [second, first], confirmedChildren: [:]))

        let duplicate = task("first", title: "Another card")
        XCTAssertTrue(CodexTaskGrouping.compactSnapshotChanged([first, duplicate], [updated, duplicate], confirmedChildren: [:]))
        XCTAssertFalse(CodexTaskGrouping.compactSnapshotChanged([first, duplicate], [first, duplicate], confirmedChildren: [:]))
    }
}
