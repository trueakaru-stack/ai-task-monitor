import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic data and local AF_UNIX only. Not executed on the Windows host.
final class NeutralCompletedIndependentTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)

    private func send(_ provider: String, _ session: String, _ kind: String, directory: URL) throws {
        try transmit(["version": 1, "provider": provider, "session": session, "kind": kind], directory: directory)
    }

    private func transmit(_ value: [String: Any], directory: URL) throws {
        let socket = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory.path + "/events.sock"))
        defer { Darwin.close(socket) }
        let data = try JSONSerialization.data(withJSONObject: value), size = data.count
        let header = Data([UInt8(size & 255), UInt8((size >> 8) & 255),
                           UInt8((size >> 16) & 255), UInt8((size >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(socket, data: header + data))
        XCTAssertEqual(ClaudeLoopSocket.read(socket, count: 1), Data([0x06]))
    }

    private func assertHidden(_ tasks: [MonitoredTask], session: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(tasks.contains { $0.id == "deepseek:" + session || $0.id == "deepseek-unassigned:" + session },
                       "A completed task must not reappear without a new active observation", file: file, line: line)
    }

    func testConflictDoesNotRevivePreviouslyCompletedTask() throws {
        for terminal in ["idle", "completed", "failed", "interrupted"] {
            let dir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("aitm-neutral-ended-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: dir.path))
            defer { runtime.stop() }
            let ended = a + "_ended", neighbor = b + "_neighbor"
            _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
            try send("deepseek", ended, "active", directory: dir)
            try send("deepseek", ended, terminal, directory: dir)
            try send("deepseek", neighbor, "active", directory: dir)
            let before = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
            assertHidden(before, session: ended)
            XCTAssertTrue(try XCTUnwrap(before.first { $0.id == "deepseek:" + neighbor }).isActive)
            let after = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]],
                                         uncertainScopes: [.deepseek: [a]], ambiguousScopes: [.deepseek: [a]])
            assertHidden(after, session: ended)
            XCTAssertTrue(try XCTUnwrap(after.first { $0.id == "deepseek:" + neighbor }).isActive)
        }
    }

    func testLateTerminalForAnotherUnownedSessionCannotReviveCompletedTask() throws {
        let dir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-late-terminal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: dir.path))
        defer { runtime.stop() }
        let ended = a + "_ended", neighbor = b + "_neighbor"
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]])
        try send("deepseek", ended, "active", directory: dir)
        try send("deepseek", ended, "completed", directory: dir)
        try send("deepseek", neighbor, "active", directory: dir)
        assertHidden(runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [a, b]]), session: ended)
        let afterRemoval = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        assertHidden(afterRemoval, session: ended)
        // This old terminal is unrelated to the already completed session.
        try send("deepseek", a + "_different_old_session", "completed", directory: dir)
        let afterTerminal = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        assertHidden(afterTerminal, session: ended)
        assertHidden(afterTerminal, session: a + "_different_old_session")
        XCTAssertTrue(try XCTUnwrap(afterTerminal.first { $0.id == "deepseek:" + neighbor }).isActive)
    }

    func testOverflowNeutralizesExistingNeighborAndSignalsCapacity() throws {
        let dir = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("aitm-neutral-overflow-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: dir.path))
        defer { runtime.stop() }
        let neighbor = b + "_neighbor"
        _ = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        try send("deepseek", neighbor, "active", directory: dir)
        try transmit(["version": 1, "provider": "deepseek", "session": neighbor, "kind": "plan",
                      "steps": [["title": "SYNTHETIC_NEIGHBOR_PLAN", "status": "done"]]], directory: dir)
        for index in 1...256 {
            let suffix = String(index, radix: 16)
            let scope = String(repeating: "0", count: 32 - suffix.count) + suffix
            try send("deepseek", scope + "_unknown", "completed", directory: dir)
        }
        let before = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        let trusted = try XCTUnwrap(before.first { $0.id == "deepseek:" + neighbor })
        XCTAssertTrue(trusted.isActive)
        XCTAssertEqual(trusted.steps.first?.title, "SYNTHETIC_NEIGHBOR_PLAN")
        XCTAssertFalse(runtime.capacityLimitedProviders.contains(.deepseek))
        let scope257 = String(repeating: "0", count: 29) + "101"
        try send("deepseek", scope257 + "_unknown", "completed", directory: dir)
        let after = runtime.snapshot(allowed: [.deepseek], profileScopes: [.deepseek: [b]])
        let neutral = try XCTUnwrap(after.first { $0.id == "deepseek-unassigned:" + neighbor })
        XCTAssertTrue(neutral.isUnconfirmed)
        XCTAssertTrue(neutral.steps.isEmpty)
        XCTAssertFalse(neutral.planConfirmed)
        XCTAssertNil(neutral.progress)
        XCTAssertTrue(runtime.capacityLimitedProviders.contains(.deepseek))
    }
}
