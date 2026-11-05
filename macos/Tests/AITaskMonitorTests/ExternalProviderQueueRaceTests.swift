import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class ExternalProviderQueueRaceTests: XCTestCase {
    private func frame(_ provider: String, _ session: String) -> Data {
        let payload = Data(#"{"version":1,"provider":"\#(provider)","session":"\#(session)","kind":"active"}"#.utf8)
        let n = payload.count
        return Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)]) + payload
    }

    func testQueuedOldConnectionCannotAcquireNewPermissionGeneration() throws {
        let directory = "/private/tmp/aitm-provider-queue-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let atCheckpoint = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        var first = true // Used only on the serial channel worker.
        let channel = try ExternalProviderChannel(directory: directory, testBeforeAccept: {
            guard first else { return }
            first = false
            atCheckpoint.signal()
            _ = proceed.wait(timeout: .now() + 5)
        })
        defer { proceed.signal(); _ = channel.stop() }
        channel.setAllowedProviders(["opencode", "deepseek"])

        let old = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(old) }
        XCTAssertTrue(ClaudeLoopSocket.write(old, data: frame("opencode", "old")))
        guard atCheckpoint.wait(timeout: .now() + 2) == .success else {
            XCTFail("The worker did not reach the test checkpoint.")
            return
        }
        XCTAssertEqual(channel.acceptedConnections, 0)

        let other = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(other) }
        XCTAssertTrue(ClaudeLoopSocket.write(other, data: frame("deepseek", "other")))
        channel.setAllowedProviders(["deepseek"])
        channel.setAllowedProviders(["opencode", "deepseek"])
        proceed.signal()

        XCTAssertNotEqual(ClaudeLoopSocket.read(old, count: 1), Data([0x06]), "A rejected old frame must not receive an acceptance ACK.")
        XCTAssertEqual(ClaudeLoopSocket.read(other, count: 1), Data([0x06]))
        let fresh = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(fresh) }
        XCTAssertTrue(ClaudeLoopSocket.write(fresh, data: frame("opencode", "fresh")))
        XCTAssertEqual(ClaudeLoopSocket.read(fresh, count: 1), Data([0x06]))
        let batch = channel.drain()
        XCTAssertFalse(batch.gap)
        XCTAssertEqual(Set(batch.events.map(\.session)), Set(["other", "fresh"]))
    }
}
#endif
