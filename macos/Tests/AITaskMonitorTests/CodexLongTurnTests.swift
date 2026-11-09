import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexLongTurnTests: XCTestCase {
    func testLongPlanSurvivesAndContinuationIsUnconfirmed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-plan-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("session_index.jsonl")
        try Data(#"{"id":"019127f4-35ae-7c73-9e72-a10123456001","thread_name":"Synthetic task"}"#.utf8).write(to: index)
        let file = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456001.jsonl")
        func event(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        func plan(_ title: String) throws -> String {
            let input = String(decoding: try JSONSerialization.data(withJSONObject: ["plan": [["step": title, "status": "in_progress"]]]), as: UTF8.self)
            return try event(["type": "response_item", "payload": ["type": "function_call", "name": "update_plan", "arguments": input]])
        }
        let start = try event(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "one"]])
        let filler = #"{"type":"response_item","payload":{"text":"\#(String(repeating: "x", count: 65_536))"}}"# + "\n"
        try Data((start + plan("First synthetic plan") + String(repeating: filler, count: 66)).utf8).write(to: file)
        let reader = CodexTaskReader(codexHome: root)
        var task = try XCTUnwrap(reader.readTasks().first)
        XCTAssertEqual(task.steps.map(\.title), ["First synthetic plan"])
        XCTAssertTrue(task.planConfirmed)
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd()
        try append.write(contentsOf: Data(try event(["type": "event_msg", "payload": ["type": "task_started", "turn_id": "two"]]).utf8))
        try append.close()
        task = try XCTUnwrap(reader.readTasks().first)
        XCTAssertEqual(task.steps.map(\.title), ["First synthetic plan"])
        XCTAssertFalse(task.planConfirmed)
        let update = try FileHandle(forWritingTo: file)
        try update.seekToEnd()
        try update.write(contentsOf: Data(try plan("Second synthetic plan").utf8))
        try update.close()
        task = try XCTUnwrap(reader.readTasks().first)
        XCTAssertEqual(task.steps.map(\.title), ["Second synthetic plan"])
        XCTAssertTrue(task.planConfirmed)
        try Data(start.utf8).write(to: file)
        XCTAssertTrue(try XCTUnwrap(reader.readTasks().first).steps.isEmpty)
    }

    func testActiveSessionOutsideIndexTailRemainsVisibleAndCacheInvalidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-index-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("session_index.jsonl")
        let first = #"{"id":"019127f4-35ae-7c73-9e72-a10123456002","thread_name":"Synthetic older"}"# + "\n"
        let padding = #"{"id":"019127f4-35ae-7c73-9e72-a10123456003","padding":"\#(String(repeating: "x", count: 800))"}"# + "\n"
        try Data((first + String(repeating: padding, count: 3_000)).utf8).write(to: index)
        let session = sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-019127f4-35ae-7c73-9e72-a10123456002.jsonl")
        let start = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"synthetic"}}"# + "\n"
        try Data(start.utf8).write(to: session)
        let reader = CodexTaskReader(codexHome: root)
        XCTAssertEqual(reader.readTasks().map(\.id), ["019127f4-35ae-7c73-9e72-a10123456002"])
        XCTAssertEqual(reader.readTasks().map(\.id), ["019127f4-35ae-7c73-9e72-a10123456002"])
        try Data(padding.utf8).write(to: index)
        XCTAssertTrue(reader.readTasks().isEmpty)
    }

    func testLongTurnsRecoverBoundariesWithoutRevivingOldTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-long-turn-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ids = ["019127f4-35ae-7c73-9e72-a10123456004", "019127f4-35ae-7c73-9e72-a10123456005", "019127f4-35ae-7c73-9e72-a10123456003", "019127f4-35ae-7c73-9e72-a10123456006", "019127f4-35ae-7c73-9e72-a10123456007", "019127f4-35ae-7c73-9e72-a10123456008"]
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

        func url(_ id: String) -> URL { sessions.appendingPathComponent("rollout-2026-11-09T10-00-00-\(id).jsonl") }
        func create(_ id: String, _ markers: [String], _ padding: String, _ event: String) throws {
            let value = markers.joined(separator: "\n") + "\n" + padding + event + "\n"
            try Data(value.utf8).write(to: url(id))
        }
        try create("019127f4-35ae-7c73-9e72-a10123456004", [start], filler, recentEvent)
        try create("019127f4-35ae-7c73-9e72-a10123456005", [start, completed], filler, recentEvent)
        try create("019127f4-35ae-7c73-9e72-a10123456003", [start], filler, oldEvent)
        try create("019127f4-35ae-7c73-9e72-a10123456006", [start, staleAbort], filler, recentEvent)
        try create("019127f4-35ae-7c73-9e72-a10123456007", [start], oversized, recentEvent)
        try create("019127f4-35ae-7c73-9e72-a10123456008", [], filler, recentEvent)

        let reader = CodexTaskReader(codexHome: root)
        var snapshot = try reader.readSnapshot(now: now, observedSince: since)
        XCTAssertEqual(Set(snapshot.tasks.map(\.id)), Set(["019127f4-35ae-7c73-9e72-a10123456004", "019127f4-35ae-7c73-9e72-a10123456006", "019127f4-35ae-7c73-9e72-a10123456007"]))
        XCTAssertTrue(snapshot.terminalIDs.contains("019127f4-35ae-7c73-9e72-a10123456005"))
        XCTAssertFalse(snapshot.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456003" || $0.id == "019127f4-35ae-7c73-9e72-a10123456008" })
        XCTAssertEqual(snapshot.tasks.first(where: { $0.id == "019127f4-35ae-7c73-9e72-a10123456004" })?.startKey, "turn:turn-b")

        let smallAppend = try FileHandle(forWritingTo: url("019127f4-35ae-7c73-9e72-a10123456004"))
        try smallAppend.seekToEnd()
        try smallAppend.write(contentsOf: Data((recentEvent + "\n").utf8))
        try smallAppend.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since, previouslyObserved: ["019127f4-35ae-7c73-9e72-a10123456004", "019127f4-35ae-7c73-9e72-a10123456006", "019127f4-35ae-7c73-9e72-a10123456007"])
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456004" })

        let burst = try FileHandle(forWritingTo: url("019127f4-35ae-7c73-9e72-a10123456004"))
        try burst.seekToEnd()
        try burst.write(contentsOf: Data((completed + "\n" + filler + recentEvent + "\n").utf8))
        try burst.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since, previouslyObserved: ["019127f4-35ae-7c73-9e72-a10123456004", "019127f4-35ae-7c73-9e72-a10123456006", "019127f4-35ae-7c73-9e72-a10123456007"])
        XCTAssertFalse(snapshot.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456004" })
        XCTAssertTrue(snapshot.terminalIDs.contains("019127f4-35ae-7c73-9e72-a10123456004"))

        let resumed = try FileHandle(forWritingTo: url("019127f4-35ae-7c73-9e72-a10123456008"))
        try resumed.seekToEnd()
        try resumed.write(contentsOf: Data((start + "\n" + filler + recentEvent + "\n").utf8))
        try resumed.close()
        snapshot = try reader.readSnapshot(now: now, observedSince: since)
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "019127f4-35ae-7c73-9e72-a10123456008" })
    }
}
