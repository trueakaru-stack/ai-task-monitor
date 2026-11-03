import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeLoopChannelTests: XCTestCase {
    func testPrivateChannelDeliveryGapAndFreshKeyAfterRestart() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        var channel: ClaudeLoopChannel? = try ClaudeLoopChannel(profile: profile)
        defer {
            if channel?.stop() != false { removeEmptyTestDirectory(directory) }
        }
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        var directoryInfo = stat()
        XCTAssertEqual(directory.withCString { lstat($0, &directoryInfo) }, 0)
        XCTAssertEqual(directoryInfo.st_uid, geteuid())
        XCTAssertEqual(directoryInfo.st_mode & mode_t(0o077), 0)
        let payload = input(event: "PreToolUse", id: "first")
        ClaudeLoopClient.send(payload, profile: profile)
        let first = try awaitEvent(try XCTUnwrap(channel))
        XCTAssertEqual(first.kind, .start)
        XCTAssertEqual(first.sessionID, "session-test")
        XCTAssertNotNil(first.fingerprint)
        ClaudeLoopClient.send(input(event: "PostToolUseFailure", id: "first"), profile: profile)
        let failed = try awaitEvent(try XCTUnwrap(channel))
        XCTAssertEqual(failed.fingerprint, first.fingerprint)
        XCTAssertEqual(failed.exitCode, 7)

        let socket = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        XCTAssertNotNil(ClaudeLoopSocket.read(socket, count: 32))
        XCTAssertTrue(ClaudeLoopSocket.write(socket, data: Data([0x88, 0x13, 0, 0])))
        Darwin.close(socket)
        let timeout = Date().addingTimeInterval(2)
        var sawGap = false
        while Date() < timeout && !sawGap {
            let batch = try XCTUnwrap(channel).drain()
            if batch.gap { sawGap = true; XCTAssertTrue(batch.events.isEmpty) }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(sawGap)
        XCTAssertTrue(try XCTUnwrap(channel).stop())
        channel = nil
        let absentStart = Date()
        ClaudeLoopClient.send(payload, profile: profile)
        XCTAssertLessThan(Date().timeIntervalSince(absentStart), 1)
        channel = try ClaudeLoopChannel(profile: profile)
        ClaudeLoopClient.send(payload, profile: profile)
        let afterRestart = try awaitEvent(try XCTUnwrap(channel))
        XCTAssertNotEqual(first.fingerprint, afterRestart.fingerprint)
    }

    func testForeignFileAtSocketPathIsPreserved() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        let foreignPath = directory + "/events.sock"
        let value = "synthetic foreign content"
        XCTAssertTrue(FileManager.default.createFile(atPath: foreignPath, contents: Data(value.utf8)))
        defer {
            if (try? String(contentsOfFile: foreignPath, encoding: .utf8)) == value { _ = foreignPath.withCString { unlink($0) } }
            removeEmptyTestDirectory(directory)
        }
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        XCTAssertEqual(try String(contentsOfFile: foreignPath, encoding: .utf8), value)
    }

    func testSymlinkAtSocketPathIsNotFollowedOrRemoved() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        let target = directory + "/sentinel"
        let socketPath = directory + "/events.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(atPath: socketPath, withDestinationPath: target)
        defer {
            _ = socketPath.withCString { unlink($0) }
            _ = target.withCString { unlink($0) }
            removeEmptyTestDirectory(directory)
        }
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: socketPath), target)
    }

    func testRejectsUnsafeDirectoryPermissionsWithoutChangingThem() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        XCTAssertEqual(directory.withCString { chmod($0, mode_t(0o755)) }, 0)
        defer {
            _ = directory.withCString { chmod($0, mode_t(0o700)) }
            removeEmptyTestDirectory(directory)
        }
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        var info = stat()
        XCTAssertEqual(directory.withCString { lstat($0, &info) }, 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o755))
    }

    func testOwnershipLockSymlinkIsNotFollowed() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        let target = directory + "/sentinel"
        let lock = directory + "/owner.lock"
        XCTAssertTrue(FileManager.default.createFile(atPath: target, contents: Data("keep".utf8)))
        try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: target)
        defer {
            _ = lock.withCString { unlink($0) }
            _ = target.withCString { unlink($0) }
            removeEmptyTestDirectory(directory)
        }
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lock), target)
    }

    func testDeadSocketIsRecoveredButLiveForeignSocketIsPreserved() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-test-\(UUID().uuidString)")
        let directory = try ClaudeLoopSocket.directory(profile: profile, create: true)
        let path = directory + "/events.sock"
        var descriptor: Int32 = -1
        var channel: ClaudeLoopChannel?
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if channel?.stop() != false {
                var info = stat()
                if path.withCString({ lstat($0, &info) }) == 0, info.st_uid == geteuid(),
                   (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) {
                    _ = path.withCString { unlink($0) }
                }
                removeEmptyTestDirectory(directory)
            }
        }
        func bindSocket() throws -> Int32 {
            var address = try ClaudeLoopSocket.address(path)
            let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { throw TestError.socket }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { Darwin.close(socketDescriptor); throw TestError.socket }
            return socketDescriptor
        }
        descriptor = try bindSocket()
        XCTAssertEqual(listen(descriptor, 1), 0)
        XCTAssertThrowsError(try ClaudeLoopChannel(profile: profile))
        var live = stat()
        XCTAssertEqual(path.withCString { lstat($0, &live) }, 0)
        Darwin.close(descriptor)
        descriptor = -1
        channel = try ClaudeLoopChannel(profile: profile)
        XCTAssertTrue(try XCTUnwrap(channel).stop())
        channel = nil
        XCTAssertNotEqual(path.withCString { lstat($0, &live) }, 0)
    }

    @MainActor
    func testSyntheticClaudeEventsReachCorrectTaskAndCanBeDismissed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try ClaudeLoopSocket.directory(profile: root, create: true)
        let events = root.appendingPathComponent("claude-events-v2.jsonl")
        try Data().write(to: events)
        let journal = DiagnosticJournal(directory: root.appendingPathComponent("diagnostics"))
        var store: TaskStore? = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: events), journal: journal,
                                          claudeLoopProfile: root)
        defer {
            store = nil
            removeEmptyTestDirectory(directory)
            try? FileManager.default.removeItem(at: root)
        }
        func send(_ event: String, id: String, session: String) throws {
            var payload = input(event: event, id: id)
            payload["session_id"] = session
            XCTAssertEqual(ClaudeHook.process(payload, directory: root), 0)
        }
        for index in 0..<5 {
            try send("PreToolUse", id: "first-\(index)", session: "first")
            try send("PostToolUseFailure", id: "first-\(index)", session: "first")
        }
        for index in 0..<3 {
            try send("PreToolUse", id: "second-\(index)", session: "second")
            try send("PostToolUseFailure", id: "second-\(index)", session: "second")
        }
        let timeout = Date().addingTimeInterval(3)
        while Date() < timeout {
            store?.refresh()
            if store?.tasks.first(where: { $0.id == "claude:first" })?.loopWarning != nil { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let first = try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:first" }))
        XCTAssertEqual(first.loopWarning, LoopWarning(threshold: 5, windowMinutes: 10))
        XCTAssertNil(store?.tasks.first(where: { $0.id == "claude:second" })?.loopWarning)
        store?.dismissLoop(for: "claude:first")
        XCTAssertNil(store?.tasks.first(where: { $0.id == "claude:first" })?.loopWarning)
        let persisted = try String(contentsOf: events, encoding: .utf8)
        for secret in ["synthetic secret command", "/synthetic/private", "synthetic secret output"] {
            XCTAssertFalse(persisted.contains(secret))
        }
    }

    private func awaitEvent(_ channel: ClaudeLoopChannel) throws -> ClaudeLoopEvent {
        let timeout = Date().addingTimeInterval(2)
        while Date() < timeout {
            let batch = channel.drain()
            if batch.gap { XCTFail("The synthetic channel lost an event."); throw TestError.gap }
            if let event = batch.events.first {
                XCTAssertEqual(batch.events.count, 1)
                return event
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw TestError.timeout
    }

    private func input(event: String, id: String) -> [String: Any] {
        ["session_id": "session-test", "hook_event_name": event, "tool_name": "Bash", "tool_use_id": id,
         "cwd": "/synthetic/private", "tool_input": ["command": "synthetic secret command"],
         "is_interrupt": false, "error": "Exit code 7\nsynthetic secret output"]
    }

    private func removeEmptyTestDirectory(_ path: String) {
        guard path.hasPrefix("/private/tmp/aitm-loop-"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: path),
              Set(names).isSubset(of: ["owner.lock"]) else { return }
        _ = (path + "/owner.lock").withCString { unlink($0) }
        _ = path.withCString { rmdir($0) }
    }

    private enum TestError: Error { case gap, timeout, socket }
}
