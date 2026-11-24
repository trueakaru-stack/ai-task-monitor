import Darwin
import CryptoKit
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

    private final class Injection {
        private let lock = NSLock()
        private weak var worker: ClaudeSourceWorker?
        private var claimed = false
        private var received = false
        private var failure: Error?
        func configure(_ worker: ClaudeSourceWorker) { lock.lock(); self.worker = worker; lock.unlock() }
        func claim() -> ClaudeSourceWorker? {
            lock.lock(); defer { lock.unlock() }
            guard !claimed, let worker else { return nil }
            claimed = true
            return worker
        }
        func finish(received: Bool, failure: Error?) {
            lock.lock(); self.received = received; self.failure = failure; lock.unlock()
        }
        func result() -> (Bool, Bool, Error?) {
            lock.lock(); defer { lock.unlock() }
            return (claimed, received, failure)
        }
    }

    func testSyntheticSocketOverrideRejectsPathsOutsideVerifiedRoot() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-channel-")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ProcessInfo.processInfo.environment
        let expected = root.deletingLastPathComponent().path
        XCTAssertEqual(try ClaudeLoopSocket.syntheticSocketBase(environment: environment), expected)
        var wrong = environment
        wrong["AITM_CLAUDE_SOCKET_TEST_ROOT"] = root.deletingLastPathComponent().deletingLastPathComponent().path
        XCTAssertThrowsError(try ClaudeLoopSocket.syntheticSocketBase(environment: wrong))
        wrong = environment
        wrong["AITM_MACOS_TEST_SANDBOX"] = "0"
        XCTAssertThrowsError(try ClaudeLoopSocket.syntheticSocketBase(environment: wrong))
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
        defer { try? FileManager.default.removeItem(at: root) }
        guard let configured = ProcessInfo.processInfo.environment["AITM_CLAUDE_CHANNEL_PROFILE"] else {
            throw CocoaError(.fileReadNoPermission)
        }
        let profile = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        let expected = root.deletingLastPathComponent().appendingPathComponent("claude-channel-profile", isDirectory: true)
        let values = try profile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard profile == expected, profile.resolvingSymlinksInPath().standardizedFileURL == profile,
              values.isDirectory == true, values.isSymbolicLink == false else {
            throw CocoaError(.fileReadNoPermission)
        }
        let digest = SHA256.hash(data: Data(profile.path.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let socketBase = ProcessInfo.processInfo.environment["AITM_CLAUDE_SOCKET_TEST_ROOT"] ?? "/private/tmp"
        let expectedSocketDirectory = socketBase + "/aitm-loop-\(geteuid())-\(suffix)"
        let address = sockaddr_un()
        XCTAssertLessThanOrEqual((expectedSocketDirectory + "/events.sock").utf8CString.count,
                                 MemoryLayout.size(ofValue: address.sun_path))
        var before = stat()
        let lookup = expectedSocketDirectory.withCString { lstat($0, &before) }
        let lookupError = errno
        guard lookup != 0, lookupError == ENOENT else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        var record = ClaudeHook.makeRecord(from: ["session_id": "fixture", "hook_event_name": "UserPromptSubmit"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        record["timestamp"] = formatter.string(from: Date().addingTimeInterval(-3))
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0a)
        try data.write(to: file)
        let state = Connection()
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: file), channelProfile: profile,
                                        requiresChannel: true, connection: { state.read() })
        var socketDirectory: String?
        defer {
            worker.close()
            let deadline = Date().addingTimeInterval(4)
            while !worker.channelStoppedForTesting && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if worker.channelStoppedForTesting, let directory = socketDirectory,
               directory == expectedSocketDirectory,
               let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
               Set(names).isSubset(of: ["owner.lock"]) {
                _ = (directory + "/owner.lock").withCString { unlink($0) }
                _ = directory.withCString { rmdir($0) }
            }
        }
        let first = try wait(worker)
        XCTAssertFalse(first.channelUnavailable, "The real isolated channel must open")
        socketDirectory = try ClaudeLoopSocket.directory(profile: profile, create: false)
        XCTAssertEqual(socketDirectory, expectedSocketDirectory)
        sendAndWait(worker, profile: profile, toolID: "first")

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
        XCTAssertTrue(busy.before.lifecycleSessions.contains("fixture"))
        XCTAssertFalse(busy.before.gap)

        sendAndWait(worker, profile: profile, toolID: "second")
        state.disconnect()
        let disconnected = try wait(worker)
        guard case .disconnected = disconnected.outcome else { return XCTFail("The source must disconnect") }
        XCTAssertTrue(disconnected.before.gap, "Stopping a channel with queued events must report a gap")
        XCTAssertTrue(disconnected.before.affectsAll)
    }

    @MainActor
    func testQueuedBashAfterSecondSnapshotPreventsApplyingOldStop() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-channel-")
        defer { try? FileManager.default.removeItem(at: root) }
        guard let configured = ProcessInfo.processInfo.environment["AITM_CLAUDE_CHANNEL_PROFILE"] else {
            throw CocoaError(.fileReadNoPermission)
        }
        let profile = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        let expected = root.deletingLastPathComponent().appendingPathComponent("claude-channel-profile", isDirectory: true)
        let values = try profile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard profile == expected, profile.resolvingSymlinksInPath().standardizedFileURL == profile,
              values.isDirectory == true, values.isSymbolicLink == false else { throw CocoaError(.fileReadNoPermission) }
        let digest = SHA256.hash(data: Data(profile.path.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let socketBase = ProcessInfo.processInfo.environment["AITM_CLAUDE_SOCKET_TEST_ROOT"] ?? "/private/tmp"
        let expectedSocketDirectory = socketBase + "/aitm-loop-\(geteuid())-\(suffix)"
        var before = stat()
        guard expectedSocketDirectory.withCString({ lstat($0, &before) }) != 0, errno == ENOENT else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var bytes = Data()
        for (name, offset) in [("UserPromptSubmit", -3.0), ("Stop", -2.0)] {
            var input: [String: Any] = ["session_id": "fixture", "hook_event_name": name]
            if name == "Stop" { input["background_tasks"] = [String](); input["session_crons"] = [String]() }
            var record = ClaudeHook.makeRecord(from: input)
            record["timestamp"] = formatter.string(from: Date().addingTimeInterval(offset))
            bytes.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); bytes.append(10)
        }
        try bytes.write(to: file)
        let precheck = try ClaudeTaskReader(eventFile: file).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(precheck.neutralEndedIDs.contains("claude:fixture"))
        let injection = Injection()
        let input: [String: Any] = ["session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                                    "tool_use_id": "synthetic-tool", "cwd": "/synthetic",
                                    "tool_input": ["command": "synthetic command"]]
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: file), channelProfile: profile,
                                        requiresChannel: true, afterSecondReadForTests: {
            guard let owner = injection.claim() else { return }
            do {
                var record = ClaudeHook.makeRecord(from: input)
                record["timestamp"] = formatter.string(from: Date().addingTimeInterval(-1))
                var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                data.append(10)
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close()
                ClaudeLoopClient.send(input, profile: profile)
                let deadline = Date().addingTimeInterval(3)
                while !owner.hasPendingOrdinaryForTesting("fixture") && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                injection.finish(received: owner.hasPendingOrdinaryForTesting("fixture"), failure: nil)
            } catch { injection.finish(received: false, failure: error) }
        }, connection: { .connected })
        injection.configure(worker)
        var socketDirectory: String?
        defer {
            worker.close()
            let deadline = Date().addingTimeInterval(4)
            while !worker.channelStoppedForTesting && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            if worker.channelStoppedForTesting, let directory = socketDirectory,
               directory == expectedSocketDirectory,
               let names = try? FileManager.default.contentsOfDirectory(atPath: directory),
               Set(names).isSubset(of: ["owner.lock"]) {
                _ = (directory + "/owner.lock").withCString { unlink($0) }
                _ = directory.withCString { rmdir($0) }
            }
        }
        let result = try wait(worker)
        socketDirectory = try ClaudeLoopSocket.directory(profile: profile, create: false)
        let state = injection.result()
        XCTAssertTrue(state.0 && state.1, "The synthetic Bash event must reach the actual channel")
        XCTAssertNil(state.2)
        XCTAssertTrue(result.after.lifecycleSessions.contains("fixture"))
        guard case .snapshot(let snapshot) = result.outcome else { return XCTFail("The changed session must be retained") }
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "claude:fixture" && $0.isUnconfirmed })
        XCTAssertFalse(snapshot.neutralEndedIDs.contains("claude:fixture"))
    }
}
#endif
