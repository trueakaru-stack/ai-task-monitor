import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderTaskStoreTests: XCTestCase {
    private func send(_ json: String, directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(json.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255), UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    @MainActor
    func testOpenCodeConnectionAndFailureDoNotMisrepresentTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-store-" + UUID().uuidString, isDirectory: true)
        let directory = "/private/tmp/aitm-provider-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var activeRuntime: ExternalProviderRuntime?
        defer {
            activeRuntime?.stop()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: directory))
            try? FileManager.default.removeItem(at: root)
        }
        var connection = OpenCodeIntegration.State.disconnected
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableExternalProviders: true,
                              openCodeConnection: { connection },
                              makeExternalRuntime: {
                                  let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory))
                                  activeRuntime = runtime
                                  return runtime
                              })
        XCTAssertNil(activeRuntime)
        connection = .connected
        store.refresh()
        XCTAssertNotNil(activeRuntime)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"waiting"}"#, directory: directory)
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"active"}]}"#, directory: directory)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            store.refresh()
            if store.tasks.contains(where: { $0.id == "opencode:one" && $0.steps.count == 1 }) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let waiting = try XCTUnwrap(store.tasks.first { $0.id == "opencode:one" })
        XCTAssertTrue(waiting.isWaiting)
        XCTAssertFalse(waiting.isActive)
        XCTAssertTrue(waiting.planConfirmed)
        connection = .partial
        store.refresh()
        let uncertain = try XCTUnwrap(store.tasks.first { $0.id == "opencode:one" })
        XCTAssertTrue(uncertain.isUnconfirmed)
        XCTAssertFalse(uncertain.isActive)
        XCTAssertFalse(uncertain.isWaiting)
        XCTAssertFalse(uncertain.planConfirmed)
        XCTAssertTrue(store.unavailableSources.contains(.opencode))
        connection = .disconnected
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .opencode })
        XCTAssertFalse(store.unavailableSources.contains(.opencode))
        connection = .connected
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .opencode })
    }
}
