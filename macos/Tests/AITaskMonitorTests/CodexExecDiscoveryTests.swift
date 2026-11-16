import Foundation
import XCTest
@testable import AITaskMonitor

/// Synthetic data only. These tests never read a user's Codex profile.
final class CodexExecDiscoveryTests: XCTestCase {
    private let first = "019127f4-35ae-7c73-9e72-a10123456789"
    private let second = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-codex-exec-" + UUID().uuidString, isDirectory: true)
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
        XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first).isActive)
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
        XCTAssertFalse(snapshot.isPartial)
    }

    func testUnindexedCompletionIsReportedForAnObservedTask() throws {
        let root = try makeRoot()
        let observedSince = Date().addingTimeInterval(-1)
        _ = try rollout(root, fileID: first, event: "task_complete")
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
}
