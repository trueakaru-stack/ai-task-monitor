import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

final class CodexAgentReaderProofTests: XCTestCase {
    private let rootID = "10000000-0000-0000-0000-000000000001"

    private func childID(_ index: Int) -> String {
        String(format: "20000000-0000-0000-0000-%012d", index)
    }

    private func rollout(_ directory: URL, id: String, parent: String?, suffix: String = "01") throws -> URL {
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
        let started: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
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
        let (root, ids, _) = try fixture(children: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        _ = try awaitProof(reader, id: ids[0])
        _ = try rollout(root, id: rootID, parent: nil, suffix: "02")
        let snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60),
                                               previouslyObserved: Set([rootID] + ids))
        XCTAssertNil(snapshot.verifiedAgentIdentities[rootID])
        XCTAssertNil(snapshot.verifiedAgentIdentities[ids[0]])
        XCTAssertTrue(snapshot.agentIdentityPartial)
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
}
