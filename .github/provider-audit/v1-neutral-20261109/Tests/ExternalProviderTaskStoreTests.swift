import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

private final class KimiInspectionFixture {
    private let lock = NSLock()
    private var value: Result<KimiConnection, Error>
    init(_ value: Result<KimiConnection, Error>) { self.value = value }
    func set(_ value: Result<KimiConnection, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func inspect() throws -> KimiConnection { lock.lock(); defer { lock.unlock() }; return try value.get() }
}

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
    func testKimiManualConnectionPreservesOnlyUnconfirmedTasks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-kimi-store-" + UUID().uuidString, isDirectory: true)
        let directory = "/private/tmp/aitm-kimi-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var activeRuntime: ExternalProviderRuntime?
        defer {
            activeRuntime?.stop()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: directory))
            try? FileManager.default.removeItem(at: root)
        }
        let scope = String(repeating: "a", count: 32)
        let fixture = KimiInspectionFixture(.success(KimiConnection(state: "connected", scope: scope)))
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableExternalProviders: true,
                              openCodeConnection: { .connected },
                              makeExternalRuntime: {
                                  let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory))
                                  activeRuntime = runtime
                                  return runtime
                              }, inspectKimiConnection: { try fixture.inspect() }, kimiScanInterval: 0.1)
        func wait(_ message: String, until predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !predicate() {
                store.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(predicate(), message)
        }
        wait("Kimi was not connected") { store.kimiState == "connected" && activeRuntime != nil }
        let session = scope + "_synthetic"
        try send(#"{"version":1,"provider":"kimi","session":"\#(session)","kind":"started"}"#, directory: directory)
        try send(#"{"version":1,"provider":"kimi","session":"\#(String(repeating: "b", count: 32))_other","kind":"started"}"#, directory: directory)
        wait("Kimi task did not arrive") { store.tasks.contains { $0.provider == .kimi } }
        XCTAssertEqual(store.tasks.filter { $0.provider == .kimi }.count, 1)
        let task = try XCTUnwrap(store.tasks.first { $0.provider == .kimi })
        XCTAssertTrue(task.isUnconfirmed)
        XCTAssertFalse(task.isActive)
        XCTAssertFalse(task.isWaiting)
        XCTAssertNil(task.progress)
        fixture.set(.failure(KimiIntegrationError(code: "modified-bundle")))
        wait("A failed check was not reported") { store.unavailableSources.contains(.kimi) }
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.provider == .kimi }).isUnconfirmed)
        fixture.set(.success(KimiConnection(state: "disabled", scope: nil)))
        wait("A disabled plugin remained connected") { store.kimiState == "disabled" && !store.tasks.contains { $0.provider == .kimi } }
        XCTAssertFalse(store.unavailableSources.contains(.kimi))
        XCTAssertNotNil(activeRuntime, "Other connected sources must retain the receiver")
        fixture.set(.success(KimiConnection(state: "connected", scope: scope)))
        wait("Kimi did not reconnect") { store.kimiState == "connected" }
        XCTAssertFalse(store.tasks.contains { $0.provider == .kimi }, "Reconnect must not resurrect an old task")
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
        XCTAssertTrue(store.tasks.contains { $0.id == "opencode:one" && $0.isUnconfirmed })
    }

    @MainActor
    func testInjectedProviderWithoutScopeIsHiddenAndDoesNotStopOtherSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-store-multi-" + UUID().uuidString, isDirectory: true)
        let directory = "/private/tmp/aitm-provider-multi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var activeRuntime: ExternalProviderRuntime?
        defer {
            activeRuntime?.stop()
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: directory))
            try? FileManager.default.removeItem(at: root)
        }
        var openCode = ExternalProviderConnectionState.connected
        var hermes = ExternalProviderConnectionState.connected
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("claude.jsonl")),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")),
                              enableExternalProviders: true,
                              openCodeConnection: { openCode },
                              additionalExternalConnections: [.hermes: { hermes }],
                              makeExternalRuntime: {
                                  let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: directory))
                                  activeRuntime = runtime
                                  return runtime
                              })
        try send(#"{"version":1,"provider":"opencode","session":"one","kind":"started"}"#, directory: directory)
        let firstEpoch = DispatchTime.now().uptimeNanoseconds
        try send(#"{"version":1,"provider":"hermes","session":"two","kind":"started","turn":"turn_1","epoch":\#(firstEpoch),"tick":\#(firstEpoch + 1)}"#, directory: directory)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            store.refresh()
            if store.tasks.contains(where: { $0.id == "opencode:one" }) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.id == "opencode:one" }).isActive)
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "No profile metadata means no verified Hermes identity")

        hermes = .partial
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes })
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.id == "opencode:one" }).isActive)
        XCTAssertTrue(store.unavailableSources.contains(.hermes))
        XCTAssertFalse(store.unavailableSources.contains(.opencode))
        try send(#"{"version":1,"provider":"opencode","session":"three","kind":"started"}"#, directory: directory)
        store.refresh()
        XCTAssertTrue(try XCTUnwrap(store.tasks.first { $0.id == "opencode:three" }).isActive)

        hermes = .disconnected
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes })
        XCTAssertTrue(store.tasks.contains { $0.id == "opencode:one" && $0.isActive })
        hermes = .connected
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes }, "Reconnect must not resurrect an old task")
        let secondEpoch = DispatchTime.now().uptimeNanoseconds
        try send(#"{"version":1,"provider":"hermes","session":"new","kind":"started","turn":"turn_2","epoch":\#(secondEpoch),"tick":\#(secondEpoch + 1)}"#, directory: directory)
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes })
        openCode = .disconnected
        store.refresh()
        XCTAssertFalse(store.tasks.contains { $0.provider == .opencode })
        XCTAssertFalse(store.tasks.contains { $0.provider == .hermes })
    }
}
