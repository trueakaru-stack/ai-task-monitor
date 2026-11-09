import Foundation
import XCTest
@testable import AITaskMonitor

// All inputs are synthetic. These tests do not access a real Codex profile.
final class CodexColdCompressedIndependentTests: XCTestCase {
    private let cold = "019127f4-35ae-7c73-9e72-a10123456789"
    private let live = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-cold-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func index(_ ids: [String], _ root: URL) throws {
        var bytes = Data()
        for id in ids {
            bytes.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic"]))
            bytes.append(0x0a)
        }
        try bytes.write(to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func file(_ id: String, _ root: URL, revision: String? = nil, compressed: Bool = false) -> URL {
        root.appendingPathComponent("sessions/rollout-2026-11-01T10-00-00-\(id)\(revision.map { "_" + $0 } ?? "").jsonl\(compressed ? ".zst" : "")")
    }

    private func compressed(_ id: String, _ root: URL, age: TimeInterval) throws -> URL {
        let url = file(id, root, compressed: true)
        // Placeholder is sufficient: candidate decides from basename before decoding.
        try Data("synthetic".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func start(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        let event: [String: Any] = ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "synthetic"]]
        var bytes = try JSONSerialization.data(withJSONObject: event)
        bytes.append(0x0a)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
    }

    func testOldUnobservedCompressedDoesNotSpoilLiveNeighbor() throws {
        try withRoot { root in
            try index([cold, live], root)
            let since = Date().addingTimeInterval(-10)
            _ = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            try start(file(live, root))
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(3), observedSince: since)
            XCTAssertTrue(snapshot.tasks.contains { $0.id == live && $0.isActive })
            XCTAssertFalse(snapshot.tasks.contains { $0.id == cold })
            XCTAssertFalse(snapshot.isPartial, "A never-observed cold compressed-only history should follow the same startup age filter as a plain history")
        }
    }

    func testFreshCompressedRemainsUncertain() throws {
        try withRoot { root in
            try index([cold], root)
            let since = Date().addingTimeInterval(-20)
            _ = try compressed(cold, root, age: 2)
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: since)
            XCTAssertTrue(snapshot.isPartial)
            XCTAssertTrue(snapshot.tasks.isEmpty)
        }
    }

    func testRecentlyCompressedJustBeforeStartupRemainsUncertain() throws {
        try withRoot { root in
            try index([cold], root)
            _ = try compressed(cold, root, age: 2)
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: Date())
            XCTAssertTrue(snapshot.isPartial)
            XCTAssertTrue(snapshot.tasks.isEmpty)
        }
    }

    func testPreviouslyObservedColdCompressedRemainsUncertain() throws {
        try withRoot { root in
            try index([cold], root)
            _ = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(observedSince: Date().addingTimeInterval(-10), previouslyObserved: [cold])
            XCTAssertTrue(snapshot.isPartial)
            XCTAssertTrue(snapshot.tasks.isEmpty)
        }
    }

    func testColdCompressedAndFreshRevertedRevisionStayAmbiguous() throws {
        try withRoot { root in
            try index([cold, live], root)
            _ = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            try start(file(cold, root, revision: revision))
            try start(file(live, root))
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(3), observedSince: Date().addingTimeInterval(-10))
            XCTAssertTrue(snapshot.isPartial)
            XCTAssertFalse(snapshot.tasks.contains { $0.id == cold })
            XCTAssertFalse(snapshot.terminalIDs.contains(cold))
            XCTAssertTrue(snapshot.tasks.contains { $0.id == live && $0.isActive })
        }
    }

    func testIdenticalPlainAndCompressedRepresentationsUsePlain() throws {
        try withRoot { root in
            try index([cold], root)
            let since = Date().addingTimeInterval(-10)
            _ = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            try start(file(cold, root))
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(3), observedSince: since)
            XCTAssertFalse(snapshot.isPartial, "An exact plain/compressed sibling is one rollout; upstream gives the plain path precedence")
            XCTAssertTrue(snapshot.tasks.contains { $0.id == cold && $0.isActive })
        }
    }

    func testOldCompressedMaterializedAndUpdatedAfterStartupIsSeen() throws {
        try withRoot { root in
            try index([cold], root)
            let since = Date().addingTimeInterval(-10)
            let zipped = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            let reader = CodexTaskReader(codexHome: root)
            let before = try reader.readSnapshot(observedSince: since)
            XCTAssertFalse(before.isPartial)
            XCTAssertTrue(before.tasks.isEmpty)
            // Synthetic analogue of upstream materialization and subsequent append.
            try FileManager.default.removeItem(at: zipped)
            try start(file(cold, root))
            let after = try reader.readSnapshot(now: Date().addingTimeInterval(3), observedSince: since)
            XCTAssertFalse(after.isPartial)
            XCTAssertTrue(after.tasks.contains { $0.id == cold && $0.isActive })
        }
    }

    func testNoStartupBoundaryMustStayConservative() throws {
        try withRoot { root in
            try index([cold], root)
            _ = try compressed(cold, root, age: 8 * 24 * 60 * 60)
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(snapshot.isPartial)
        }
    }
}
