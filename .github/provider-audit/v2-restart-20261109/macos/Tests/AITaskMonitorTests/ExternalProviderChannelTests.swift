import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderChannelTests: XCTestCase {
    private func send(_ text: String, directory: String, expectAcknowledgement: Bool = true) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(text.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255), UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        if expectAcknowledgement { XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06])) }
        else { XCTAssertNotEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06])) }
    }

    private func awaitBatch(_ channel: ExternalProviderChannel) throws -> ExternalProviderChannel.Batch {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let batch = channel.drain()
            if batch.gap || !batch.events.isEmpty { return batch }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(domain: "ExternalProviderChannelTests", code: 1)
    }

    func testLocalEventsAndShutdown() throws {
        let directory = "/private/tmp/aitm-provider-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let channel = try ExternalProviderChannel(directory: directory)
        defer { channel.stop() }
        channel.setAllowedProviders(["kimi", "deepseek", "hermes", "opencode"])
        XCTAssertThrowsError(try ExternalProviderChannel(directory: directory))
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"active"}"#, directory: directory)
        let first = try awaitBatch(channel)
        XCTAssertFalse(first.gap)
        XCTAssertEqual(first.events.first?.session, "one")
        let received = try XCTUnwrap(first.events.first?.receivedAt)
        XCTAssertLessThan(abs(received.timeIntervalSinceNow), 5)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"active","prompt":"secret"}"#, directory: directory, expectAcknowledgement: false)
        let invalid = try awaitBatch(channel)
        XCTAssertTrue(invalid.gap)
        XCTAssertTrue(invalid.events.isEmpty)
        try send(#"{"version":1,"provider":"deepseek","session":"two","kind":"plan","steps":[{"title":"Test","status":"done"}]}"#, directory: directory)
        let recovered = try awaitBatch(channel)
        XCTAssertFalse(recovered.gap)
        XCTAssertEqual(recovered.events.first?.steps?.first?.status, "done")
        channel.setAllowedProviders(["deepseek"])
        try send(#"{"version":1,"provider":"opencode","session":"disconnected","kind":"active"}"#, directory: directory, expectAcknowledgement: false)
        try send(#"{"version":1,"provider":"deepseek","session":"barrier","kind":"active"}"#, directory: directory)
        let barrier = try awaitBatch(channel)
        XCTAssertEqual(barrier.events.map(\.session), ["barrier"])
        channel.setAllowedProviders(["deepseek", "opencode"])
        XCTAssertTrue(channel.drain().events.isEmpty)
        try send(#"{"version":1,"provider":"opencode","session":"fresh","kind":"active"}"#, directory: directory)
        XCTAssertEqual(try awaitBatch(channel).events.first?.session, "fresh")
        let acceptedBefore = channel.acceptedConnections
        let inFlight = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(inFlight) }
        let body = Data(#"{"version":1,"provider":"opencode","session":"old_generation","kind":"active"}"#.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255), UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(inFlight, data: header))
        let deadline = Date().addingTimeInterval(0.3)
        while channel.acceptedConnections <= acceptedBefore && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertGreaterThan(channel.acceptedConnections, acceptedBefore)
        channel.setAllowedProviders(["deepseek"])
        channel.setAllowedProviders(["deepseek", "opencode"])
        XCTAssertTrue(ClaudeLoopSocket.write(inFlight, data: body))
        XCTAssertNotEqual(ClaudeLoopSocket.read(inFlight, count: 1), Data([0x06]))
        try send(#"{"version":1,"provider":"deepseek","session":"after_generation","kind":"active"}"#, directory: directory)
        XCTAssertEqual(try awaitBatch(channel).events.map(\.session), ["after_generation"])
        XCTAssertTrue(channel.stop())
        let reopened = try ExternalProviderChannel(directory: directory)
        XCTAssertTrue(reopened.stop())
    }

    func testSymlinkDirectoryIsRejected() throws {
        let destination = "/private/tmp/aitm-provider-target-\(UUID().uuidString)"
        let link = "/private/tmp/aitm-provider-link-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: destination)
        }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: destination)
        XCTAssertThrowsError(try ExternalProviderChannel(directory: link))
    }
}
