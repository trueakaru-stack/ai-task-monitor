import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

/// Synthetic data only. These tests never read a user's Codex profile.
final class CodexExecDiscoveryTests: XCTestCase {
    private let first = "019127f4-35ae-7c73-9e72-a10123456789"
    private let second = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"

    private func makeRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["RUNNER_OS"] == "macOS", environment["AITM_MACOS_TEST_SANDBOX"] == "1",
              let configured = environment["AITM_SYNTHETIC_TEST_ROOT"] else {
            throw XCTSkip("Synthetic Codex files require an isolated hosted-runner fixture")
        }
        let base = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        let resolved = base.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let container = resolved.deletingLastPathComponent()
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard base == resolved, resolved.lastPathComponent == "temp",
              container.lastPathComponent.hasPrefix("aitm-card-tests."),
              container.deletingLastPathComponent() == runnerTemp,
              values.isDirectory == true, values.isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = resolved.appendingPathComponent("aitm-codex-exec-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions/2026/11/16"), withIntermediateDirectories: true)
        return root
    }

    private func rolloutName(_ id: String, revision: String? = nil) -> String {
        "rollout-2026-11-16T15-31-00-\(id)\(revision.map { "_" + $0 } ?? "").jsonl"
    }

    private func rollout(_ root: URL, fileID: String, metadataID: String? = nil,
                         source: String? = "exec", revision: String? = nil, event: String = "task_started",
                         threadSource: String? = "user") throws -> URL {
        let url = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(fileID, revision: revision))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        var metadata: [String: Any] = ["id": metadataID ?? fileID]
        if let source { metadata["source"] = source }
        if let threadSource { metadata["thread_source"] = threadSource }
        let rows: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": metadata],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": event, "turn_id": "fixture-turn"]]
        ]
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try writeFixture(data, to: url)
        return url
    }

    private func writeFixture(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private func append(_ event: String, to file: URL, turn: String = "fixture-turn") throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
                                  "payload": ["type": event, "turn_id": turn,
                                              "text": event == "agent_reasoning" ? "**Synthetic detail**" : ""]]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func index(_ root: URL, id: String) throws {
        let row: [String: Any] = ["id": id, "thread_name": "Indexed synthetic task"]
        var data = try JSONSerialization.data(withJSONObject: row)
        data.append(0x0a)
        try writeFixture(data, to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func indexRows(_ root: URL, _ rows: [(String, String)]) throws {
        var data = Data()
        for (id, title) in rows {
            data.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": title]))
            data.append(0x0a)
        }
        try writeFixture(data, to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func subagentRollout(_ root: URL, id: String, parent: String, metadataID: String? = nil,
                                 nestedParent: String? = nil, outerPath: String = "/root/research",
                                 nestedPath: String = "/root/research", outerName: String? = "Sparrow",
                                 nestedName: String? = "Sparrow", sourceOverride: String? = nil,
                                 threadSource: Any? = nil) throws {
        var spawn: [String: Any] = ["parent_thread_id": nestedParent ?? parent, "agent_path": nestedPath]
        if let nestedName { spawn["agent_nickname"] = nestedName }
        var payload: [String: Any] = ["id": metadataID ?? id, "parent_thread_id": parent,
            "agent_path": outerPath, "source": ["subagent": ["thread_spawn": spawn]]]
        if let outerName { payload["agent_nickname"] = outerName }
        if let sourceOverride { payload["source"] = sourceOverride }
        if let threadSource { payload["thread_source"] = threadSource }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let rows: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": payload],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "fixture-turn"]],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "user_message", "message": "PRIVATE_ASSIGNMENT"]]
        ]
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0a)
        }
        let url = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(id))
        try writeFixture(data, to: url)
    }

    func testUnindexedSubagentUsesIndexedParentAndConfirmedName() throws {
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            let root = try makeRoot()
            try indexRows(root, [(first, "Parent task")])
            try subagentRollout(root, id: second, parent: first)
            let reader = CodexTaskReader(codexHome: root)
            var snapshot = try reader.readSnapshot()
            for _ in 0..<4 where snapshot.subagentParents[second] == nil {
                reader.waitForAmbiguousObservationForTests()
                snapshot = try reader.readSnapshot()
            }
            let task = try XCTUnwrap(snapshot.tasks.first { $0.id == second })
            XCTAssertEqual(task.title, language == .ru ? "Parent task (агент Sparrow)" : "Parent task (agent Sparrow)")
            XCTAssertFalse(task.isActive)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertNil(task.progress)
            XCTAssertFalse(task.title.contains("PRIVATE_ASSIGNMENT"))
        }
    }

    func testIndexedChildNameTakesPriorityAndUnnamedChildUsesParent() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let root = try makeRoot()
        try subagentRollout(root, id: second, parent: first)
        try indexRows(root, [(first, "Parent task"), (second, "Direct child title")])
        let reader = CodexTaskReader(codexHome: root)
        XCTAssertEqual(try reader.readSnapshot().tasks.first { $0.id == second }?.title, "Direct child title")
        try indexRows(root, [(first, "Parent task"), (second, "")])
        var updated = try reader.readSnapshot()
        for _ in 0..<4 where updated.subagentParents[second] == nil {
            reader.waitForAmbiguousObservationForTests()
            updated = try reader.readSnapshot()
        }
        XCTAssertEqual(updated.tasks.first { $0.id == second }?.title, "Parent task (agent Sparrow)")
    }

    func testVerifiedParentIDReachesSnapshotForIndexedAndUnindexedChild() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        for indexed in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let rows = indexed ? [(first, "Parent task"), (second, "Child task")] : [(first, "Parent task")]
            try indexRows(root, rows)
            try subagentRollout(root, id: second, parent: first)
            let reader = CodexTaskReader(codexHome: root)
            var result = try reader.readSnapshot()
            for _ in 0..<4 where result.subagentParents[second] == nil {
                reader.waitForAmbiguousObservationForTests()
                result = try reader.readSnapshot()
            }
            XCTAssertEqual(result.subagentParents[second], first, "indexed=\(indexed)")
            XCTAssertEqual(result.subagentTitles[first], "Parent task", "indexed=\(indexed)")
            XCTAssertTrue(result.tasks.contains { $0.id == second }, "indexed=\(indexed)")
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testIndexedChildWithConflictingParentMetadataHasNoLink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        try subagentRollout(root, id: second, parent: first, nestedParent: revision)
        let reader = CodexTaskReader(codexHome: root)
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let result = try reader.readSnapshot()
        XCTAssertTrue(result.tasks.contains { $0.id == second })
        XCTAssertNil(result.subagentParents[second])
        reader.waitForAmbiguousObservationForTests()
    }

    func testConflictingNicknameKeepsSeparateCard() throws {
        for indexed in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, indexed ? [(first, "Parent"), (second, "Child")] : [(first, "Parent")])
            _ = try rollout(root, fileID: first)
            try subagentRollout(root, id: second, parent: first, outerName: "One", nestedName: "Two")
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let snapshot = try reader.readSnapshot()
            XCTAssertTrue(snapshot.tasks.contains { $0.id == second })
            XCTAssertNil(snapshot.subagentParents[second])
            let projected = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            XCTAssertTrue(projected.contains { $0.id == first })
            XCTAssertTrue(projected.contains { $0.id == second })
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testUnknownIntermediateMetadataNeverCreatesRoot() throws {
        for intermediateVisible in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, [(first, "Parent"), (second, "Intermediate"), (revision, "Child")])
            _ = try rollout(root, fileID: first, source: "vscode", threadSource: "agent_created_thread")
            try subagentRollout(root, id: second, parent: first, threadSource: "unknown")
            if !intermediateVisible {
                let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
            }
            try subagentRollout(root, id: revision, parent: second)
            let reader = CodexTaskReader(codexHome: root)
            var snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
            for _ in 0..<5 where snapshot.subagentParents[revision] == nil || !snapshot.confirmedSubagentRoots.contains(first) {
                reader.waitForAmbiguousObservationForTests()
                snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
            }
            XCTAssertEqual(snapshot.subagentParents[revision], second)
            XCTAssertNil(snapshot.subagentParents[second])
            XCTAssertTrue(snapshot.confirmedSubagentRoots.contains(first))
            XCTAssertFalse(snapshot.confirmedSubagentRoots.contains(second))
            let visible = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            XCTAssertTrue(visible.contains { $0.id == first })
            XCTAssertTrue(visible.contains { $0.id == revision })
            if intermediateVisible { XCTAssertTrue(visible.contains { $0.id == second }) }
            XCTAssertFalse(visible.contains { $0.id.hasPrefix("codex-group:") })
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testOnlyExplicitCompatibleRootMetadataEnablesGrouping() throws {
        let cases: [(String?, String?, Bool)] = [
            ("cli", "user", true), ("vscode", "agent_created_thread", true),
            ("exec", "user", true), ("mcp", "user", true),
            ("unknown", "user", false), (nil, "user", false), ("vscode", nil, false),
            ("vscode", "subagent", false), ("vscode", "unknown", false)
        ]
        for (source, classification, accepted) in cases {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, [(first, "Parent"), (second, "Child")])
            _ = try rollout(root, fileID: first, source: source, threadSource: classification)
            try subagentRollout(root, id: second, parent: first)
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let snapshot = try reader.readSnapshot()
            XCTAssertEqual(snapshot.confirmedSubagentRoots.contains(first), accepted)
            let visible = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            if accepted {
                XCTAssertEqual(visible.first(where: { $0.id == first })?.codexAgentCount, 1)
            } else {
                XCTAssertTrue(visible.contains { $0.id == first })
                XCTAssertTrue(visible.contains { $0.id == second })
            }
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testTwoRootRolloutsCanConfirmLineageButNeverActivity() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent")])
        _ = try rollout(root, fileID: first, source: "vscode", threadSource: "agent_created_thread")
        let secondRoot = try rollout(root, fileID: first, source: "vscode", revision: revision,
                                     threadSource: "agent_created_thread")
        try subagentRollout(root, id: second, parent: first, threadSource: "subagent")
        let reader = CodexTaskReader(codexHome: root)
        defer { reader.waitForAmbiguousObservationForTests() }
        var snapshot = try reader.readSnapshot()
        var proved = false
        for _ in 0..<8 {
            reader.waitForAmbiguousObservationForTests()
            snapshot = try reader.readSnapshot()
            if snapshot.confirmedSubagentRoots.contains(first) { proved = true; break }
        }
        XCTAssertTrue(proved)
        XCTAssertEqual(snapshot.subagentParents[second], first)
        let grouped = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents,
            titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
        let parent = try XCTUnwrap(grouped.first { $0.id == "codex-group:" + first })
        XCTAssertEqual(parent.title, "Parent")
        XCTAssertEqual(parent.codexAgentCount, 1)
        XCTAssertTrue(parent.isUnconfirmed)
        XCTAssertFalse(parent.isActive)
        XCTAssertNil(parent.progress)
        XCTAssertFalse(snapshot.terminalIDs.contains(first))
        reader.waitForAmbiguousObservationForTests()

        let original = try Data(contentsOf: secondRoot)
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        for different in ["subagent", "user"] {
            try writeFixture(Data(text.replacingOccurrences(of: "agent_created_thread", with: different).utf8), to: secondRoot)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            snapshot = try reader.readSnapshot()
            XCTAssertFalse(snapshot.confirmedSubagentRoots.contains(first), different)
            XCTAssertTrue(CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots).contains { $0.id == second })
            try writeFixture(original, to: secondRoot)
            for _ in 0..<8 {
                reader.waitForAmbiguousObservationForTests()
                snapshot = try reader.readSnapshot()
                if snapshot.confirmedSubagentRoots.contains(first) { break }
            }
            XCTAssertTrue(snapshot.confirmedSubagentRoots.contains(first), different)
            reader.waitForAmbiguousObservationForTests()
        }
        let otherDir = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let thirdRoot = otherDir.appendingPathComponent(rolloutName(first))
        try writeFixture(Data(text.replacingOccurrences(of: "agent_created_thread", with: "subagent").utf8), to: thirdRoot)
        snapshot = try reader.readSnapshot()
        XCTAssertFalse(snapshot.confirmedSubagentRoots.contains(first), "A new version must invalidate the old proof")
        XCTAssertFalse(snapshot.terminalIDs.contains(first))
    }

    func testThreadSourceMustAgreeWithSubagentMetadata() throws {
        let cases: [(Any?, Bool)] = [(nil, true), (NSNull(), true), ("subagent", true),
                                     ("user", false), ("guardian_review", false), ("unknown", false), (42, false)]
        for (classification, accepted) in cases {
          for indexed in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, indexed ? [(first, "Parent"), (second, "Child")] : [(first, "Parent")])
            _ = try rollout(root, fileID: first)
            try subagentRollout(root, id: second, parent: first, threadSource: classification)
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let snapshot = try reader.readSnapshot()
            XCTAssertTrue(snapshot.tasks.contains { $0.id == second })
            XCTAssertEqual(snapshot.subagentParents[second] == first, accepted)
            if !indexed && !accepted {
                let child = try XCTUnwrap(snapshot.tasks.first { $0.id == second })
                XCTAssertTrue(child.isUnconfirmed)
                XCTAssertFalse(child.isActive)
                XCTAssertNil(snapshot.subagentParents[second])
            }
            reader.waitForAmbiguousObservationForTests()
          }
        }
    }

    func testStringSourceWithSubagentClassificationRemainsSeparate() throws {
        for source in ["cli", "vscode"] {
          for indexed in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, indexed ? [(first, "Parent"), (second, "Child")] : [(first, "Parent")])
            _ = try rollout(root, fileID: first)
            try subagentRollout(root, id: second, parent: first, sourceOverride: source, threadSource: "subagent")
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let snapshot = try reader.readSnapshot()
            let child = try XCTUnwrap(snapshot.tasks.first { $0.id == second }, "\(source), indexed=\(indexed)")
            if !indexed { XCTAssertTrue(child.isUnconfirmed) }
            XCTAssertNil(snapshot.subagentParents[second])
            let visible = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            XCTAssertTrue(visible.contains { $0.id == first })
            XCTAssertTrue(visible.contains { $0.id == second })
            reader.waitForAmbiguousObservationForTests()
          }
        }
    }

    func testDuplicateMetadataKeysNeverCreateRelationship() throws {
        for duplicate in ["id", "parent", "path", "nested-parent", "nested-path", "escaped-id"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try indexRows(root, [(first, "Parent"), (second, "Child")])
            _ = try rollout(root, fileID: first)
            let extraID = duplicate == "id" ? "\"id\":\"\(first)\"," :
                (duplicate == "escaped-id" ? "\"\\u0069d\":\"\(first)\"," : "")
            let extraParent = duplicate == "parent" ? "\"parent_thread_id\":\"\(revision)\"," : ""
            let extraPath = duplicate == "path" ? "\"agent_path\":\"/root/other\"," : ""
            let extraNestedParent = duplicate == "nested-parent" ? "\"parent_thread_id\":\"\(revision)\"," : ""
            let extraNestedPath = duplicate == "nested-path" ? "\"agent_path\":\"/root/other\"," : ""
            let header = """
            {"type":"session_meta","payload":{\(extraID)"id":"\(second)",\(extraParent)"parent_thread_id":"\(first)",\(extraPath)"agent_path":"/root/research","source":{"subagent":{"thread_spawn":{\(extraNestedParent)"parent_thread_id":"\(first)",\(extraNestedPath)"agent_path":"/root/research"}}}}}
            """
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let event = "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"fixture-turn\"}}"
            let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
            try writeFixture(Data((header + "\n" + event + "\n").utf8), to: file)
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let result = try reader.readSnapshot()
            XCTAssertTrue(result.tasks.contains { $0.id == second }, duplicate)
            XCTAssertNil(result.subagentParents[second], duplicate)
            let visible = CodexTaskGrouping.project(result.tasks, parents: result.subagentParents, titles: result.subagentTitles, confirmedRoots: result.confirmedSubagentRoots)
            XCTAssertTrue(visible.contains { $0.id == first }, duplicate)
            XCTAssertTrue(visible.contains { $0.id == second }, duplicate)
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testReplacementAtSamePathInvalidatesCachedRelationship() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        let reader = CodexTaskReader(codexHome: root)
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let original = try reader.readSnapshot()
        XCTAssertEqual(original.subagentParents[second], first)
        reader.waitForAmbiguousObservationForTests()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let held = root.appendingPathComponent("old-synthetic-rollout")
        try FileManager.default.moveItem(at: file, to: held)
        try subagentRollout(root, id: second, parent: first, nestedParent: revision)
        if let modified = before[.modificationDate] {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertNotEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        let replaced = try reader.readSnapshot()
        XCTAssertNil(replaced.subagentParents[second])
        let visible = CodexTaskGrouping.project(replaced.tasks, parents: replaced.subagentParents, titles: replaced.subagentTitles, confirmedRoots: replaced.confirmedSubagentRoots)
        XCTAssertTrue(visible.contains { $0.id == first })
        XCTAssertTrue(visible.contains { $0.id == second })
        reader.waitForAmbiguousObservationForTests()
        XCTAssertNil(try reader.readSnapshot().subagentParents[second])
        reader.waitForAmbiguousObservationForTests()
    }

    func testReplacementBetweenIndexedAttributesAndTailCannotMixRelationship() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let child = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        try append("agent_reasoning", to: child)
        let original = try XCTUnwrap(String(data: Data(contentsOf: child), encoding: .utf8))
        let replacement = root.appendingPathComponent("replacement-fixture")
        try writeFixture(Data(original.replacingOccurrences(of: first, with: revision).utf8), to: replacement)
        let held = root.appendingPathComponent("held-original")
        var armed = false
        var swapError: Error?
        let reader = CodexTaskReader(codexHome: root, afterIndexedAttributesForTests: { id in
            guard armed, id == self.second else { return }
            armed = false
            do {
                try FileManager.default.moveItem(at: child, to: held)
                try FileManager.default.moveItem(at: replacement, to: child)
            } catch { swapError = error }
        })
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let before = try reader.readSnapshot()
        XCTAssertEqual(before.subagentParents[second], first)
        XCTAssertTrue(before.tasks.first(where: { $0.id == second })?.lastKnownActivity?.contains("Synthetic detail") == true)
        reader.waitForAmbiguousObservationForTests()
        armed = true
        let after = try reader.readSnapshot()
        XCTAssertNil(swapError)
        XCTAssertFalse(armed)
        XCTAssertTrue(after.isPartial)
        XCTAssertNil(after.subagentParents[second])
        XCTAssertFalse(after.tasks.contains { $0.id == second })
        let retained = TaskSnapshotMerger.merge(previous: before.tasks, current: after.tasks, terminalIDs: after.terminalIDs)
        let kept = try XCTUnwrap(retained.first { $0.id == second })
        XCTAssertTrue(kept.isUnconfirmed)
        XCTAssertFalse(kept.displayedActivity.contains("Synthetic detail"))
        reader.waitForAmbiguousObservationForTests()
    }

    func testTruncationBetweenIndexedAttributesAndTailIsRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let child = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        var armed = false
        var truncationError: Error?
        let reader = CodexTaskReader(codexHome: root, afterIndexedAttributesForTests: { id in
            guard armed, id == self.second else { return }
            armed = false
            do { try self.writeFixture(Data(), to: child) } catch { truncationError = error }
        })
        defer { reader.waitForAmbiguousObservationForTests() }
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let before = try reader.readSnapshot()
        XCTAssertEqual(before.subagentParents[second], first)
        reader.waitForAmbiguousObservationForTests()
        armed = true
        let after = try reader.readSnapshot()
        XCTAssertNil(truncationError)
        XCTAssertFalse(armed)
        XCTAssertTrue(after.isPartial)
        XCTAssertFalse(after.tasks.contains { $0.id == second })
        XCTAssertNil(after.subagentParents[second])
    }

    func testAppendsKeepVerifiedGroupWithoutPartialWarning() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        let reader = CodexTaskReader(codexHome: root)
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        var snapshot = try reader.readSnapshot()
        XCTAssertEqual(snapshot.subagentParents[second], first)
        reader.waitForAmbiguousObservationForTests()
        for _ in 0..<4 {
            try append("agent_reasoning", to: file)
            snapshot = try reader.readSnapshot()
            XCTAssertEqual(snapshot.subagentParents[second], first)
            XCTAssertFalse(snapshot.isPartial)
            let grouped = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            XCTAssertEqual(grouped.first(where: { $0.id == first })?.codexAgentCount, 1)
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testLargeHistoryEventuallyGroupsUnindexedChildAndRejectsConflict() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let child = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<320 {
            let file = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: file.path)
        }
        let reader = CodexTaskReader(codexHome: root)
        defer { reader.waitForAmbiguousObservationForTests() }
        var previous: Set<String> = []
        var lastTasks: [MonitoredTask] = []
        var found = false
        var trace: [String] = []
        for round in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: previous)
            previous.formUnion(snapshot.tasks.map(\.id))
            lastTasks = TaskSnapshotMerger.merge(previous: lastTasks, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            trace.append("\(round):visible=\(snapshot.tasks.contains { $0.id == second }),sweep=\(snapshot.didCompleteUnindexedSweep),file=\(snapshot.verifiedActivityFiles[second] != nil),link=\(snapshot.subagentParents[second] == first),root=\(snapshot.confirmedSubagentRoots.contains(first))")
            reader.waitForAmbiguousObservationForTests()
            if snapshot.subagentParents[second] == first {
                let grouped = CodexTaskGrouping.project(lastTasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
                XCTAssertEqual(grouped.first(where: { $0.id == first })?.codexAgentCount, 1)
                found = true
                break
            }
        }
        XCTAssertTrue(found, "A completed sweep should verify the unindexed path: \(trace.joined(separator: "; "))")
        guard found else { return }
        for _ in 0..<3 {
            try append("agent_reasoning", to: child)
            let snapshot = try reader.readSnapshot(previouslyObserved: previous)
            XCTAssertEqual(snapshot.subagentParents[second], first)
            reader.waitForAmbiguousObservationForTests()
        }

        let oldIdentity = root.appendingPathComponent("saved-previous-child")
        try FileManager.default.moveItem(at: child, to: oldIdentity)
        try subagentRollout(root, id: second, parent: first)
        let replaced = try reader.readSnapshot(previouslyObserved: previous)
        XCTAssertNil(replaced.subagentParents[second], "A new inode must not inherit the verified path")
        reader.waitForAmbiguousObservationForTests()
        var reverified = false
        for _ in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: previous)
            lastTasks = TaskSnapshotMerger.merge(previous: lastTasks, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            reader.waitForAmbiguousObservationForTests()
            if snapshot.subagentParents[second] == first { reverified = true; break }
        }
        XCTAssertTrue(reverified, "A stable replacement must be verified by a new sweep")
        guard reverified else { return }
        let named = try XCTUnwrap(lastTasks.first { $0.id == second })
        XCTAssertEqual(named.title, "Parent (agent Sparrow)")
        XCTAssertTrue(named.usesDerivedCodexParentTitle == true)

        let competing = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(second)_\(revision).jsonl")
        let childText = try XCTUnwrap(String(data: Data(contentsOf: child), encoding: .utf8))
        try writeFixture(Data(childText.replacingOccurrences(of: first, with: revision).utf8), to: competing)
        var rejected = false
        for _ in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: previous)
            lastTasks = TaskSnapshotMerger.merge(previous: lastTasks, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            reader.waitForAmbiguousObservationForTests()
            if snapshot.subagentParents[second] == nil {
                let kept = try XCTUnwrap(lastTasks.first { $0.id == second })
                XCTAssertEqual(kept.title, "Codex task")
                let visible = CodexTaskGrouping.project(lastTasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
                XCTAssertTrue(visible.contains { $0.id == second })
                rejected = true
                break
            }
        }
        XCTAssertTrue(rejected, "The next sweep should invalidate a competing rollout")
        reader.waitForAmbiguousObservationForTests()
    }

    func testNewUnindexedAssistantIsNotStarvedBySixteenRetainedSessions() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent")])
        _ = try rollout(root, fileID: first)
        let old = (1...16).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let newID = "00000000-0000-4000-8000-000000000099"
        for id in old { try subagentRollout(root, id: id, parent: first) }
        let reader = CodexTaskReader(codexHome: root)
        defer { reader.waitForAmbiguousObservationForTests() }
        let before = try reader.readSnapshot(previouslyObserved: Set(old))
        XCTAssertEqual(Set(before.tasks.filter { old.contains($0.id) }.map(\.id)), Set(old))
        reader.waitForAmbiguousObservationForTests()
        try subagentRollout(root, id: newID, parent: first)
        let next = try reader.readSnapshot(previouslyObserved: Set(old))
        XCTAssertTrue(next.isPartial)
        XCTAssertTrue(next.tasks.contains { $0.id == newID })
        var retained = TaskSnapshotMerger.merge(previous: before.tasks, current: next.tasks, terminalIDs: next.terminalIDs)
        XCTAssertTrue(Set(retained.map(\.id)).isSuperset(of: Set(old + [newID])))
        reader.waitForAmbiguousObservationForTests()
        var visited: Set<String> = []
        for _ in 0..<4 {
            let snapshot = try reader.readSnapshot(previouslyObserved: Set(old + [newID]))
            visited.formUnion(snapshot.tasks.map(\.id))
            reader.waitForAmbiguousObservationForTests()
        }
        XCTAssertTrue(visited.isSuperset(of: Set(old + [newID])))
        var grouped = false
        for _ in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: Set(old + [newID]))
            retained = TaskSnapshotMerger.merge(previous: retained, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            reader.waitForAmbiguousObservationForTests()
            let projection = CodexTaskGrouping.project(retained, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            if projection.first(where: { $0.id == first })?.codexAgentCount == 17 { grouped = true; break }
        }
        XCTAssertTrue(grouped, "Verified links should cover all retained assistants")
        guard grouped else { return }
        for _ in 0..<4 {
            let snapshot = try reader.readSnapshot(previouslyObserved: Set(old + [newID]))
            retained = TaskSnapshotMerger.merge(previous: retained, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            let projection = CodexTaskGrouping.project(retained, parents: snapshot.subagentParents,
                titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
            XCTAssertEqual(projection.first(where: { $0.id == first })?.codexAgentCount, 17)
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testFairSelectionAdvancesWhenPreviouslySelectedNewIDsLeaveQueue() throws {
        let cache = CodexExecDiscoveryCache()
        var existing = (1...16).map { String(format: "old-%03d", $0) }
        var unseen = (1...40).map { String(format: "new-%03d", $0) }
        let pageCursor = CodexExecDiscoveryCache()
        _ = pageCursor.selectFair(existing: existing, unseen: unseen, limit: 16)
        let newestOnlyOnThisPage = "new-000"
        let nextPage = pageCursor.selectFair(existing: existing, unseen: [newestOnlyOnThisPage] + unseen, limit: 16)
        XCTAssertTrue(nextPage.contains(newestOnlyOnThisPage))
        var discovered: Set<String> = []
        for _ in 0..<10 {
            let selected = cache.selectFair(existing: existing, unseen: unseen, limit: 16)
            XCTAssertLessThanOrEqual(selected.count, 16)
            let newlySeen = Set(unseen).intersection(selected)
            discovered.formUnion(newlySeen)
            existing.append(contentsOf: newlySeen)
            unseen.removeAll { newlySeen.contains($0) }
        }
        XCTAssertEqual(discovered.count, 40)
    }

    func testRewrittenHeaderOnSameInodeInvalidatesRelationship() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Child")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        let reader = CodexTaskReader(codexHome: root)
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        XCTAssertEqual(try reader.readSnapshot().subagentParents[second], first)
        reader.waitForAmbiguousObservationForTests()
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        try subagentRollout(root, id: second, parent: first, nestedParent: revision)
        try append("agent_reasoning", to: file)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let rechecked = try reader.readSnapshot()
        XCTAssertNil(rechecked.subagentParents[second])
        let visible = CodexTaskGrouping.project(rechecked.tasks, parents: rechecked.subagentParents, titles: rechecked.subagentTitles, confirmedRoots: rechecked.confirmedSubagentRoots)
        XCTAssertTrue(visible.contains { $0.id == first })
        XCTAssertTrue(visible.contains { $0.id == second })
        reader.waitForAmbiguousObservationForTests()
    }

    func testIndexedCompletedIntermediateIsDiscoveredForActiveGrandchild() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (second, "Intermediate"), (revision, "Grandchild")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let intermediate = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        try append("task_complete", to: intermediate)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: intermediate.path)
        try subagentRollout(root, id: revision, parent: second)
        let reader = CodexTaskReader(codexHome: root)
        var snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        for _ in 0..<6 where snapshot.subagentParents[second] != first || snapshot.subagentParents[revision] != second {
            reader.waitForAmbiguousObservationForTests()
            snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        }
        XCTAssertFalse(snapshot.tasks.contains { $0.id == second })
        XCTAssertEqual(snapshot.subagentParents[second], first)
        XCTAssertEqual(snapshot.subagentParents[revision], second)
        let visible = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.id, first)
        XCTAssertEqual(visible.first?.codexAgentCount, 1)
        XCTAssertEqual(visible.first?.codexAgents?.map(\.id), [revision])
        reader.waitForAmbiguousObservationForTests()
    }

    func testUnavailableOldIntermediateLeavesGrandchildSeparate() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try indexRows(root, [(first, "Parent"), (revision, "Grandchild")])
        _ = try rollout(root, fileID: first)
        try subagentRollout(root, id: second, parent: first)
        let intermediate = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        try append("task_complete", to: intermediate)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: intermediate.path)
        try subagentRollout(root, id: revision, parent: second)
        let reader = CodexTaskReader(codexHome: root)
        var snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        for _ in 0..<4 {
            reader.waitForAmbiguousObservationForTests()
            snapshot = try reader.readSnapshot(observedSince: Date().addingTimeInterval(-60))
        }
        XCTAssertEqual(snapshot.subagentParents[revision], second)
        XCTAssertNil(snapshot.subagentParents[second])
        let visible = CodexTaskGrouping.project(snapshot.tasks, parents: snapshot.subagentParents, titles: snapshot.subagentTitles, confirmedRoots: snapshot.confirmedSubagentRoots)
        XCTAssertTrue(visible.contains { $0.id == first })
        XCTAssertTrue(visible.contains { $0.id == revision })
        reader.waitForAmbiguousObservationForTests()
    }

    @MainActor
    func testTaskStoreGroupsVerifiedChildAndKeepsSelectionAndDisclosure() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = CodexTaskReader(codexHome: root)
        let store = TaskStore(codexReader: reader,
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                              previewTasks: [])
        let neighbor2 = "f19127f4-35ae-7c73-9e72-a10123456789"
        let neighbor3 = "f29127f4-35ae-7c73-9e72-a10123456789"
        try indexRows(root, [(first, "Parent"), (revision, "Neighbor"), (neighbor2, "Neighbor 2"), (neighbor3, "Neighbor 3")])
        _ = try rollout(root, fileID: first)
        _ = try rollout(root, fileID: revision)
        _ = try rollout(root, fileID: neighbor2)
        _ = try rollout(root, fileID: neighbor3)
        store.refresh()
        waitForCodexRead(store)
        XCTAssertEqual(store.tasks.count, 4)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(store.tasks.firstIndex { $0.id == first }), 3)
        try indexRows(root, [(first, "Parent"), (second, "Child"), (revision, "Neighbor"), (neighbor2, "Neighbor 2"), (neighbor3, "Neighbor 3")])
        try subagentRollout(root, id: second, parent: first)
        store.refresh()
        waitForCodexRead(store)
        XCTAssertEqual(store.tasks.count, 5)
        store.compactIndex = try XCTUnwrap(store.tasks.firstIndex { $0.id == second })
        XCTAssertLessThan(store.compactIndex, 3)
        reader.waitForAmbiguousObservationForTests()
        var found = false
        for _ in 0..<8 {
            store.refresh()
            waitForCodexRead(store)
            reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == first })?.codexAgentCount == 1 {
                found = true
                break
            }
        }
        XCTAssertTrue(found)
        XCTAssertEqual(store.tasks[store.compactIndex].id, first)
        XCTAssertLessThan(store.compactIndex, 3)
        XCTAssertEqual(store.count(for: .all), 4)
        XCTAssertEqual(store.count(for: .codex), 4)
        XCTAssertTrue(store.tasks.contains { $0.id == revision })
        XCTAssertTrue(store.tasks.contains { $0.id == neighbor2 })
        XCTAssertTrue(store.tasks.contains { $0.id == neighbor3 })
        store.refresh()
        waitForCodexRead(store)
        XCTAssertEqual(store.tasks[store.compactIndex].id, first)
        XCTAssertLessThan(store.compactIndex, 3)
        store.toggleCodexGroup(first)
        XCTAssertTrue(store.isCodexGroupExpanded(first))
        XCTAssertTrue(store.isCodexGroupExpanded("codex-group:" + first))
        let childFile = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(second))
        try append("agent_reasoning", to: childFile)
        for _ in 0..<8 {
            store.refresh()
            waitForCodexRead(store)
            reader.waitForAmbiguousObservationForTests()
            if store.tasks.first(where: { $0.id == first })?.codexAgentCount == 1 { break }
        }
        XCTAssertTrue(store.isCodexGroupExpanded(first))
        let parent = try XCTUnwrap(store.tasks.first { $0.id == first })
        XCTAssertEqual(parent.codexAgents?.first?.id, second)
        XCTAssertTrue(store.tasks.contains { $0.id == revision })
        reader.waitForAmbiguousObservationForTests()
    }

    func testMissingParentOrUnconfirmedNicknameKeepsGenericTitle() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let missingParent = try makeRoot()
        try subagentRollout(missingParent, id: second, parent: first)
        XCTAssertEqual(try CodexTaskReader(codexHome: missingParent).readSnapshot().tasks.first?.title, "Codex task")

        let missingName = try makeRoot()
        try indexRows(missingName, [(first, "Parent task")])
        try subagentRollout(missingName, id: second, parent: first, outerName: nil, nestedName: nil)
        XCTAssertEqual(try CodexTaskReader(codexHome: missingName).readSnapshot().tasks.first?.title, "Codex task")

        let conflictingName = try makeRoot()
        try indexRows(conflictingName, [(first, "Parent task")])
        try subagentRollout(conflictingName, id: second, parent: first, outerName: "One", nestedName: "Two")
        XCTAssertEqual(try CodexTaskReader(codexHome: conflictingName).readSnapshot().tasks.first?.title, "Codex task")

        let unpairedName = try makeRoot()
        try indexRows(unpairedName, [(first, "Parent task")])
        try subagentRollout(unpairedName, id: second, parent: first, outerName: nil)
        XCTAssertEqual(try CodexTaskReader(codexHome: unpairedName).readSnapshot().tasks.first?.title, "Codex task")

        let emptyParent = try makeRoot()
        try indexRows(emptyParent, [(first, "  ")])
        try subagentRollout(emptyParent, id: second, parent: first)
        XCTAssertEqual(try CodexTaskReader(codexHome: emptyParent).readSnapshot().tasks.first?.title, "Codex task")

        let guardianParent = try makeRoot()
        try indexRows(guardianParent, [(first, "Guardian review")])
        try subagentRollout(guardianParent, id: second, parent: first)
        XCTAssertEqual(try CodexTaskReader(codexHome: guardianParent).readSnapshot().tasks.first?.title, "Codex task")

        let ordinaryExec = try makeRoot()
        try indexRows(ordinaryExec, [(first, "Parent task")])
        try subagentRollout(ordinaryExec, id: second, parent: first, sourceOverride: "exec")
        XCTAssertEqual(try CodexTaskReader(codexHome: ordinaryExec).readSnapshot().tasks.first?.title, "Codex task")
    }

    func testSubagentDiscoveryRejectsConflictingIdentityAndPaths() throws {
        for kind in ["child-id", "parent-id", "path-mismatch", "path-traversal", "self-parent"] {
            let root = try makeRoot()
            try indexRows(root, [(first, "Parent task")])
            switch kind {
            case "child-id": try subagentRollout(root, id: second, parent: first, metadataID: first)
            case "parent-id": try subagentRollout(root, id: second, parent: first, nestedParent: revision)
            case "path-mismatch": try subagentRollout(root, id: second, parent: first, nestedPath: "/root/other")
            case "path-traversal": try subagentRollout(root, id: second, parent: first, outerPath: "/root/../other", nestedPath: "/root/../other")
            default: try subagentRollout(root, id: second, parent: second)
            }
            let reader = CodexTaskReader(codexHome: root)
            _ = try reader.readSnapshot()
            reader.waitForAmbiguousObservationForTests()
            let snapshot = try reader.readSnapshot()
            if kind == "child-id" {
                XCTAssertFalse(snapshot.tasks.contains { $0.id == second }, "Rejected metadata: \(kind)")
            } else {
                let task = try XCTUnwrap(snapshot.tasks.first { $0.id == second }, kind)
                XCTAssertTrue(task.isUnconfirmed, kind)
                XCTAssertFalse(task.isActive, kind)
                XCTAssertNil(snapshot.subagentParents[second], kind)
            }
            reader.waitForAmbiguousObservationForTests()
        }
    }

    func testExecWithoutIndexIsVisibleWithoutCreatingIndex() throws {
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        _ = try rollout(root, fileID: first)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: observedSince)
        XCTAssertEqual(snapshot.tasks.map(\.id), [first])
        let task = try XCTUnwrap(snapshot.tasks.first)
        XCTAssertFalse(task.isActive)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertNil(task.progressLabel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session_index.jsonl").path))
    }

    func testVSCodeSourceWithoutIndexIsVisibleOnlyAsUnconfirmed() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        let file = try rollout(root, fileID: first, source: "vscode")
        let reader = CodexTaskReader(codexHome: root)
        let snapshot = try reader.readSnapshot(observedSince: observedSince)
        let task = try XCTUnwrap(snapshot.tasks.first { $0.id == first })
        XCTAssertEqual(task.title, "Codex task")
        XCTAssertFalse(task.isActive)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertNil(task.progress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session_index.jsonl").path))

        try append("task_complete", to: file)
        let completed = try reader.readSnapshot(observedSince: observedSince, previouslyObserved: [first])
        XCTAssertFalse(completed.tasks.contains { $0.id == first })
        XCTAssertTrue(completed.terminalIDs.contains(first))
    }

    func testUnindexedUncertainEndingsDoNotClaimSuccess() throws {
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        for scenario in ["missing-turn", "other-turn", "error", "partial"] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let since = Date().addingTimeInterval(-60)
            let file = try rollout(root, fileID: first)
            _ = try rollout(root, fileID: second)
            let reader = CodexTaskReader(codexHome: root)
            let before = try reader.readSnapshot(observedSince: since)
            XCTAssertTrue(before.tasks.contains { $0.id == first && $0.isUnconfirmed })
            XCTAssertTrue(before.tasks.contains { $0.id == second && $0.isUnconfirmed })
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var payload: [String: Any] = ["type": "task_complete", "turn_id": "fixture-turn"]
            if scenario == "missing-turn" { payload["turn_id"] = "" }
            if scenario == "other-turn" { payload["turn_id"] = "other-turn" }
            if scenario == "error" { payload["error"] = ["message": "Synthetic error"] }
            var bytes = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: Date()),
                                                                    "type": "event_msg", "payload": payload])
            bytes.append(0x0a)
            if scenario == "partial" { bytes.append(contentsOf: Data("{\"type\":".utf8)) }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
            try handle.close()

            let after = try reader.readSnapshot(observedSince: since, previouslyObserved: [first, second])
            XCTAssertFalse(after.terminalIDs.contains(first), scenario)
            let merged = TaskSnapshotMerger.merge(previous: before.tasks, current: after.tasks, terminalIDs: after.terminalIDs)
            let task = try XCTUnwrap(merged.first { $0.id == first }, scenario)
            XCTAssertTrue(task.isUnconfirmed, scenario)
            XCTAssertFalse(task.isActive, scenario)
            XCTAssertNil(task.progress, scenario)
            XCTAssertTrue(merged.contains { $0.id == second && $0.isUnconfirmed }, scenario)
        }
    }

    func testIndexedAndUnindexedTasksAppearTogether() throws {
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        try index(root, id: first)
        _ = try rollout(root, fileID: first, source: "cli")
        _ = try rollout(root, fileID: second)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: observedSince)
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set([first, second]))
        XCTAssertEqual(snapshot.tasks.first { $0.id == first }?.title, "Indexed synthetic task")
        XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first { $0.id == first }).isActive)
        XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first { $0.id == second }).isUnconfirmed)
        XCTAssertFalse(snapshot.isPartial)
    }

    func testUnindexedCompletionIsReportedForAnObservedTask() throws {
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        let file = try rollout(root, fileID: first)
        try append("task_complete", to: file)
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(observedSince: observedSince, previouslyObserved: [first])
        XCTAssertFalse(snapshot.tasks.contains { $0.id == first })
        XCTAssertTrue(snapshot.terminalIDs.contains(first))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session_index.jsonl").path))
    }

    func testUnindexedNewStartDuringTerminalReadNeverClosesOldCard() throws {
        for point in ["tail", "recheck"] {
            let root = try makeRoot()
            let since = Date().addingTimeInterval(-1)
            let file = try rollout(root, fileID: first)
            var armed = false
            var appended = false
            var appendError: Error?
            let inject: (String) -> Void = { id in
                guard id == self.first, armed, !appended else { return }
                appended = true
                do { try self.append("task_started", to: file, turn: "next-turn") }
                catch { appendError = error }
            }
            let reader = CodexTaskReader(codexHome: root,
                afterUnindexedTailForTests: point == "tail" ? inject : nil,
                beforeUnindexedTerminalRecheckForTests: point == "recheck" ? inject : nil)
            let previous = try reader.readSnapshot(observedSince: since).tasks
            XCTAssertTrue(previous.contains { $0.id == first && $0.isUnconfirmed })
            try append("task_complete", to: file)
            armed = true
            let raced = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            XCTAssertTrue(appended, "The fixture must write at the selected race point")
            XCTAssertNil(appendError)
            XCTAssertTrue(raced.isPartial)
            XCTAssertFalse(raced.terminalIDs.contains(first))
            let retained = TaskSnapshotMerger.merge(previous: previous, current: raced.tasks, terminalIDs: raced.terminalIDs)
            XCTAssertTrue(retained.contains { $0.id == first && $0.isUnconfirmed })
            armed = false
            let next = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            XCTAssertTrue(next.tasks.contains { $0.id == first && $0.startKey == "turn:next-turn" })
        }
    }

    func testUnindexedOtherSourcesAndMismatchedIdentityAreNotClaimed() throws {
        let root = try makeRoot()
        _ = try rollout(root, fileID: first, source: "cli")
        _ = try rollout(root, fileID: second, metadataID: first)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testAmbiguousRevertedExecDoesNotProduceConfirmedCard() throws {
        let root = try makeRoot()
        _ = try rollout(root, fileID: first)
        _ = try rollout(root, fileID: first, revision: revision)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertTrue(snapshot.isPartial)
    }

    func testUnindexedSymlinkIsNotReadAsARealSession() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        let target = try rollout(outside, fileID: first)
        let link = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(first))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
        XCTAssertTrue(snapshot.tasks.isEmpty)
    }

    func testAbandonedUnindexedLogNeverClaimsTheProcessIsRunning() throws {
        let root = try makeRoot()
        let file = try rollout(root, fileID: first)
        try append("agent_reasoning", to: file)
        let task = try XCTUnwrap(CodexTaskReader(codexHome: root).readSnapshot().tasks.first)
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.isActive)
        XCTAssertNil(task.progressLabel)
        XCTAssertTrue(task.activity.contains("Synthetic detail"))
        XCTAssertTrue(task.activity.contains("Статус не подтверждён") || task.activity.contains("Status unconfirmed"))
    }

    func testUnreadableIndexKeepsPriorCardsAndFindsExecAsPartial() throws {
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        try index(root, id: first)
        _ = try rollout(root, fileID: first, source: "cli")
        _ = try rollout(root, fileID: second)
        let reader = CodexTaskReader(codexHome: root)
        let before = try reader.readSnapshot(observedSince: observedSince)
        XCTAssertEqual(Set(before.tasks.map(\.id)), Set([first, second]))
        try writeFixture(Data(repeating: 0x78, count: 1_048_577), to: root.appendingPathComponent("session_index.jsonl"))
        let after = try reader.readSnapshot(observedSince: observedSince, previouslyObserved: Set(before.tasks.map(\.id)))
        let merged = TaskSnapshotMerger.merge(previous: before.tasks, current: after.tasks, terminalIDs: after.terminalIDs)
        XCTAssertTrue(after.isPartial)
        XCTAssertTrue(try XCTUnwrap(merged.first { $0.id == first }).isUnconfirmed)
        XCTAssertTrue(try XCTUnwrap(merged.first { $0.id == second }).isUnconfirmed)
    }

    func testLargeHistoryWarnsButFindsRecentUnindexedExec() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let id = UUID().uuidString.lowercased()
            let file = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(id).jsonl")
            try writeFixture(Data(), to: file)
        }
        let original = try rollout(root, fileID: first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let recent = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let destination = recent.appendingPathComponent(original.lastPathComponent)
        if destination.standardizedFileURL != original.standardizedFileURL {
            try FileManager.default.moveItem(at: original, to: destination)
        }
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first { $0.id == first }).isUnconfirmed)
    }

    func testOfficialCodexExecFixtureWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["AITM_MACOS_TEST_SANDBOX"] == "1",
              let input = environment["AITM_REAL_CODEX_ROLLOUT"],
              let allowed = environment["AITM_SYNTHETIC_TEST_ROOT"] else {
            throw XCTSkip("Official CLI fixture is supplied only by the isolated hosted-runner job")
        }
        let base = URL(fileURLWithPath: allowed, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        let source = URL(fileURLWithPath: input).resolvingSymlinksInPath().standardizedFileURL
        guard source.path.hasPrefix(base + "/") else { throw CocoaError(.fileReadNoPermission) }
        let data = try Data(contentsOf: source)
        guard let newline = data.firstIndex(of: 0x0a),
              let meta = try JSONSerialization.jsonObject(with: Data(data[..<newline])) as? [String: Any],
              let payload = meta["payload"] as? [String: Any],
              let id = payload["id"] as? String, let timestamp = FileHelpers.isoDate(meta["timestamp"]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        XCTAssertEqual(payload["source"] as? String, "exec")
        let root = try makeRoot()
        let file = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(id))
        try writeFixture(data, to: file)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: timestamp.addingTimeInterval(2),
                                                                        observedSince: timestamp.addingTimeInterval(-1))
        let task = try XCTUnwrap(snapshot.tasks.first { $0.id == id })
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.isActive)
        XCTAssertNil(task.progressLabel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("session_index.jsonl").path))
    }

    func testLongUnindexedHistoryWithoutVisibleStartDoesNotEndPreviousTask() throws {
        let root = try makeRoot()
        let file = try rollout(root, fileID: first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let filler = Data((String(repeating: "x", count: 300_000) + "\n").utf8)
        try handle.write(contentsOf: filler)
        try handle.close()
        try append("task_complete", to: file)
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(observedSince: Date().addingTimeInterval(-60), previouslyObserved: [first])
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertFalse(snapshot.terminalIDs.contains(first))
    }

    func testPartialHistoryDoesNotAssertUnindexedCompletion() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let file = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: file)
        }
        let original = try rollout(root, fileID: first)
        try append("task_complete", to: original)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let recent = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        let destination = recent.appendingPathComponent(original.lastPathComponent)
        if destination.standardizedFileURL != original.standardizedFileURL {
            try FileManager.default.moveItem(at: original, to: destination)
        }
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(observedSince: Date().addingTimeInterval(-60), previouslyObserved: [first])
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertFalse(snapshot.terminalIDs.contains(first))
    }

    func testUnindexedKnownPlanDoesNotShowCertainProgress() throws {
        let root = try makeRoot()
        let file = try rollout(root, fileID: first)
        let plan = #"{"plan":[{"step":"Synthetic step","status":"in_progress"}]}"#
        let event: [String: Any] = ["type": "response_item", "payload":
            ["type": "function_call", "name": "update_plan", "arguments": plan]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        let task = try XCTUnwrap(CodexTaskReader(codexHome: root).readSnapshot().tasks.first)
        XCTAssertEqual(task.steps.map(\.title), ["Synthetic step"])
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertNil(task.progress)
        XCTAssertNil(task.progressLabel)
        XCTAssertNotNil(task.planStatusNote)
    }

    func testEarlierExecWithWriterFileAppearsUnconfirmedAfterMonitorStarts() throws {
        let root = try makeRoot()
        _ = try rollout(root, fileID: first)
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        try writeFixture(Data(), to: locks.appendingPathComponent(first + ".lock"))
        let observedSince = Date().addingTimeInterval(60)
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(now: observedSince.addingTimeInterval(1), observedSince: observedSince)
        let task = try XCTUnwrap(snapshot.tasks.first { $0.id == first })
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.isActive)
        XCTAssertNil(task.progressLabel)
    }

    func testEarlierExecWithoutWriterFileIsNotShownAsActive() throws {
        let root = try makeRoot()
        _ = try rollout(root, fileID: first)
        let observedSince = Date().addingTimeInterval(60)
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(now: observedSince.addingTimeInterval(1), observedSince: observedSince)
        XCTAssertFalse(snapshot.tasks.contains { $0.id == first })
    }

    func testWriterLockSymlinkIsNotTreatedAsEvidence() throws {
        let root = try makeRoot()
        _ = try rollout(root, fileID: first)
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("synthetic-target")
        try writeFixture(Data(), to: target)
        try FileManager.default.createSymbolicLink(at: locks.appendingPathComponent(first + ".lock"), withDestinationURL: target)
        let observedSince = Date().addingTimeInterval(60)
        let snapshot = try CodexTaskReader(codexHome: root)
            .readSnapshot(now: observedSince.addingTimeInterval(1), observedSince: observedSince)
        XCTAssertFalse(snapshot.tasks.contains { $0.id == first })
        XCTAssertTrue(snapshot.isPartial)
    }

    func testTodayDirectoryOverBudgetEventuallyReachesLaterFile() throws {
        let root = try makeRoot()
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        var candidates: [String: String] = [:]
        for _ in 0..<600 {
            let id = UUID().uuidString.lowercased()
            let path = today.appendingPathComponent("rollout-2026-11-16T15-31-00-\(id).jsonl")
            try writeFixture(Data(), to: path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path.path)
            candidates[path.standardizedFileURL.path] = id
        }
        func firstPage(_ directory: URL) throws -> Set<String> {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles]) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            var paths: Set<String> = []
            for _ in 0..<256 {
                guard let value = enumerator.nextObject() as? URL else { break }
                paths.insert(value.standardizedFileURL.path)
            }
            return paths
        }
        let initiallyScanned = try firstPage(today).union(firstPage(sessions))
        let chosen = try XCTUnwrap(candidates.first { !initiallyScanned.contains($0.key) })
        let target = URL(fileURLWithPath: chosen.key)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let rows: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": ["id": chosen.value, "source": "exec"]],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "fixture-turn"]]
        ]
        var bytes = Data()
        for row in rows {
            bytes.append(try JSONSerialization.data(withJSONObject: row))
            bytes.append(0x0a)
        }
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: bytes)
        try handle.close()
        let reader = CodexTaskReader(codexHome: root)
        let observedSince = Date().addingTimeInterval(-60)
        var found = false
        for round in 0..<12 {
            let snapshot = try reader.readSnapshot(observedSince: observedSince)
            XCTAssertTrue(snapshot.isPartial)
            if round == 0 { XCTAssertFalse(snapshot.tasks.contains { $0.id == chosen.value }) }
            if let task = snapshot.tasks.first(where: { $0.id == chosen.value }) {
                XCTAssertTrue(task.isUnconfirmed)
                XCTAssertFalse(task.isActive)
                found = true
                break
            }
        }
        XCTAssertTrue(found)
    }

    func testObservedExecFinishesAfterPagedHistoryVerification() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let path = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path.path)
        }
        let original = try rollout(root, fileID: first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        let file = today.appendingPathComponent(original.lastPathComponent)
        if file.standardizedFileURL != original.standardizedFileURL { try FileManager.default.moveItem(at: original, to: file) }
        let reader = CodexTaskReader(codexHome: root)
        let since = Date().addingTimeInterval(-60)
        let before = try reader.readSnapshot(observedSince: since)
        XCTAssertTrue(try XCTUnwrap(before.tasks.first { $0.id == first }).isUnconfirmed)
        try append("task_complete", to: file)
        var finished = false
        for _ in 0..<12 {
            let after = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            if after.terminalIDs.contains(first) {
                let merged = TaskSnapshotMerger.merge(previous: before.tasks, current: after.tasks, terminalIDs: after.terminalIDs)
                XCTAssertFalse(merged.contains { $0.id == first })
                finished = true
                break
            }
        }
        XCTAssertTrue(finished)
    }

    func testCachedUniquePathDoesNotConfirmTerminalDuringNextIncompleteSweep() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<320 {
            let path = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path.path)
        }
        let original = try rollout(root, fileID: first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        let file = today.appendingPathComponent(original.lastPathComponent)
        if file.standardizedFileURL != original.standardizedFileURL { try FileManager.default.moveItem(at: original, to: file) }
        let reader = CodexTaskReader(codexHome: root)
        defer { reader.waitForAmbiguousObservationForTests() }
        let before = try reader.readSnapshot()
        XCTAssertTrue(before.tasks.contains { $0.id == first })
        var completed = 0
        for _ in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: [first])
            if snapshot.didCompleteUnindexedSweep { completed += 1 }
            if completed == 2 { break }
        }
        XCTAssertEqual(completed, 2)
        guard completed == 2 else { return }
        try append("task_complete", to: file)
        let incomplete = try reader.readSnapshot(previouslyObserved: [first])
        XCTAssertFalse(incomplete.didCompleteUnindexedSweep)
        XCTAssertFalse(incomplete.terminalIDs.contains(first))
        let retained = TaskSnapshotMerger.merge(previous: before.tasks, current: incomplete.tasks, terminalIDs: incomplete.terminalIDs)
        XCTAssertTrue(retained.contains { $0.id == first && $0.isUnconfirmed })
        var ended = false
        for _ in 0..<20 {
            let snapshot = try reader.readSnapshot(previouslyObserved: [first])
            if snapshot.terminalIDs.contains(first) {
                XCTAssertTrue(snapshot.didCompleteUnindexedSweep)
                ended = true
                break
            }
        }
        XCTAssertTrue(ended)
        reader.waitForAmbiguousObservationForTests()
    }

    func testPagedHistoryDuplicatePreventsFalseCompletion() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let path = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path.path)
        }
        let original = try rollout(root, fileID: first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        let file = today.appendingPathComponent(original.lastPathComponent)
        if file.standardizedFileURL != original.standardizedFileURL { try FileManager.default.moveItem(at: original, to: file) }
        let reader = CodexTaskReader(codexHome: root)
        let since = Date().addingTimeInterval(-60)
        let before = try reader.readSnapshot(observedSince: since)
        XCTAssertTrue(try XCTUnwrap(before.tasks.first { $0.id == first }).isUnconfirmed)
        let duplicate = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(first)_\(revision).jsonl")
        try FileManager.default.copyItem(at: file, to: duplicate)
        try append("task_complete", to: file)
        for _ in 0..<12 {
            let after = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            XCTAssertTrue(after.isPartial)
            XCTAssertFalse(after.terminalIDs.contains(first))
            let kept = TaskSnapshotMerger.merge(previous: before.tasks, current: after.tasks, terminalIDs: after.terminalIDs)
            XCTAssertTrue(kept.contains { $0.id == first && $0.isUnconfirmed })
        }
    }

    @MainActor
    func testBrokenIndexWithoutReadableExecStaysFullyUnavailable() throws {
        let root = try makeRoot()
        try writeFixture(Data(repeating: 0x78, count: 1_048_577), to: root.appendingPathComponent("session_index.jsonl"))
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")))
        store.refresh()
        waitForCodexRead(store)
        XCTAssertTrue(store.unavailableSources.contains(.codex))
        XCTAssertFalse(store.codexPartiallyUnavailable)
    }

    func testPagedCompletionWaitsForWriterFileToDisappear() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let path = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            try writeFixture(Data(), to: path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path.path)
        }
        let original = try rollout(root, fileID: first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.dateComponents([.year, .month, .day], from: Date())
        let today = root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d",
            try XCTUnwrap(date.year), try XCTUnwrap(date.month), try XCTUnwrap(date.day)), isDirectory: true)
        try FileManager.default.createDirectory(at: today, withIntermediateDirectories: true)
        let file = today.appendingPathComponent(original.lastPathComponent)
        if file.standardizedFileURL != original.standardizedFileURL { try FileManager.default.moveItem(at: original, to: file) }
        let locks = root.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        let marker = locks.appendingPathComponent(first + ".lock")
        try writeFixture(Data(), to: marker)
        let reader = CodexTaskReader(codexHome: root)
        let since = Date().addingTimeInterval(-60)
        let before = try reader.readSnapshot(observedSince: since)
        XCTAssertTrue(try XCTUnwrap(before.tasks.first { $0.id == first }).isUnconfirmed)
        try append("task_complete", to: file)
        for _ in 0..<8 {
            let after = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            XCTAssertFalse(after.terminalIDs.contains(first))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
        try FileManager.default.removeItem(at: marker)
        var finished = false
        for _ in 0..<12 {
            let after = try reader.readSnapshot(observedSince: since, previouslyObserved: [first])
            if after.terminalIDs.contains(first) { finished = true; break }
        }
        XCTAssertTrue(finished)
    }
}
