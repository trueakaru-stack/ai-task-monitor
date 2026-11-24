import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexRetainedProjectionTests: XCTestCase {
    private let root = "10000000-0000-0000-0000-000000000001"
    private let child = "20000000-0000-0000-0000-000000000001"

    private func identity(_ inode: UInt64, parent: String? = nil, root: Bool = false) -> CodexVerifiedAgentIdentity {
        CodexVerifiedAgentIdentity(file: CodexFileIdentity(device: 1, inode: inode),
                                   headerDigest: Data(repeating: UInt8(inode), count: 32),
                                   parentID: parent, isRoot: root)
    }

    private func task(_ id: String, inode: UInt64) -> MonitoredTask {
        MonitoredTask(id: id, provider: .codex, title: id, activity: "Synthetic activity", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: "turn",
                      lastActivityIdentityConfirmed: true,
                      lastActivityFileIdentity: CodexFileIdentity(device: 1, inode: inode))
    }

    func testKnownCountSurvivesMissingChildWithSeparateUncertainty() throws {
        let parent = task(root, inode: 1), assistant = task(child, inode: 2)
        let parentProof = identity(1, root: true), childProof = identity(2, parent: root)
        var retention = CodexAgentRetention()
        let first = retention.observe(tasks: [parent, assistant], identities: [root: parentProof, child: childProof])
        let firstGroup = try XCTUnwrap(first.groups.first)
        let shown = CodexTaskGrouping.makeRetainedProjection([parent, assistant], groups: first.groups, titles: [:])
        XCTAssertEqual(shown.tasks.count, 1)
        let task = try XCTUnwrap(shown.tasks.first)
        XCTAssertEqual(task.codexAgentCount, 1)
        XCTAssertEqual(task.codexAgentCountUnconfirmed, true)
        XCTAssertEqual(task.codexAgentsUnconfirmed, false)
        XCTAssertEqual(task.codexAgents?.first?.activity, assistant.activity)
        XCTAssertEqual(shown.displayIDBySourceID[child], root)
        let token = try XCTUnwrap(firstGroup.rootBinding)

        let missing = retention.observe(tasks: [parent], identities: [root: parentProof], sourcePartial: true)
        let missingProjection = CodexTaskGrouping.makeRetainedProjection([parent], groups: missing.groups, titles: [:])
        let retained = try XCTUnwrap(missingProjection.tasks.first)
        XCTAssertEqual(retained.codexAgentCount, 1)
        XCTAssertEqual(retained.codexAgentCountUnconfirmed, true)
        XCTAssertEqual(retained.codexAgentsUnconfirmed, true)
        XCTAssertEqual(retained.codexAgents?.first?.isUnconfirmed, true)

        var carriedChild = assistant
        carriedChild.isActive = false
        carriedChild.isUnconfirmed = true
        carriedChild.lastActivityIdentityConfirmed = false
        let withCarriedChild = retention.observe(tasks: [parent, carriedChild], identities: [root: parentProof], sourcePartial: true)
        let childBinding = CodexRetainedAgentCard(file: childProof.file, startKey: assistant.startKey)
        let grouped = CodexTaskGrouping.makeRetainedProjection([parent, carriedChild], groups: withCarriedChild.groups,
                                                               titles: [:], retainedCards: [child: childBinding])
        XCTAssertEqual(grouped.tasks.count, 1)
        XCTAssertEqual(grouped.tasks.first?.codexAgentCount, 1)
        XCTAssertEqual(grouped.tasks.first?.codexAgents?.first?.isUnconfirmed, true)
        var differentTurn = carriedChild
        differentTurn.startKey = "different-turn"
        let separate = CodexTaskGrouping.makeRetainedProjection([parent, differentTurn], groups: withCarriedChild.groups,
                                                                titles: [:], retainedCards: [child: childBinding])
        XCTAssertEqual(separate.tasks.count, 2, "A new or ambiguous card must not inherit old provenance")

        var carried = parent
        carried.isActive = false
        carried.isUnconfirmed = true
        carried.lastActivityIdentityConfirmed = false
        let unavailable = retention.observe(tasks: [carried], identities: [:], sourceUnavailable: true,
                                            retainedRootBindings: [root: token])
        let carriedProjection = CodexTaskGrouping.makeRetainedProjection([carried], groups: unavailable.groups, titles: [:])
        XCTAssertEqual(carriedProjection.tasks.first?.codexAgentCount, 1)
        XCTAssertEqual(carriedProjection.tasks.first?.codexAgentCountUnconfirmed, true)
        XCTAssertEqual(carriedProjection.tasks.first?.codexAgentsUnconfirmed, true)
    }

    func testConflictingIdentityDoesNotHideOrAttachAnotherTask() throws {
        let parent = task(root, inode: 1), assistant = task(child, inode: 2)
        var retention = CodexAgentRetention()
        _ = retention.observe(tasks: [parent, assistant], identities: [root: identity(1, root: true), child: identity(2, parent: root)])
        let replacement = task(child, inode: 3)
        let conflicted = retention.observe(tasks: [parent, replacement],
            identities: [root: identity(1, root: true), child: identity(3, parent: root)])
        let result = CodexTaskGrouping.makeRetainedProjection([parent, replacement], groups: conflicted.groups, titles: [:])
        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertTrue(result.tasks.contains { $0.id == child })
        XCTAssertNil(result.tasks.first { $0.id == root }?.codexAgentCount)
        XCTAssertNil(result.displayIDBySourceID[child])
    }

    func testMissingFreshRootProofKeepsOldCountSeparatelyUntilRecovery() throws {
        let parent = task(root, inode: 1), assistant = task(child, inode: 2)
        let rootProof = identity(1, root: true), childProof = identity(2, parent: root)
        var retention = CodexAgentRetention()
        _ = retention.observe(tasks: [parent, assistant], identities: [root: rootProof, child: childProof])
        let missing = retention.observe(tasks: [parent, assistant], identities: [child: childProof], sourcePartial: true)
        XCTAssertFalse(try XCTUnwrap(missing.groups.first).canAttach)
        let shown = CodexTaskGrouping.makeRetainedProjection([parent, assistant], groups: missing.groups,
                                                              titles: [:], fallbackRoots: [root: parent])
        let held = try XCTUnwrap(shown.tasks.first { $0.id == "codex-retained:" + root })
        XCTAssertTrue(held.isUnconfirmed)
        XCTAssertEqual(held.codexAgentCount, 1)
        XCTAssertEqual(held.codexAgentCountUnconfirmed, true)
        XCTAssertEqual(held.codexAgentsUnconfirmed, true)
        XCTAssertTrue(shown.tasks.contains { $0.id == root }, "The newly unverified root remains separate")

        let restored = retention.observe(tasks: [parent, assistant], identities: [root: rootProof, child: childProof])
        let recovered = CodexTaskGrouping.makeRetainedProjection([parent, assistant], groups: restored.groups,
                                                                  titles: [:], fallbackRoots: [root: parent])
        XCTAssertEqual(recovered.tasks.count, 1)
        XCTAssertEqual(recovered.tasks.first?.id, root)
        XCTAssertEqual(recovered.tasks.first?.codexAgentCount, 1)
        XCTAssertEqual(recovered.displayIDBySourceID["codex-retained:" + root], root)
    }
}
