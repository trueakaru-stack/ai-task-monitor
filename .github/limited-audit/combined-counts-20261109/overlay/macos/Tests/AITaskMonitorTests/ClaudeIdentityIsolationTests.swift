import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeIdentityIsolationTests: XCTestCase {
    private func event(_ seconds: TimeInterval, session: String, payload: [String: Any]) -> [String: Any] {
        var input = payload
        input["session_id"] = session
        var output = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        output["timestamp"] = formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + seconds))
        return output
    }

    private func plan(session: String, invalidToolID: String? = nil) -> [[String: Any]] {
        var update: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
            "tool_input": ["taskId": "step-1", "status": "completed"],
            "tool_response": ["success": true, "taskId": "step-1", "updatedFields": ["status"],
                              "statusChange": ["from": "pending", "to": "completed"]]]
        if let invalidToolID { update["tool_use_id"] = invalidToolID }
        return [
            event(0, session: session, payload: ["hook_event_name": "UserPromptSubmit"]),
            event(1, session: session, payload: ["hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                  "tool_input": ["subject": "Synthetic step"], "tool_response": ["task": ["id": "step-1", "subject": "Synthetic step"]]]),
            event(2, session: session, payload: update)
        ]
    }

    func testUnsupportedSessionOrToolIDDoesNotConfirmOwnPlanOrAffectNeighbor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("events.jsonl")
        for unsupported in ["é", String(repeating: "a", count: 129)] {
            var data = Data()
            for item in plan(session: "neighbor") + plan(session: unsupported) {
                data.append(try JSONSerialization.data(withJSONObject: item)); data.append(0x0a)
            }
            try data.write(to: file)
            let tasks = try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date(timeIntervalSince1970: 1_800_000_005)).tasks
            let ownID = "claude:" + (try XCTUnwrap(claudeSessionKey(unsupported)))
            XCTAssertFalse(try XCTUnwrap(tasks.first(where: { $0.id == ownID })).planConfirmed)
            XCTAssertTrue(try XCTUnwrap(tasks.first(where: { $0.id == "claude:neighbor" })).planConfirmed)
        }
        var data = Data()
        for item in plan(session: "neighbor") + plan(session: "unsupported-call", invalidToolID: String(repeating: "x", count: 129)) {
            data.append(try JSONSerialization.data(withJSONObject: item)); data.append(0x0a)
        }
        try data.write(to: file)
        let tasks = try ClaudeTaskReader(eventFile: file).readSnapshot(now: Date(timeIntervalSince1970: 1_800_000_005)).tasks
        XCTAssertFalse(try XCTUnwrap(tasks.first(where: { $0.id == "claude:unsupported-call" })).planConfirmed)
        XCTAssertTrue(try XCTUnwrap(tasks.first(where: { $0.id == "claude:neighbor" })).planConfirmed)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(String(repeating: "x", count: 129)))
    }

    func testUnsupportedIdentifiersDoNotOpenSocketOrSetGlobalGap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-identity-channel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let channel = try ClaudeLoopChannel(profile: dir)
        let socketDirectory = try ClaudeLoopSocket.directory(profile: dir, create: false)
        defer {
            _ = channel.stop()
            if let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory),
               socketDirectory.hasPrefix("/private/tmp/aitm-loop-"), Set(names).isSubset(of: ["owner.lock"]) {
                _ = (socketDirectory + "/owner.lock").withCString { unlink($0) }
                _ = socketDirectory.withCString { rmdir($0) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        for (session, tool) in [("é", "call"), (String(repeating: "s", count: 129), "call"),
                                ("neighbor", String(repeating: "t", count: 129))] {
            let input: [String: Any] = ["session_id": session, "hook_event_name": "PreToolUse",
                                         "tool_name": "TaskUpdate", "tool_use_id": tool,
                                         "tool_input": ["taskId": "step-1", "status": "completed"]]
            let bytes = try JSONSerialization.data(withJSONObject: ClaudeHook.makeRecord(from: input), options: [.sortedKeys])
            ClaudeLoopClient.send(input, profile: dir, record: bytes)
        }
        Thread.sleep(forTimeInterval: 0.15)
        let batch = channel.drain()
        XCTAssertFalse(batch.gap)
        XCTAssertTrue(batch.events.isEmpty)
        let neighbor: [String: Any] = ["session_id": "neighbor", "hook_event_name": "PreToolUse",
                                      "tool_name": "TaskUpdate", "tool_use_id": "neighbor-call",
                                      "tool_input": ["taskId": "step-1", "status": "completed"]]
        let bytes = try JSONSerialization.data(withJSONObject: ClaudeHook.makeRecord(from: neighbor), options: [.sortedKeys])
        ClaudeLoopClient.send(neighbor, profile: dir, record: bytes)
        let deadline = Date().addingTimeInterval(3)
        var observed = false
        while Date() < deadline && !observed {
            let next = channel.drain()
            XCTAssertFalse(next.gap)
            observed = next.events.contains { $0.kind == .phase && $0.sessionID == "neighbor" }
            if !observed { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(observed)
    }
}
