import Foundation
import XCTest
@testable import AITaskMonitor

// This suite runs only against a test-instrumented reader: the test runner
// replaces two metadata reads with nil / an empty attribute dictionary.
final class CodexUnknownMetadataIndependentTests: XCTestCase {
    private let failure = "019127f4-35ae-7c73-9e72-a10123456888"
    private let missingDate = "019127f4-35ae-7c73-9e72-a10123456889"
    private let neighbor = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"

    private func withRoot(_ id: String, _ body: (URL, Date, Date) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-unknown-metadata-" + UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var index = Data()
        for item in [id, neighbor] {
            index.append(try JSONSerialization.data(withJSONObject: ["id": item, "thread_name": "Synthetic"]))
            index.append(0x0a)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let zipped = sessions.appendingPathComponent("rollout-2026-11-01T10-00-00-\(id).jsonl.zst")
        try Data("synthetic".utf8).write(to: zipped)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))], ofItemAtPath: zipped.path)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(2))
        let event: [String: Any] = ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started"]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0a)
        let live = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-\(neighbor).jsonl")
        try data.write(to: live)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: live.path)
        try body(root, now.addingTimeInterval(3), now.addingTimeInterval(-10))
    }

    func testFailedAttributeReadStaysUnconfirmedWithoutHidingNeighbor() throws {
        try withRoot(failure) { root, now, since in
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: since)
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == failure })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testMissingModificationDateStaysUnconfirmedWithoutHidingNeighbor() throws {
        try withRoot(missingDate) { root, now, since in
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: since)
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == missingDate })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testOneUnknownDateInMultipleOldRevisionsDoesNotDisappear() throws {
        try withRoot(failure) { root, now, since in
            let oldPlain = root.appendingPathComponent("sessions/rollout-2026-11-01T10-00-00-\(failure)_\(revision).jsonl")
            try Data("synthetic".utf8).write(to: oldPlain)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))], ofItemAtPath: oldPlain.path)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: since)
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == failure })
            XCTAssertFalse(result.terminalIDs.contains(failure))
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }
}
