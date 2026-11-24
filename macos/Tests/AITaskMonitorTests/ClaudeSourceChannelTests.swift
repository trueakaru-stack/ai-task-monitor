import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class ClaudeSourceChannelTests: XCTestCase {
    private final class Connection {
        private let lock = NSLock()
        private var value: ClaudeIntegration.ConnectionState = .connected
        func read() -> ClaudeIntegration.ConnectionState { lock.lock(); defer { lock.unlock() }; return value }
        func disconnect() { lock.lock(); value = .disconnected; lock.unlock() }
    }

    @MainActor
    private func wait(_ worker: ClaudeSourceWorker) throws -> ClaudeSourceRead {
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return try XCTUnwrap(result)
    }

    @MainActor
    private func sendAndWait(_ worker: ClaudeSourceWorker, profile: URL, toolID: String) {
        let input: [String: Any] = ["session_id": "fixture", "hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_use_id": toolID, "cwd": "/synthetic",
            "tool_input": ["command": "synthetic command"]]
        ClaudeLoopClient.send(input, profile: profile)
        let deadline = Date().addingTimeInterval(3)
        while !worker.hasPendingOrdinaryForTesting("fixture") && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(worker.hasPendingOrdinaryForTesting("fixture"), "The real channel must queue the event")
    }

    @MainActor
    func testRealQueuedEventsSurviveBusyAndStopSignalsGap() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-channel-")
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        var record = ClaudeHook.makeRecord(from: ["session_id": "fixture", "hook_event_name": "UserPromptSubmit"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        record["timestamp"] = formatter.string(from: Date().addingTimeInterval(-3))
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0a)
        try data.write(to: file)
        let state = Connection()
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: file), channelProfile: root,
                                        requiresChannel: true, connection: { state.read() })
        var socketDirectory: String?
        defer {
            worker.close()
            let deadline = Date().addingTimeInterval(4)
            while !worker.channelStoppedForTesting && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if worker.channelStoppedForTesting, let directory = socketDirectory,
               directory.hasPrefix("/private/tmp/aitm-loop-\(geteuid())-"),
               let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
               Set(names).isSubset(of: ["owner.lock"]) {
                _ = (directory + "/owner.lock").withCString { unlink($0) }
                _ = directory.withCString { rmdir($0) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let first = try wait(worker)
        XCTAssertFalse(first.channelUnavailable, "The real isolated channel must open")
        socketDirectory = try ClaudeLoopSocket.directory(profile: root, create: false)
        sendAndWait(worker, profile: root, toolID: "first")

        let lockPath = root.appendingPathComponent("claude-events.lock").path
        let descriptor = lockPath.withCString { open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let busy = try wait(worker)
        _ = flock(descriptor, LOCK_UN)
        guard case .failed(let error) = busy.outcome,
              let sourceError = error as? ClaudeReadError, case .journalBusy = sourceError else {
            return XCTFail("The synthetic journal lock must produce journalBusy")
        }
        XCTAssertTrue(busy.before.ordinary.contains { $0.sessionID == "fixture" && $0.kind == .start })
        XCTAssertFalse(busy.before.gap)

        sendAndWait(worker, profile: root, toolID: "second")
        state.disconnect()
        let disconnected = try wait(worker)
        guard case .disconnected = disconnected.outcome else { return XCTFail("The source must disconnect") }
        XCTAssertTrue(disconnected.before.gap, "Stopping a channel with queued events must report a gap")
        XCTAssertTrue(disconnected.before.affectsAll)
    }
}
#endif
