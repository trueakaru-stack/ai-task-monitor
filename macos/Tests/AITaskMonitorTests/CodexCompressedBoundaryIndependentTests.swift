import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic paths and times only; no real Codex files are opened.
final class CodexCompressedBoundaryIndependentTests: XCTestCase {
    private let thread = "019127f4-35ae-7c73-9e72-a10123456789"

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-compressed-boundary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var data = try JSONSerialization.data(withJSONObject: ["id": thread, "thread_name": "Synthetic"])
        data.append(0x0a)
        try data.write(to: root.appendingPathComponent("session_index.jsonl"))
        try body(root)
    }

    private func file(_ root: URL, compressed: Bool) -> URL {
        root.appendingPathComponent("sessions/rollout-2026-11-01T10-00-00-\(thread).jsonl\(compressed ? ".zst" : "")")
    }

    private func write(_ url: URL, modified: Date) throws {
        try Data("synthetic".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testSevenDayAgeBoundary() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let since = now.addingTimeInterval(-10)
            let compressed = file(root, compressed: true)
            try write(compressed, modified: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 1))
            let reader = CodexTaskReader(codexHome: root)
            XCTAssertTrue(try reader.readSnapshot(now: now, observedSince: since).isPartial)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1)], ofItemAtPath: compressed.path)
            XCTAssertFalse(try reader.readSnapshot(now: now, observedSince: since).isPartial)
        }
    }

    func testEqualObservationBoundaryRemainsUnconfirmed() throws {
        try withRoot { root in
            let boundary = Date(timeIntervalSince1970: 1_700_000_000)
            try write(file(root, compressed: true), modified: boundary)
            let now = boundary.addingTimeInterval(7 * 24 * 60 * 60 + 1)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: boundary)
            XCTAssertTrue(result.isPartial)
        }
    }

    func testOldPlainAndFreshExactCompressedSiblingUsePlainStartupFilter() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            let since = now.addingTimeInterval(-10)
            try write(file(root, compressed: false), modified: now.addingTimeInterval(-(8 * 24 * 60 * 60)))
            try write(file(root, compressed: true), modified: now)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: since)
            XCTAssertFalse(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
        }
    }

    func testUnknownVariantStillBlocksOldCompressedThread() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            try write(file(root, compressed: true), modified: now.addingTimeInterval(-(8 * 24 * 60 * 60)))
            let unknown = root.appendingPathComponent("sessions/rollout-unrecognised-\(thread)_not-a-uuid.jsonl")
            try write(unknown, modified: now)
            let result = try CodexTaskReader(codexHome: root).readSnapshot(now: now, observedSince: now.addingTimeInterval(-10))
            XCTAssertTrue(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
        }
    }
}
