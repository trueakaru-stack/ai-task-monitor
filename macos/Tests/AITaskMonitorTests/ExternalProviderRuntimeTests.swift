import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderRuntimeTests: XCTestCase {
    private func send(_ json: String, directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(json.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255), UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    private func waitFor(_ id: String, runtime: ExternalProviderRuntime, stepCount: Int? = nil) throws -> [MonitoredTask] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let tasks = runtime.snapshot(allowed: [.opencode, .deepseek])
            if tasks.contains(where: { task in task.id == id && (stepCount.map { task.steps.count == $0 } ?? true) }) { return tasks }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "ExternalProviderRuntimeTests", code: 1)
    }

    func testConnectedSourcesWaitingPlansAndDelayedReads() throws {
        let directory = "/private/tmp/aitm-provider-runtime-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let channel = try ExternalProviderChannel(directory: directory)
        let runtime = ExternalProviderRuntime(channel: channel)
        defer { runtime.stop() }
        XCTAssertTrue(runtime.snapshot(allowed: [.opencode, .deepseek]).isEmpty)
        try send(#"{"version":1,"provider":"hermes","session":"disabled","kind":"active"}"#, directory: directory)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(runtime.snapshot(allowed: [.opencode, .deepseek]).isEmpty)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c1","action":"command"}"#, directory: directory)
        XCTAssertTrue(try XCTUnwrap(waitFor("opencode:one", runtime: runtime).first).isActive)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}"#, directory: directory)
        let planned = try XCTUnwrap(waitFor("opencode:one", runtime: runtime, stepCount: 2).first)
        XCTAssertEqual(planned.progress, 50)
        XCTAssertEqual(planned.progressKind, .exact)
        try send(#"{"version":1,"provider":"deepseek","session":"two","kind":"waiting"}"#, directory: directory)
        let tasks = try waitFor("deepseek:two", runtime: runtime)
        let waiting = try XCTUnwrap(tasks.first { $0.provider == .deepseek })
        XCTAssertTrue(waiting.isWaiting)
        XCTAssertFalse(waiting.isActive)
        XCTAssertFalse(waiting.startKey.isEmpty)
        let aged = runtime.snapshot(allowed: [.opencode, .deepseek], now: Date().addingTimeInterval(1_860))
        XCTAssertTrue(aged.allSatisfy { !$0.isActive && !$0.isWaiting && $0.isUnconfirmed })
        XCTAssertFalse(runtime.snapshot(allowed: [.deepseek]).contains { $0.provider == .opencode })
        try send(#"{"version":1,"provider":"opencode","session":"while_disconnected","kind":"active"}"#, directory: directory)
        try send(#"{"version":1,"provider":"deepseek","session":"barrier","kind":"active"}"#, directory: directory)
        let deadline = Date().addingTimeInterval(3)
        var barrierSeen = false
        while Date() < deadline {
            if runtime.snapshot(allowed: [.deepseek]).contains(where: { $0.id == "deepseek:barrier" }) {
                barrierSeen = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(barrierSeen)
        XCTAssertFalse(runtime.snapshot(allowed: [.deepseek, .opencode]).contains { $0.provider == .opencode })
        try send(#"{"version":1,"provider":"opencode","session":"fresh","kind":"active"}"#, directory: directory)
        XCTAssertTrue(try waitFor("opencode:fresh", runtime: runtime).contains { $0.id == "opencode:fresh" })
        XCTAssertTrue(runtime.stop())
    }
}
