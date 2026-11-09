import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic source paths only. The compressed placeholders are not decoded.
final class CodexMultipleColdIndependentTests: XCTestCase {
    private let thread = "019127f4-35ae-7c73-9e72-a10123456789"
    private let neighbor = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"
    private let next = "019127f4-35ae-7c73-9e72-a10987654320"

    private func withRoot(_ body: (URL, Date, Date) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-multiple-cold-" + UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var index = Data()
        for id in [thread, neighbor] {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic"]))
            index.append(0x0a)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let cold = now.addingTimeInterval(-(8 * 24 * 60 * 60))
        for suffix in ["", "_" + revision] {
            let compressed = sessions.appendingPathComponent("rollout-2026-11-01T10-00-00-\(thread)\(suffix).jsonl.zst")
            try Data("synthetic".utf8).write(to: compressed)
            try FileManager.default.setAttributes([.modificationDate: cold], ofItemAtPath: compressed.path)
        }
        try start(sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-\(neighbor).jsonl"), now: now)
        try body(root, now, now.addingTimeInterval(-10))
    }

    private func start(_ file: URL, now: Date) throws {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(2))
        let event: [String: Any] = ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started"]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0a)
        try data.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(2)], ofItemAtPath: file.path)
    }

    func testUnobservedAllOldCompressedRevisionsDoNotWarn() throws {
        try withRoot { root, now, since in
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now.addingTimeInterval(3), observedSince: since)
            XCTAssertFalse(result.isPartial, "Old never-observed revisions should not create a permanent active-source warning")
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testPreviouslyObservedOldRevisionsStayUnconfirmed() throws {
        try withRoot { root, now, since in
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now.addingTimeInterval(3), observedSince: since, previouslyObserved: [thread])
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testAnyNewRevisionKeepsTheWholeThreadAmbiguous() throws {
        try withRoot { root, now, since in
            let newest = root.appendingPathComponent("sessions/rollout-2026-11-09T10-00-00-\(thread)_\(next).jsonl")
            try start(newest, now: now)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now.addingTimeInterval(3), observedSince: since)
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertFalse(result.terminalIDs.contains(thread))
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testOldPlainAndOldCompressedDifferentRevisionsAreHistorical() throws {
        try withRoot { root, now, since in
            let stem = "rollout-2026-11-01T10-00-00-\(thread).jsonl"
            try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(stem).zst"))
            let plain = root.appendingPathComponent("sessions/\(stem)")
            try Data("synthetic".utf8).write(to: plain)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))], ofItemAtPath: plain.path)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now.addingTimeInterval(3), observedSince: since)
            XCTAssertFalse(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testOldPlainWithRecentCompressedDifferentRevisionRemainsAmbiguous() throws {
        try withRoot { root, now, since in
            let stem = "rollout-2026-11-01T10-00-00-\(thread).jsonl"
            try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/\(stem).zst"))
            let plain = root.appendingPathComponent("sessions/\(stem)")
            try Data("synthetic".utf8).write(to: plain)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(8 * 24 * 60 * 60))], ofItemAtPath: plain.path)
            let compressed = root.appendingPathComponent("sessions/rollout-2026-11-01T10-00-00-\(thread)_\(revision).jsonl.zst")
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)], ofItemAtPath: compressed.path)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now.addingTimeInterval(3), observedSince: since)
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertTrue(result.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }
}
