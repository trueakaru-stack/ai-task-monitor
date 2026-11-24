import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexAgentRetentionTests: XCTestCase {
    private let root = "10000000-0000-0000-0000-000000000001"
    private let first = "10000000-0000-0000-0000-000000000002"
    private let nested = "10000000-0000-0000-0000-000000000003"
    private let other = "10000000-0000-0000-0000-000000000004"

    private func file(_ inode: UInt64) -> CodexFileIdentity { CodexFileIdentity(device: 1, inode: inode) }
    private func proof(_ inode: UInt64, _ parent: String? = nil, root: Bool = false,
                       digest: UInt8? = nil) -> CodexVerifiedAgentIdentity {
        CodexVerifiedAgentIdentity(file: file(inode), headerDigest: Data(repeating: digest ?? UInt8(inode), count: 32),
                                   parentID: parent, isRoot: root)
    }
    private func task(_ id: String, _ inode: UInt64, active: Bool = true,
                      unconfirmed: Bool = false, waiting: Bool = false, identityConfirmed: Bool = true) -> MonitoredTask {
        MonitoredTask(id: id, provider: .codex, title: "Synthetic task", activity: "Synthetic activity",
                      isActive: active, progress: nil, progressKind: .none, steps: [], updatedAt: .distantPast,
                      isUnconfirmed: unconfirmed, isWaiting: waiting, startKey: "turn-1",
                      lastActivityIdentityConfirmed: identityConfirmed, lastActivityFileIdentity: file(inode))
    }
    private func nodes() -> [String: CodexVerifiedAgentIdentity] {
        [root: proof(1, root: true), first: proof(2, root), nested: proof(3, first)]
    }
    private func group(_ result: CodexAgentRetention.Snapshot, file: StaticString = #filePath,
                       line: UInt = #line) throws -> CodexAgentRetention.Group {
        XCTAssertEqual(result.groups.count, 1, file: file, line: line)
        return try XCTUnwrap(result.groups.first, file: file, line: line)
    }
    private func member(_ group: CodexAgentRetention.Group, _ id: String, file: StaticString = #filePath,
                        line: UInt = #line) throws -> CodexAgentRetention.Member {
        let matches = group.members.filter { $0.id == id }
        XCTAssertEqual(matches.count, 1, file: file, line: line)
        return try XCTUnwrap(matches.first, file: file, line: line)
    }

    func testVerifiedChainRetainsMissingAgentAndCompletedTurn() throws {
        var retention = CodexAgentRetention()
        let rootTask = task(root, 1), nestedTask = task(nested, 3)
        let initial = try group(retention.observe(tasks: [rootTask, nestedTask], identities: nodes()))
        XCTAssertEqual(initial.rootID, root)
        XCTAssertEqual(initial.knownCount, 2, "The verified intermediate is an observed agent too")
        XCTAssertTrue(initial.canAttach)
        XCTAssertTrue(initial.countUnconfirmed && initial.coverageUnconfirmed && initial.closureUnconfirmed && initial.continuityUnconfirmed)
        XCTAssertTrue(try member(initial, nested).current)
        XCTAssertTrue(try member(initial, nested).active)
        XCTAssertFalse(try member(initial, first).current)
        XCTAssertTrue(try member(initial, first).statusUnconfirmed)

        var newTurn = nestedTask
        newTurn.startKey = "another-turn"
        let sameTask = try group(retention.observe(tasks: [rootTask, newTurn], identities: nodes()))
        XCTAssertEqual(sameTask.knownCount, 2)
        XCTAssertTrue(try member(sameTask, nested).current)

        let missing = try group(retention.observe(tasks: [rootTask], identities: [:], sourcePartial: true))
        XCTAssertEqual(missing.knownCount, 2)
        XCTAssertFalse(missing.canAttach, "A root card without current proof must not receive a count")
        XCTAssertFalse(try member(missing, nested).current)
        XCTAssertTrue(try member(missing, nested).statusUnconfirmed)

        let failed = try group(retention.observe(tasks: [rootTask, nestedTask], identities: nodes(), sourceUnavailable: true))
        XCTAssertEqual(failed.knownCount, 2)
        XCTAssertFalse(failed.canAttach)
        XCTAssertFalse(try member(failed, nested).current)
        let recovered = try group(retention.observe(tasks: [rootTask, nestedTask], identities: nodes()))
        XCTAssertEqual(recovered.knownCount, 2)
        XCTAssertTrue(try member(recovered, nested).current)
        XCTAssertTrue(recovered.continuityUnconfirmed, "The same file/header does not prove uninterrupted lifetime")

        let turnEnded = task(nested, 3, active: false)
        let ended = try group(retention.observe(tasks: [rootTask, turnEnded], identities: nodes()))
        XCTAssertEqual(ended.knownCount, 2)
        XCTAssertFalse(try member(ended, nested).current)
        XCTAssertTrue(try member(ended, nested).statusUnconfirmed)
        let noVisibleTask = try group(retention.observe(tasks: [], identities: [:], sourcePartial: true))
        XCTAssertEqual(noVisibleTask.knownCount, 2)
        XCTAssertFalse(noVisibleTask.canAttach)
    }

    func testRootCardNeedsItsOwnConfirmedIdentityAndMissingRootCanUseChild() throws {
        var retention = CodexAgentRetention()
        let nestedTask = task(nested, 3)
        _ = retention.observe(tasks: [task(root, 1), nestedTask], identities: nodes())
        let unverifiedRoot = task(root, 1, identityConfirmed: false)
        let uncertain = try group(retention.observe(tasks: [unverifiedRoot, nestedTask], identities: nodes()))
        XCTAssertEqual(uncertain.knownCount, 2)
        XCTAssertFalse(uncertain.canAttach)
        let rootAbsent = try group(retention.observe(tasks: [nestedTask], identities: nodes()))
        XCTAssertEqual(rootAbsent.knownCount, 2)
        XCTAssertTrue(rootAbsent.canAttach)
        XCTAssertTrue(try member(rootAbsent, nested).current)
    }

    func testSameRetainedRootCanCarryCountAcrossSourceLoss() throws {
        var retention = CodexAgentRetention()
        let original = task(root, 1), child = task(nested, 3)
        let initial = try group(retention.observe(tasks: [original, child], identities: nodes()))
        let binding = try XCTUnwrap(initial.rootBinding)
        var carried = original
        carried.isActive = false
        carried.isUnconfirmed = true
        carried.lastActivityIdentityConfirmed = false

        let outage = try group(retention.observe(tasks: [carried], identities: [:], sourceUnavailable: true,
                                                  retainedRootBindings: [root: binding]))
        XCTAssertTrue(outage.canAttach)
        XCTAssertTrue(outage.rootCardRetained)
        XCTAssertEqual(outage.knownCount, 2)
        XCTAssertTrue(outage.members.allSatisfy { !$0.current && $0.statusUnconfirmed })
        XCTAssertTrue(outage.countUnconfirmed && outage.coverageUnconfirmed && outage.closureUnconfirmed)

        let missingFreshProof = try group(retention.observe(tasks: [carried], identities: [:], sourcePartial: true,
                                                            retainedRootBindings: [root: binding]))
        XCTAssertTrue(missingFreshProof.canAttach)
        XCTAssertTrue(missingFreshProof.rootCardRetained)
        let withoutProvenance = try group(retention.observe(tasks: [carried], identities: [:], sourceUnavailable: true))
        XCTAssertFalse(withoutProvenance.canAttach)

        var newTurn = carried
        newTurn.startKey = "other-turn"
        let wrongTurn = try group(retention.observe(tasks: [newTurn], identities: [:], sourceUnavailable: true,
                                                    retainedRootBindings: [root: binding]))
        XCTAssertFalse(wrongTurn.canAttach)
        var wrongFile = carried
        wrongFile.lastActivityFileIdentity = file(9)
        let wrongIdentity = try group(retention.observe(tasks: [wrongFile], identities: [:], sourceUnavailable: true,
                                                         retainedRootBindings: [root: binding]))
        XCTAssertFalse(wrongIdentity.canAttach)
        var activeCard = carried
        activeCard.isActive = true
        let notRetained = try group(retention.observe(tasks: [activeCard], identities: [:], sourceUnavailable: true,
                                                       retainedRootBindings: [root: binding]))
        XCTAssertFalse(notRetained.canAttach)
        let contradiction = try group(retention.observe(tasks: [carried], identities: [:], sourceUnavailable: true,
                                                        conflictedIDs: [root], retainedRootBindings: [root: binding]))
        XCTAssertFalse(contradiction.canAttach)
        XCTAssertTrue(contradiction.conflictIDs.contains(root))
    }

    func testFreshIdentityProofRequiredAndPendingProofCanRecover() throws {
        var retention = CodexAgentRetention()
        let noProof = retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: [:])
        XCTAssertTrue(noProof.groups.isEmpty)
        XCTAssertTrue(noProof.missingIdentityIDs.contains(nested))
        var incomplete = nodes()
        incomplete.removeValue(forKey: first)
        let missingParent = retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: incomplete)
        XCTAssertTrue(missingParent.groups.isEmpty)
        XCTAssertTrue(missingParent.missingIdentityIDs.contains(first))
        var shortDigest = nodes()
        shortDigest[nested] = CodexVerifiedAgentIdentity(file: file(3), headerDigest: Data([1]), parentID: first, isRoot: false)
        let invalidDigest = retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: shortDigest)
        XCTAssertTrue(invalidDigest.groups.isEmpty)
        XCTAssertTrue(invalidDigest.missingIdentityIDs.contains(nested))
        let accepted = try group(retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes()))
        XCTAssertEqual(accepted.knownCount, 2)
        let pending = try group(retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes(),
                                                  conflictedIDs: [first]))
        XCTAssertEqual(pending.knownCount, 2)
        XCTAssertFalse(pending.canAttach)
        XCTAssertTrue(pending.conflictIDs.contains(first))
        let restored = try group(retention.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes()))
        XCTAssertTrue(restored.canAttach)
    }

    func testFileDigestParentAndRootConflictsPreserveOldEvidence() throws {
        var changedFile = CodexAgentRetention()
        _ = changedFile.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes())
        var replacement = nodes(); replacement[nested] = proof(4, first)
        let fileConflict = changedFile.observe(tasks: [task(root, 1), task(nested, 4)], identities: replacement)
        let firstGroup = try group(fileConflict)
        XCTAssertEqual(firstGroup.knownCount, 2)
        XCTAssertFalse(firstGroup.canAttach)
        XCTAssertTrue(fileConflict.conflictIDs.contains(nested))
        XCTAssertEqual(try member(firstGroup, nested).identity.file, file(3))

        var changedDigest = CodexAgentRetention()
        _ = changedDigest.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes())
        var rewritten = nodes(); rewritten[nested] = proof(3, first, digest: 99)
        let digestConflict = changedDigest.observe(tasks: [task(root, 1), task(nested, 3)], identities: rewritten)
        XCTAssertTrue(digestConflict.conflictIDs.contains(nested))
        XCTAssertFalse(try group(digestConflict).canAttach)

        var changedParent = CodexAgentRetention()
        _ = changedParent.observe(tasks: [task(root, 1), task(first, 2)], identities: nodes())
        var moved = nodes(); moved[first] = proof(2, other)
        let parentConflict = changedParent.observe(tasks: [task(root, 1), task(first, 2)], identities: moved)
        let parentGroup = try group(parentConflict)
        XCTAssertEqual(parentGroup.knownCount, 1)
        XCTAssertEqual(try member(parentGroup, first).parentID, root)
        XCTAssertTrue(parentConflict.conflictIDs.contains(first))
        XCTAssertFalse(parentGroup.canAttach)

        var changedRoot = CodexAgentRetention()
        _ = changedRoot.observe(tasks: [task(root, 1), task(first, 2)], identities: nodes())
        var newRoot = nodes(); newRoot[root] = proof(4, root: true)
        let rootConflict = changedRoot.observe(tasks: [task(root, 4), task(first, 2)], identities: newRoot)
        XCTAssertTrue(rootConflict.conflictIDs.contains(root))
        XCTAssertEqual(try group(rootConflict).knownCount, 1)
        XCTAssertFalse(try group(rootConflict).canAttach)
    }

    func testDuplicateAndSharedFileCannotCreateAnAgent() {
        var duplicate = CodexAgentRetention()
        let child = task(first, 2)
        let duplicated = duplicate.observe(tasks: [task(root, 1), child, child], identities: nodes())
        XCTAssertTrue(duplicated.groups.isEmpty)
        XCTAssertTrue(duplicated.conflictIDs.contains(first))

        var shared = CodexAgentRetention()
        let sameFile: [String: CodexVerifiedAgentIdentity] = [root: proof(1, root: true), first: proof(1, root)]
        let collision = shared.observe(tasks: [task(root, 1), task(first, 1)], identities: sameFile)
        XCTAssertTrue(collision.groups.isEmpty)
        XCTAssertTrue(collision.conflictIDs.contains(root))
        XCTAssertTrue(collision.conflictIDs.contains(first))
    }

    func testCapacityNeverDiscardsEarlierEvidence() throws {
        var tooSmall = CodexAgentRetention(maximumAgents: 1, maximumRoots: 1)
        let tooDeep = tooSmall.observe(tasks: [task(root, 1), task(nested, 3)], identities: nodes())
        XCTAssertTrue(tooDeep.groups.isEmpty)
        XCTAssertTrue(tooDeep.capacityExceeded)

        var full = CodexAgentRetention(maximumAgents: 1, maximumRoots: 1)
        _ = full.observe(tasks: [task(root, 1), task(first, 2)], identities: nodes())
        let over = full.observe(tasks: [task(root, 1), task(first, 2), task(nested, 3)], identities: nodes())
        XCTAssertTrue(over.capacityExceeded)
        XCTAssertEqual(try group(over).knownCount, 1)
    }
}
