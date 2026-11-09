import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic-only; real AF_UNIX case requires a disposable isolated macOS runner.
final class ClaudePhaseIdentityIsolationIndependentTests: XCTestCase {
    private let key = Data(repeating: 0x29, count: 32)

    private func input(_ session: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "PreToolUse", "tool_name": "TaskCreate",
         "tool_use_id": "synthetic-call", "tool_input": ["subject": "Synthetic step"]]
    }

    func testOrdinaryUUIDProducesPhaseFrame() throws {
        let session = "019127f4-35ae-7c73-9e72-a10123456789"
        let raw = input(session)
        let record = ClaudeHook.makeRecord(from: raw)
        XCTAssertEqual(record["session_id"] as? String, session)
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let payload = try XCTUnwrap(ClaudeLoopClient.phasePayload(raw, record: data, key: key))
        let frame = try XCTUnwrap(ClaudeLoopPayload.parse(payload))
        XCTAssertEqual(frame.sessionID, session)
        XCTAssertEqual(frame.kind, .phase)
    }

    func testReaderAcceptsSessionsThatPhasePayloadRejects() throws {
        for session in ["é", String(repeating: "a", count: 129)] {
            let raw = input(session)
            let record = ClaudeHook.makeRecord(from: raw)
            XCTAssertEqual(record["session_id"] as? String, session)
            XCTAssertNotNil(claudeSessionKey(session))
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            XCTAssertNil(ClaudeLoopClient.phasePayload(raw, record: data, key: key))
        }
    }

    func testUnsupportedSessionMustNotPoisonNeighborChannel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-id-gap-" + UUID().uuidString)
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
        let ordinary = "019127f4-35ae-7c73-9e72-a10123456789"
        XCTAssertEqual(ClaudeHook.process(input(ordinary), directory: dir, retentionPolicy: { nil }), 0)
        var observedOrdinary = false
        let firstDeadline = Date().addingTimeInterval(3)
        while Date() < firstDeadline && !observedOrdinary {
            let batch = channel.drain()
            XCTAssertFalse(batch.gap)
            observedOrdinary = batch.events.contains { $0.kind == .phase && $0.sessionID == ordinary }
            if !observedOrdinary { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(observedOrdinary, "Positive UUID control must reach the local channel")

        XCTAssertEqual(ClaudeHook.process(input("é"), directory: dir, retentionPolicy: { nil }), 0)
        let log = try Data(contentsOf: dir.appendingPathComponent("claude-events-v2.jsonl"))
        let records = log.split(separator: 0x0a).compactMap { ClaudeJSONValidation.object(Data($0)) }
        XCTAssertTrue(records.contains { ($0["session_id"] as? String)?.utf8.elementsEqual("é".utf8) == true },
                      "The otherwise accepted session must have been written")
        var observedGap = false
        let secondDeadline = Date().addingTimeInterval(3)
        while Date() < secondDeadline && !observedGap {
            observedGap = channel.drain().gap
            if !observedGap { Thread.sleep(forTimeInterval: 0.01) }
        }
        // Fix3 is expected to fail here: the rejected payload closes an already
        // accepted connection, which the server treats as a source-wide gap.
        XCTAssertFalse(observedGap, "An unsupported but identifiable session must not poison its neighbor")
    }
}
