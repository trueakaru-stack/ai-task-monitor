import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderV2ChannelTests: XCTestCase {
    private let generation = String(repeating: "a", count: 32)
    private let instance = String(repeating: "b", count: 32)
    private let ticket = String(repeating: "c", count: 32)
    private let scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")

    private func directory() -> String { "/private/tmp/aitm-provider-\(UUID().uuidString)" }

    private func frame(_ kind: String) -> [String: Any] {
        ["version": 2, "provider": "opencode", "scope": "global", "generation": generation,
         "instance": instance, "kind": kind]
    }

    private func send(_ value: [String: Any], directory: String) throws -> [String: Any] {
        let fd = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events-v2.sock"))
        defer { Darwin.close(fd) }
        let body = try JSONSerialization.data(withJSONObject: value), n = UInt32(body.count)
        let header = Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(fd, data: header + body))
        let bytes = [UInt8](try XCTUnwrap(ClaudeLoopSocket.read(fd, count: 4)))
        let length = Int(bytes[0]) | (Int(bytes[1]) << 8) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 24)
        guard (2...4096).contains(length) else { throw CocoaError(.fileReadCorruptFile) }
        let reply = try XCTUnwrap(ClaudeLoopSocket.read(fd, count: length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    private func wait(_ message: String, predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline { if predicate() { return }; Thread.sleep(forTimeInterval: 0.01) }
        XCTFail(message)
        throw CocoaError(.fileReadUnknown)
    }

    func testLocalSocketRequiresActionAndRejectsStaleTicket() throws {
        let path = directory(), broker = ExternalProviderV2Broker()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(broker.configure(scope, generation: generation))
        let channel = try ExternalProviderV2Channel(directory: path, broker: broker)
        defer { _ = channel.stop() }
        XCTAssertEqual(try send(frame("hello"), directory: path)["state"] as? String, "wait")
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: generation, ticket: ticket))
        XCTAssertEqual(try send(frame("hello"), directory: path)["ticket"] as? String, ticket)
        var event = frame("event")
        event["ticket"] = ticket; event["seq"] = 1
        event["event"] = ["version": 1, "provider": "opencode", "session": "synthetic", "kind": "active"]
        XCTAssertEqual(try send(event, directory: path)["accepted"] as? Bool, true)
        let notice = try XCTUnwrap(broker.drain().first { $0.event != nil })
        XCTAssertTrue(broker.isCurrent(notice))
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: generation, ticket: String(repeating: "d", count: 32)))
        XCTAssertFalse(broker.isCurrent(notice))
        XCTAssertEqual(try send(event, directory: path)["accepted"] as? Bool, false)
    }

    func testJavaScriptSenderUsesRealSocketWithoutProfileOrNetwork() throws {
        let environment = ProcessInfo.processInfo.environment
        let node = try XCTUnwrap(environment["AITM_TEST_NODE"], "Set an absolute path to test-only Node.")
        let script = try XCTUnwrap(environment["AITM_V2_SENDER_FIXTURE"], "Set the absolute test fixture path.")
        XCTAssertTrue(node.hasPrefix("/")); XCTAssertTrue(script.hasPrefix("/"))
        let path = directory(), broker = ExternalProviderV2Broker()
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(broker.configure(scope, generation: generation))
        let channel = try ExternalProviderV2Channel(directory: path, broker: broker)
        defer { _ = channel.stop() }
        let generations = ExternalProviderV2GenerationFile(directory: URL(fileURLWithPath: path, isDirectory: true))
        try generations.replace([scope: generation])
        let input = Pipe(), child = Process()
        child.executableURL = URL(fileURLWithPath: node)
        child.arguments = [script, path, generation]
        child.environment = [:]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        var unconfirmed: ExternalProviderV2Notice?
        try wait("No unconfirmed callback before the action") {
            for notice in broker.drain() where notice.event?.session == "before" { unconfirmed = notice }
            return unconfirmed != nil && broker.hasSeenInstance(scope, generation: generation)
        }
        XCTAssertFalse(broker.isCurrent(try XCTUnwrap(unconfirmed)))
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: generation, ticket: ticket))
        try input.fileHandleForWriting.write(contentsOf: Data("fresh\n".utf8))
        var observed: ExternalProviderV2Notice?
        try wait("No fresh ticketed callback after the action") {
            for notice in broker.drain() where notice.event?.session == "after" { observed = notice }
            return observed != nil
        }
        XCTAssertTrue(broker.isCurrent(try XCTUnwrap(observed)))
    }
}
