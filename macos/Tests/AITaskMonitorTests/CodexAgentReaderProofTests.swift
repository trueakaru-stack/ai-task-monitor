import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

final class CodexAgentReaderProofTests: XCTestCase {
    func testRevalidationDoesNotCombineChangedAgentEvidence() {
        let root = "019127f4-35ae-7c73-9e72-a10123456789"
        let child = "019127f4-35ae-7c73-9e72-a10123456780"
        let next = "019127f4-35ae-7c73-9e72-a10123456781"
        let rootProof = CodexVerifiedAgentIdentity(file: CodexFileIdentity(device: 1, inode: 1),
            headerDigest: Data(repeating: 1, count: 32), parentID: nil, isRoot: true)
        let childProof = CodexVerifiedAgentIdentity(file: CodexFileIdentity(device: 1, inode: 2),
            headerDigest: Data(repeating: 2, count: 32), parentID: root, isRoot: false)
        let changedProof = CodexVerifiedAgentIdentity(file: CodexFileIdentity(device: 1, inode: 2),
            headerDigest: Data(repeating: 3, count: 32), parentID: root, isRoot: false)
        let nextProof = CodexVerifiedAgentIdentity(file: CodexFileIdentity(device: 1, inode: 3),
            headerDigest: Data(repeating: 4, count: 32), parentID: root, isRoot: false)
        var earlier = CodexTaskSnapshot()
        earlier.verifiedAgentIdentities = [root: rootProof, child: childProof]
        var later = earlier
        later.verifiedAgentIdentities = [root: rootProof, child: changedProof, next: nextProof]
        XCTAssertTrue(earlier.agreesWith(later), "Task-state agreement must not silently merge different proof slices")
        let safe = later.revalidatingAgentEvidence(against: earlier)
        XCTAssertEqual(safe.verifiedAgentIdentities, [root: rootProof])
        XCTAssertTrue(safe.agentIdentityPartial)
        XCTAssertNil(safe.verifiedAgentIdentities[child])
        XCTAssertNil(safe.verifiedAgentIdentities[next])

        let unchanged = earlier.revalidatingAgentEvidence(against: earlier)
        XCTAssertEqual(unchanged.verifiedAgentIdentities, earlier.verifiedAgentIdentities)
        XCTAssertFalse(unchanged.agentIdentityPartial)
        later = earlier
        later.agentIdentityPartial = true
        XCTAssertTrue(later.revalidatingAgentEvidence(against: earlier).agentIdentityPartial)
        XCTAssertTrue(earlier.revalidatingAgentEvidence(against: later).agentIdentityPartial)
    }

    private let rootID = "10000000-0000-0000-0000-000000000001"

    private final class MetadataGate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false
        private var blocked = false
        func arm() { lock.lock(); armed = true; lock.unlock() }
        func pause(_ id: String, target: String) {
            lock.lock()
            let shouldWait = armed && !blocked && id == target
            if shouldWait { blocked = true }
            lock.unlock()
            guard shouldWait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    private final class RevalidationGate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false
        private var selections: [Set<String>] = []
        func arm() { lock.lock(); armed = true; selections = []; lock.unlock() }
        func observe(_ snapshot: CodexTaskSnapshot) {
            lock.lock()
            let shouldRecord = armed
            if shouldRecord { selections.append(snapshot.selectedAgentProofIDs) }
            let shouldWait = shouldRecord && selections.count == 1
            lock.unlock()
            if shouldWait { entered.signal(); _ = release.wait(timeout: .now() + 12) }
        }
        var recorded: [Set<String>] { lock.lock(); defer { lock.unlock() }; return selections }
    }

    private final class Mutation {
        private let lock = NSLock()
        private var action: (() throws -> Void)?
        private(set) var performed = false
        private(set) var failure: Error?
        func schedule(_ action: @escaping () throws -> Void) {
            lock.lock(); self.action = action; lock.unlock()
        }
        func run() {
            lock.lock(); let next = action; action = nil; lock.unlock()
            guard let next else { return }
            do { try next(); lock.lock(); performed = true; lock.unlock() }
            catch { lock.lock(); performed = true; failure = error; lock.unlock() }
        }
        func result() -> (Bool, Error?) { lock.lock(); defer { lock.unlock() }; return (performed, failure) }
    }

    private func childID(_ index: Int) -> String {
        String(format: "20000000-0000-0000-0000-%012d", index)
    }

    private func rollout(_ directory: URL, id: String, parent: String?, suffix: String = "01",
                         startOffset: TimeInterval = 0) throws -> URL {
        let folder = directory.appendingPathComponent("sessions/2026/11/24", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("rollout-2026-11-24T00-00-\(suffix)-\(id).jsonl")
        let payload: [String: Any]
        if let parent {
            let path = "/root/child"
            payload = ["id": id, "thread_source": "subagent", "parent_thread_id": parent, "agent_path": path,
                       "source": ["subagent": ["thread_spawn": ["parent_thread_id": parent, "agent_path": path]]]]
        } else {
            payload = ["id": id, "thread_source": "user", "source": "cli", "agent_path": "/root"]
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started: [String: Any] = ["timestamp": formatter.string(from: Date().addingTimeInterval(startOffset)), "type": "event_msg",
                                      "payload": ["type": "task_started", "turn_id": "synthetic-turn"]]
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload], options: [.sortedKeys])
        data.append(10)
        data.append(try JSONSerialization.data(withJSONObject: started, options: [.sortedKeys]))
        data.append(10)
        try data.write(to: file)
        return file
    }

    private func fixture(children: Int) throws -> (URL, [String], [String: URL]) {
        let root = try codexSyntheticDirectory(prefix: "aitm-agent-proof-")
        let ids = (0..<children).map(childID)
        var files: [String: URL] = [:]
        files[rootID] = try rollout(root, id: rootID, parent: nil)
        for id in ids { files[id] = try rollout(root, id: id, parent: rootID) }
        var index = Data()
        for id in [rootID] + ids {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic task"], options: [.sortedKeys]))
            index.append(10)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        return (root, ids, files)
    }

    private func awaitProof(_ reader: CodexTaskReader, id: String) throws -> CodexTaskSnapshot {
        var latest = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        for _ in 0..<30 {
            if latest.verifiedAgentIdentities[id] != nil && latest.verifiedAgentIdentities[rootID] != nil { return latest }
            reader.waitForAmbiguousObservationForTests()
            latest = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        }
        XCTFail("The synthetic complete chain was never verified")
        return latest
    }

    @MainActor
    func testSlowTaskStoreRechecksVisibleGroupsWithoutStarvingRotation() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-proof-groups-")
        let secondRoot = "10000000-0000-0000-0000-000000000002"
        let ids = (0..<40).map(childID)
        var files: [String: URL] = [:]
        for (index, id) in ids.enumerated() {
            files[id] = try rollout(root, id: id, parent: index < 20 ? rootID : secondRoot, startOffset: 30)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(35)], ofItemAtPath: files[id]!.path)
        }
        for id in [rootID, secondRoot] {
            files[id] = try rollout(root, id: id, parent: nil, startOffset: 30)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(40)], ofItemAtPath: files[id]!.path)
        }
        var index = Data()
        for id in [rootID, secondRoot] + ids {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic task"], options: [.sortedKeys]))
            index.append(10)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        let gate = RevalidationGate()
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { gate.observe($0) })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        defer {
            gate.release.signal()
            waitForCodexRead(store, timeout: 8)
            try? FileManager.default.removeItem(at: root)
        }
        var ready = false
        for _ in 0..<30 {
            store.refresh()
            waitForCodexRead(store, timeout: 8)
            let groups = store.tasks.filter { $0.id == rootID || $0.id == secondRoot }
            if groups.contains(where: { $0.id == rootID && ($0.codexAgentCount ?? 0) > 0 }) &&
                groups.contains(where: { $0.id == secondRoot && ($0.codexAgentCount ?? 0) > 0 }) &&
                !store.tasks.contains(where: { $0.id == "codex-retained:" + rootID || $0.id == "codex-retained:" + secondRoot }) {
                ready = true
                break
            }
            reader.waitForAmbiguousObservationForTests()
        }
        XCTAssertTrue(ready, "Both parent groups need fresh proof before testing the transition")
        guard ready else { return }
        reader.waitForAmbiguousObservationForTests()
        let target = try XCTUnwrap(store.compactDots.first { $0.task.id == rootID || $0.task.id == secondRoot })
        gate.arm()
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        store.selectCompactTask(dot: target)
        let selected = store.compactTasks[store.compactSelectedIndex].id
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        gate.release.signal()
        waitForCodexRead(store, timeout: 8)
        let selections = gate.recorded
        XCTAssertGreaterThanOrEqual(selections.count, 2)
        if selections.count >= 2 { XCTAssertEqual(selections[0], selections[1]) }
        XCTAssertEqual(store.compactTasks[store.compactSelectedIndex].id, selected)
        for parent in [rootID, secondRoot] {
            XCTAssertEqual(store.tasks.filter { $0.id == parent }.count, 1)
            XCTAssertFalse(store.tasks.contains { $0.id == "codex-retained:" + parent })
        }
        if let last = selections.last {
            let provenChildren = last.intersection(Set(ids))
            XCTAssertFalse(provenChildren.isEmpty)
            XCTAssertTrue(store.compactTasks.allSatisfy { !provenChildren.contains($0.id) },
                          "A child with matching current proof must not become a separate compact card")
        }
    }

    @MainActor
    func testChangedHeaderBetweenSlowReadsCannotHideIndependentTask() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-proof-changed-")
        let child = childID(0)
        let parentFile = try rollout(root, id: rootID, parent: nil, startOffset: 30)
        let childFile = try rollout(root, id: child, parent: rootID, startOffset: 30)
        for file in [parentFile, childFile] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(35)], ofItemAtPath: file.path)
        }
        var index = Data()
        for id in [rootID, child] {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic task"], options: [.sortedKeys]))
            index.append(10)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        let gate = RevalidationGate()
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { gate.observe($0) })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        defer {
            gate.release.signal()
            waitForCodexRead(store, timeout: 8)
            try? FileManager.default.removeItem(at: root)
        }
        var ready = false
        for _ in 0..<20 {
            store.refresh()
            waitForCodexRead(store, timeout: 8)
            if store.tasks.contains(where: { $0.id == rootID && ($0.codexAgentCount ?? 0) == 1 }) &&
                !store.compactTasks.contains(where: { $0.id == child }) {
                ready = true
                break
            }
            reader.waitForAmbiguousObservationForTests()
        }
        XCTAssertTrue(ready)
        guard ready else { return }
        reader.waitForAmbiguousObservationForTests()
        var before = stat()
        XCTAssertEqual(childFile.path.withCString { lstat($0, &before) }, 0)
        gate.arm()
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": child, "source": "cli", "thread_source": "user", "agent_path": "/root"]],
            ["timestamp": formatter.string(from: Date().addingTimeInterval(30)), "type": "event_msg",
             "payload": ["type": "task_started", "turn_id": "new-independent-turn"]]
        ]
        var replacement = Data()
        for row in rows {
            replacement.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            replacement.append(10)
        }
        let handle = try FileHandle(forUpdating: childFile)
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement); try handle.close()
        var after = stat()
        XCTAssertEqual(childFile.path.withCString { lstat($0, &after) }, 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        gate.release.signal()
        waitForCodexRead(store, timeout: 8)
        XCTAssertTrue(store.compactTasks.contains { $0.id == child && $0.isUnconfirmed },
                      "The changed same-inode header may be an independent task and must remain visible")
        XCTAssertFalse(store.tasks.contains { task in
            task.id == rootID && (task.codexAgents ?? []).contains { $0.id == child && $0.isActive }
        })
    }

    func testOneSnapshotProvesChildAndRootWithoutExposingHeader() throws {
        let (root, ids, _) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        let snapshot = try awaitProof(reader, id: ids[0])
        let child = try XCTUnwrap(snapshot.verifiedAgentIdentities[ids[0]])
        let parent = try XCTUnwrap(snapshot.verifiedAgentIdentities[rootID])
        XCTAssertEqual(child.parentID, rootID)
        XCTAssertFalse(child.isRoot)
        XCTAssertEqual(child.headerDigest.count, 32)
        XCTAssertTrue(parent.isRoot)
        XCTAssertNil(parent.parentID)
        var retention = CodexAgentRetention()
        let grouped = retention.observe(tasks: snapshot.tasks, identities: snapshot.verifiedAgentIdentities,
                                        sourcePartial: snapshot.agentIdentityPartial)
        XCTAssertEqual(grouped.groups.first?.knownCount, 1)
    }

    func testAmbiguousRootCannotProveAnyChildChain() throws {
        let (root, ids, _) = try fixture(children: 2)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        _ = try awaitProof(reader, id: ids[0])
        let before = try awaitProof(reader, id: ids[1])
        let rootProof = try XCTUnwrap(before.verifiedAgentIdentities[rootID])
        let firstProof = try XCTUnwrap(before.verifiedAgentIdentities[ids[0]])
        let secondProof = try XCTUnwrap(before.verifiedAgentIdentities[ids[1]])
        var retained = CodexAgentRetention()
        let initial = retained.observe(tasks: before.tasks,
            identities: [rootID: rootProof, ids[0]: firstProof], sourcePartial: true)
        XCTAssertEqual(initial.groups.first?.knownCount, 1)
        _ = try rollout(root, id: rootID, parent: nil, suffix: "02")
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60),
                                               previouslyObserved: Set([rootID] + ids))
        XCTAssertNil(snapshot.verifiedAgentIdentities[rootID])
        let first = try XCTUnwrap(snapshot.verifiedAgentIdentities[ids[0]])
        let second = try XCTUnwrap(snapshot.verifiedAgentIdentities[ids[1]])
        XCTAssertEqual(first, firstProof)
        XCTAssertEqual(second, secondProof)
        XCTAssertEqual(first.parentID, rootID)
        XCTAssertFalse(first.isRoot)
        XCTAssertEqual(second.parentID, rootID)
        XCTAssertFalse(second.isRoot)
        XCTAssertTrue(snapshot.agentIdentityPartial)

        var fresh = CodexAgentRetention()
        let unlinked = fresh.observe(tasks: snapshot.tasks, identities: snapshot.verifiedAgentIdentities,
                                     sourcePartial: snapshot.agentIdentityPartial)
        XCTAssertTrue(unlinked.groups.isEmpty, "A child header alone must not create a parent group")

        let previous = retained.observe(tasks: snapshot.tasks, identities: snapshot.verifiedAgentIdentities,
                                        sourcePartial: snapshot.agentIdentityPartial)
        let group = try XCTUnwrap(previous.groups.first)
        XCTAssertEqual(previous.groups.count, 1)
        XCTAssertEqual(group.knownCount, 1, "An unlinked child must not increase the retained count")
        XCTAssertEqual(group.members.map(\.id), [ids[0]])
        XCTAssertTrue(group.countUnconfirmed)
        XCTAssertFalse(group.canAttach)
        XCTAssertTrue(group.members.allSatisfy { !$0.current && !$0.active && $0.statusUnconfirmed })
    }

    func testAppendAfterTaskSnapshotCannotUseCachedHeaderAsProof() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(files[ids[0]])
        var armed = false
        var injected = false
        var writeError: Error?
        let reader = CodexTaskReader(codexHome: root, afterAgentProofSelectionForTests: {
            guard armed, !injected else { return }
            injected = true
            do {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("{\"type\":\"synthetic_tail\"}\n".utf8))
            } catch { writeError = error }
        })
        _ = try awaitProof(reader, id: ids[0])
        armed = true
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(injected)
        XCTAssertNil(writeError)
        XCTAssertNil(snapshot.verifiedAgentIdentities[ids[0]])
        XCTAssertTrue(snapshot.agentIdentityPartial)
    }

    func testRewrittenHeaderOnSameInodeCannotUseOldLink() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(files[ids[0]])
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        var armed = false
        var injected = false
        var writeError: Error?
        let reader = CodexTaskReader(codexHome: root, afterAgentProofSelectionForTests: {
            guard armed, !injected else { return }
            injected = true
            do {
                let original = try String(contentsOf: file, encoding: .utf8)
                let replacement = original.replacingOccurrences(of: self.rootID, with: self.childID(99))
                guard replacement != original else { throw CocoaError(.fileWriteUnknown) }
                let handle = try FileHandle(forUpdating: file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data(replacement.utf8))
            } catch { writeError = error }
        })
        _ = try awaitProof(reader, id: ids[0])
        armed = true
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertTrue(injected)
        XCTAssertNil(writeError)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertNil(snapshot.verifiedAgentIdentities[ids[0]])
        XCTAssertTrue(snapshot.agentIdentityPartial)
    }

    @MainActor
    func testChildRewrittenAsRootCannotBeHiddenByStaleCachedMetadata() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(files[ids[0]])
        let gate = MetadataGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, beforeSubagentMetadataLoadForTests: { id in
            gate.pause(id, target: ids[0])
        })
        _ = try awaitProof(reader, id: ids[0])
        reader.waitForAmbiguousObservationForTests()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let header: [String: Any] = ["type": "session_meta", "payload":
            ["id": ids[0], "source": "cli", "thread_source": "user", "agent_path": "/root"]]
        let start: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
                                    "payload": ["type": "task_started", "turn_id": "new-root"]]
        let filler: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
                                     "payload": ["type": "agent_reasoning", "text": String(repeating: "x", count: 2_048)]]
        var data = Data()
        for row in [header, start, filler] {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10)
        }
        let handle = try FileHandle(forUpdating: file)
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data); try handle.close()
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertGreaterThan((after[.size] as? NSNumber)?.intValue ?? 0, (before[.size] as? NSNumber)?.intValue ?? 0)
        gate.arm()
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60),
                                               previouslyObserved: Set([rootID] + ids))
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(snapshot.subagentParents[ids[0]], rootID, "The old cached link must be present in this interleaving")
        XCTAssertNil(snapshot.verifiedAgentIdentities[ids[0]], "A stale link is not a fresh child proof")
        let store = TaskStore(codexReader: reader, claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                              previewTasks: snapshot.tasks)
        store.testSetCompactSnapshot(snapshot)
        XCTAssertTrue(store.compactTasks.contains { $0.id == ids[0] }, "The rewritten root must remain visible")
        gate.release.signal()
        reader.waitForAmbiguousObservationForTests()
    }

    func testRewrittenTaskWithSameHeaderSizeAndMtimeCannotUseOldSnapshot() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(files[ids[0]])
        var before = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &before) }, 0)
        var armed = false
        var injected = false
        var writeError: Error?
        let reader = CodexTaskReader(codexHome: root, afterAgentProofSelectionForTests: {
            guard armed, !injected else { return }
            injected = true
            do {
                let original = try String(contentsOf: file, encoding: .utf8)
                let replacement = original.replacingOccurrences(of: "synthetic-turn", with: "synthetic-xxxx")
                guard replacement != original, replacement.utf8.count == original.utf8.count else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forUpdating: file)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data(replacement.utf8))
                var times = [before.st_atimespec, before.st_mtimespec]
                guard times.withUnsafeMutableBufferPointer({ futimens(handle.fileDescriptor, $0.baseAddress) }) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } catch { writeError = error }
        })
        _ = try awaitProof(reader, id: ids[0])
        armed = true
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        var after = stat()
        XCTAssertEqual(file.path.withCString { lstat($0, &after) }, 0)
        XCTAssertTrue(injected)
        XCTAssertNil(writeError)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertNil(snapshot.verifiedAgentIdentities[ids[0]])
        XCTAssertTrue(snapshot.agentIdentityPartial)
    }

    func testRoundRobinReaderProvidesCompleteChainsForMoreThanOneBatch() throws {
        let (root, ids, _) = try fixture(children: 40)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        var visited: Set<String> = []
        for _ in 0..<40 {
            let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
            if snapshot.verifiedAgentIdentities[rootID]?.isRoot == true {
                for id in ids where snapshot.verifiedAgentIdentities[id]?.parentID == rootID { visited.insert(id) }
            }
            if visited.count == ids.count { break }
            reader.waitForAmbiguousObservationForTests()
        }
        XCTAssertEqual(visited, Set(ids))
    }

    @MainActor
    func testTaskStoreRetainsCountAndHidesCarriedAssistantInCompactMode() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        let store = TaskStore(codexReader: reader,
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")),
                              previewTasks: [])
        Thread.sleep(forTimeInterval: 0.02)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(1))
        let started: [String: Any] = ["timestamp": timestamp, "type": "event_msg",
                                      "payload": ["type": "task_started", "turn_id": "store-turn"]]
        var record = try JSONSerialization.data(withJSONObject: started, options: [.sortedKeys])
        record.append(10)
        for file in files.values {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: record); try handle.close()
        }
        var found = false
        for _ in 0..<20 {
            store.refresh()
            waitForCodexRead(store)
            reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == rootID })?.codexAgentCount == 1 { found = true; break }
        }
        XCTAssertTrue(found, "The child must first be linked through a real fresh header chain")
        guard found else { return }
        XCTAssertEqual(store.compactTasks.count, 1)
        XCTAssertEqual(store.tasks.first(where: { $0.id == rootID })?.codexAgentCountUnconfirmed, true)

        let childFile = try XCTUnwrap(files[ids[0]])
        let parked = root.appendingPathComponent("parked-synthetic-child.jsonl")
        try FileManager.default.moveItem(at: childFile, to: parked)
        store.refresh()
        waitForCodexRead(store)
        let parent = try XCTUnwrap(store.tasks.first { $0.id == rootID })
        XCTAssertEqual(parent.codexAgentCount, 1)
        XCTAssertEqual(parent.codexAgentCountUnconfirmed, true)
        XCTAssertEqual(parent.codexAgentsUnconfirmed, true)
        XCTAssertEqual(parent.codexAgents?.first?.isUnconfirmed, true)
        XCTAssertEqual(store.compactTasks.map(\.id), [rootID])
        XCTAssertFalse(store.tasks.contains { $0.id == ids[0] }, "The carried assistant remains inside its parent")
    }

    @MainActor
    func testTaskStoreKeepsEarlierCountSeparateUntilRootProofReturns() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let mutation = Mutation()
        let reader = CodexTaskReader(codexHome: root, afterAgentProofSelectionForTests: { mutation.run() })
        let store = TaskStore(codexReader: reader,
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")),
                              previewTasks: [])
        Thread.sleep(forTimeInterval: 0.02)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let start: [String: Any] = ["timestamp": formatter.string(from: Date().addingTimeInterval(1)), "type": "event_msg",
                                    "payload": ["type": "task_started", "turn_id": "store-turn"]]
        var startBytes = try JSONSerialization.data(withJSONObject: start, options: [.sortedKeys])
        startBytes.append(10)
        for file in files.values {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: startBytes); try handle.close()
        }
        var found = false
        for _ in 0..<20 {
            store.refresh(); waitForCodexRead(store); reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == rootID })?.codexAgentCount == 1 { found = true; break }
        }
        XCTAssertTrue(found)
        guard found else { return }
        let selected = try XCTUnwrap(store.compactDots.first { $0.task.id == rootID })
        store.selectCompactTask(dot: selected)
        let rootFile = try XCTUnwrap(files[rootID])
        mutation.schedule {
            let event: [String: Any] = ["timestamp": formatter.string(from: Date().addingTimeInterval(2)), "type": "event_msg",
                                        "payload": ["type": "agent_reasoning", "text": "Synthetic new activity"]]
            var bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            bytes.append(10)
            let handle = try FileHandle(forWritingTo: rootFile)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.close()
        }
        store.refresh(); waitForCodexRead(store)
        let result = mutation.result()
        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
        let retainedID = "codex-retained:" + rootID
        let retained = try XCTUnwrap(store.tasks.first { $0.id == retainedID })
        XCTAssertTrue(retained.isUnconfirmed)
        XCTAssertEqual(retained.codexAgentCount, 1)
        XCTAssertEqual(retained.codexAgentCountUnconfirmed, true)
        XCTAssertTrue(store.tasks.contains { $0.id == rootID })
        XCTAssertEqual(store.tasks[store.compactIndex].id, retainedID)

        reader.waitForAmbiguousObservationForTests()
        var recovered = false
        for _ in 0..<20 {
            store.refresh(); waitForCodexRead(store); reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == rootID })?.codexAgentCount == 1 &&
                !store.tasks.contains(where: { $0.id == retainedID }) { recovered = true; break }
        }
        XCTAssertTrue(recovered)
        XCTAssertEqual(store.tasks[store.compactIndex].id, rootID)
        XCTAssertFalse(store.tasks.contains { $0.id == ids[0] })
    }

    @MainActor
    func testConfirmedRootEndingDoesNotResurrectOldFallback() throws {
        let (root, ids, files) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        let store = TaskStore(codexReader: reader,
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")),
                              previewTasks: [])
        Thread.sleep(forTimeInterval: 0.02)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func event(_ kind: String, offset: TimeInterval) throws -> Data {
            let row: [String: Any] = ["timestamp": formatter.string(from: Date().addingTimeInterval(offset)),
                                      "type": "event_msg", "payload": ["type": kind, "turn_id": "store-turn"]]
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            return data
        }
        let started = try event("task_started", offset: 1)
        for file in files.values {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: started); try handle.close()
        }
        var found = false
        for _ in 0..<20 {
            store.refresh(); waitForCodexRead(store); reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == rootID })?.codexAgentCount == 1 { found = true; break }
        }
        XCTAssertTrue(found)
        guard found else { return }
        let childFile = try XCTUnwrap(files[ids[0]])
        try FileManager.default.moveItem(at: childFile, to: root.appendingPathComponent("parked-synthetic-child.jsonl"))
        let parent = try XCTUnwrap(files[rootID])
        let handle = try FileHandle(forWritingTo: parent)
        try handle.seekToEnd(); try handle.write(contentsOf: event("task_complete", offset: 2)); try handle.close()
        store.refresh(); waitForCodexRead(store); waitForClaudeRead(store)
        XCTAssertFalse(store.tasks.contains { $0.id == rootID || $0.id == "codex-retained:" + rootID })
        XCTAssertEqual(store.testRetainedAgentCount(root: rootID), 1, "A missing child is not proof of its exit")
        XCTAssertTrue(store.compactTasks.isEmpty, "The retained child must not become a separate compact task")
        XCTAssertEqual(store.compactEmptyMessage,
                       tr("Список задач Codex может быть неполным", "The Codex task list may be incomplete"))
        store.refresh(); waitForCodexRead(store); waitForClaudeRead(store)
        XCTAssertFalse(store.tasks.contains { $0.id == rootID || $0.id == "codex-retained:" + rootID })
        XCTAssertEqual(store.testRetainedAgentCount(root: rootID), 1)
        XCTAssertTrue(store.compactTasks.isEmpty)
        XCTAssertEqual(store.compactEmptyMessage,
                       tr("Список задач Codex может быть неполным", "The Codex task list may be incomplete"))
    }
}
