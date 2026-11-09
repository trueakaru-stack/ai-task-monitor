import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class V1RuntimeProtectionTests: XCTestCase {
    private func send(_ json: String, directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(json.utf8), size = body.count
        let header = Data([UInt8(size & 255), UInt8((size >> 8) & 255), UInt8((size >> 16) & 255), UInt8((size >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    private func waitForTask(_ id: String, runtime: ExternalProviderRuntime) throws -> MonitoredTask {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let task = runtime.snapshot(allowed: [.opencode]).first(where: { $0.id == id }) { return task }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "V1RuntimeProtectionTests", code: 1)
    }

    func testParkedStorePreservesUnconfirmedCardAfterReceiverRestart() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-v1-synthetic-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        _ = first.snapshot(allowed: [.opencode])
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"active"}"#, directory: directory.path)
        XCTAssertTrue(try waitForTask("opencode:one", runtime: first).isActive)
        let saved = first.parkState(markTransportGap: false)
        XCTAssertTrue(first.stop())
        let next = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory.path))
        defer { next.stop() }
        next.adoptState(saved)
        let restored = try XCTUnwrap(next.snapshot(allowed: [.opencode]).first { $0.id == "opencode:one" })
        XCTAssertTrue(restored.isUnconfirmed)
        XCTAssertFalse(restored.isActive)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"completed"}"#, directory: directory.path)
        let after = try waitForTask("opencode:one", runtime: next)
        XCTAssertTrue(after.isUnconfirmed)
        XCTAssertFalse(after.isActive)
    }
}
