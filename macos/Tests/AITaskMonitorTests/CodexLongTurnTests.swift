import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexLongTurnTests: XCTestCase {
    func testLongTurnsRecoverBoundariesWithoutRevivingOldTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-long-turn-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = ["active", "completed", "quiet", "old-abort", "oversized", "no-start"]
        let index = ids.map { #"{"id":"\#($0)","thread_name":"\#($0)"}"# }.joined(separator: "\n") + "\n"
        try Data(index.utf8).write(to: root.appendingPathComponent("session_index.jsonl"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let since = now.addingTimeInterval(-2)
        let old = formatter.string(from: now.addingTimeInterval(-3_600))
        let recent = formatter.string(from: now.addingTimeInterval(1))
        let start = #"{"timestamp":"\#(old)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-b"}}"#
        let completed = #"{"timestamp":"\#(recent)","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-b"}}"#
        let staleAbort = #"{"timestamp":"\#(old)","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-a"}}"#
        let recentEvent = #"{"timestamp":"\#(recent)","type":"event_msg","payload":{"type":"item_completed"}}"#
        let oldEvent = #"{"timestamp":"\#(old)","type":"event_msg","payload":{"type":"item_completed"}}"#
        let line = #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 65_536))"}}"# + "\n"
        let filler = String(repeating: line, count: 80)
        let oversized = #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 5_300_000))"}}"# + "\n"

        func url(_ id: String) -> URL { sessions.appendingPathComponent("rollout-\(id).jsonl") }
        func create(_ id: String, _ markers: [String], _ padding: String, _ event: String) throws {
            let value = markers.joined(separator: "\n") + "\n" + padding + event + "\n"
            try Data(value.utf8).write(to: url(id))
        }
        try create("active", [start], filler, recentEvent)
        try create("completed", [start, completed], filler, recentEvent)
        try create("quiet", [start], filler, oldEvent)
        try create("old-abort", [start, staleAbort], filler, recentEvent)
        try create("oversized", [start], oversized, recentEvent)
        try create("no-start", [], filler, recentEvent)

        let reader = CodexTaskReader(codexHome: root)
        var snapshot = try reader.readSnapshot(now: now, observedSince: since)
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set(["active", "old-abort", "oversized"]))
        XCTAssertTrue(snapshot.terminalIDs.contains("completed"))
        XCTAssertFalse(snapshot.tasks.contains { $0.id == "quiet" || $0.id == "no-start" })
        XCTAssertEqual(snapshot.tasks.first(where: { $0.id == "active" })?.startKey, "turn:turn-b")

        let smallAppend = try FileHandle(forWritingTo: url("active"))
        try smallAppend.seekToEnd()
        try smallAppend.write(contentsOf: Data((recentEvent + "\n").utf8))
        try smallAppend.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since, previouslyObserved: ["active", "old-abort", "oversized"])
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "active" })

        let burst = try FileHandle(forWritingTo: url("active"))
        try burst.seekToEnd()
        try burst.write(contentsOf: Data((completed + "\n" + filler + recentEvent + "\n").utf8))
        try burst.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since, previouslyObserved: ["active", "old-abort", "oversized"])
        XCTAssertFalse(snapshot.tasks.contains { $0.id == "active" })
        XCTAssertTrue(snapshot.terminalIDs.contains("active"))

        let resumed = try FileHandle(forWritingTo: url("no-start"))
        try resumed.seekToEnd()
        try resumed.write(contentsOf: Data((start + "\n" + filler + recentEvent + "\n").utf8))
        try resumed.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since)
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "no-start" })
    }
}
