import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexSiblingDirectoryIndependentTests: XCTestCase {
    func testSameBasenameInDifferentDirectoriesIsNotOnePhysicalRollout() throws {
        let id = "019127f4-35ae-7c73-9e72-a10123456789"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-sibling-dirs-" + UUID().uuidString, isDirectory: true)
        let a = root.appendingPathComponent("sessions/a", isDirectory: true)
        let b = root.appendingPathComponent("sessions/b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic"])
        var line = index
        line.append(0x0a)
        try line.write(to: root.appendingPathComponent("session_index.jsonl"))
        let name = "rollout-2026-11-01T10-00-00-\(id).jsonl"
        let plain = a.appendingPathComponent(name)
        let zipped = b.appendingPathComponent(name + ".zst")
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2))
        let event: [String: Any] = ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started"]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0a)
        try data.write(to: plain)
        try Data("synthetic".utf8).write(to: zipped)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: plain.path)
        let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(3), observedSince: Date().addingTimeInterval(-10))
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertTrue(snapshot.tasks.isEmpty)
        XCTAssertTrue(snapshot.terminalIDs.isEmpty)
    }
}
