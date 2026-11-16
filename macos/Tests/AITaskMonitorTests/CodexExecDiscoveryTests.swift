import Foundation
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
                         source: String = "exec", revision: String? = nil, event: String = "task_started") throws -> URL {
        let url = root.appendingPathComponent("sessions/2026/11/16").appendingPathComponent(rolloutName(fileID, revision: revision))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let rows: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": ["id": metadataID ?? fileID, "source": source]],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": event, "turn_id": "fixture-turn"]]
        ]
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func append(_ event: String, to file: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
                                  "payload": ["type": event, "turn_id": "fixture-turn",
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
        try data.write(to: root.appendingPathComponent("session_index.jsonl"))
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
        try Data(repeating: 0x78, count: 1_048_577).write(to: root.appendingPathComponent("session_index.jsonl"))
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
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
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
        try data.write(to: file, options: .atomic)
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
            guard FileManager.default.createFile(atPath: file.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
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
        guard FileManager.default.createFile(atPath: locks.appendingPathComponent(first + ".lock").path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
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
        guard FileManager.default.createFile(atPath: target.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
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
            guard FileManager.default.createFile(atPath: path.path, contents: Data()) else {
                throw CocoaError(.fileWriteUnknown)
            }
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
            guard FileManager.default.createFile(atPath: path.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
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

    func testPagedHistoryDuplicatePreventsFalseCompletion() throws {
        let root = try makeRoot()
        let old = root.appendingPathComponent("sessions/2001/01/01", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        for _ in 0..<300 {
            let path = old.appendingPathComponent("rollout-2001-01-01T00-00-00-\(UUID().uuidString.lowercased()).jsonl")
            guard FileManager.default.createFile(atPath: path.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
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
        }
    }
}
