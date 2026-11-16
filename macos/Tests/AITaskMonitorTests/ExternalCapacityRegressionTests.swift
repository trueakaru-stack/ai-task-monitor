import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalCapacityRegressionTests: XCTestCase {
    private let scopeA = String(repeating: "a", count: 32)
    private let scopeB = String(repeating: "b", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ provider: String, _ session: String, _ kind: String = "active",
                       tick: Int64 = 0, epoch: Int64 = 0) -> ExternalProviderEvent {
        ExternalProviderEvent(provider: provider, session: session, kind: kind, turn: "synthetic",
                              call: "", action: "", steps: nil, tick: tick, epoch: epoch, request: "")
    }

    private func directory(_ name: String) throws -> String {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["AITM_SYNTHETIC_TEST_ROOT"])
        XCTAssertTrue(root.hasPrefix("/Users/runner/work/_temp/aitm-card-tests."))
        XCTAssertNil(ProcessInfo.processInfo.environment["HOME"])
        XCTAssertNil(ProcessInfo.processInfo.environment["CODEX_HOME"])
        return URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(name + "-" + String(UUID().uuidString.prefix(8))).path
    }

    func testVisibleKimiCardSurvivesCapacityAndLateTerminal() {
        let store = ExternalProviderStateStore()
        store.retainProviders(["kimi"])
        for index in 0..<256 {
            XCTAssertTrue(store.apply(event("kimi", scopeA + "_s\(index)"), now: now.addingTimeInterval(Double(index))))
        }
        XCTAssertTrue(store.apply(event("kimi", scopeA + "_s0", "completed"), now: now))
        XCTAssertFalse(store.apply(event("kimi", scopeA + "_new"), now: now.addingTimeInterval(257)))
        let tasks = store.snapshot(now: now.addingTimeInterval(257))
        XCTAssertEqual(tasks.count, 256)
        XCTAssertTrue(tasks.contains { $0.session == scopeA + "_s0" && $0.status == "unknown" })
        XCTAssertFalse(tasks.contains { $0.session == scopeA + "_new" })
        XCTAssertTrue(store.capacityLimitedProviders.contains("kimi"))
    }

    func testV1CapacityWarningSurvivesUnavailableAndReconnect() {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode"])
        store.markGap(provider: "opencode")
        for index in 0..<256 {
            XCTAssertTrue(store.apply(event("opencode", "s\(index)"), now: now))
        }
        XCTAssertFalse(store.apply(event("opencode", "missing"), now: now))
        XCTAssertEqual(store.capacityLimitedProviders, ["opencode"])
        store.retainProviders([])
        XCTAssertEqual(store.capacityLimitedProviders, ["opencode"])
        store.retainProviders(["opencode"])
        XCTAssertEqual(store.capacityLimitedProviders, ["opencode"])
        XCTAssertEqual(store.snapshot(now: now).count, 256)
    }

    func testCapacityLossInScopeADoesNotUnconfirmScopeB() {
        let store = ExternalProviderStateStore()
        store.retainProviders(["deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [scopeA, scopeB])
        XCTAssertTrue(store.apply(event("deepseek", scopeB + "_healthy"), now: now))
        for index in 0..<255 {
            XCTAssertTrue(store.apply(event("kimi", scopeA + "_k\(index)"), now: now))
        }
        XCTAssertFalse(store.apply(event("deepseek", scopeA + "_lost"), now: now))
        let healthy = store.snapshot(now: now).first { $0.session == scopeB + "_healthy" }
        XCTAssertEqual(healthy?.status, "active")
        XCTAssertTrue(store.capacityLimitedProviders.contains("deepseek"))
    }

    func testHermesWaitsForAnObserverStartedAfterMonitoring() {
        let store = ExternalProviderStateStore()
        store.retainProviders(["hermes"])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA])
        let session = scopeA + "_synthetic"
        XCTAssertFalse(store.apply(event("hermes", session, "started", tick: 1, epoch: 1), now: now))
        XCTAssertTrue(store.snapshot(now: now).isEmpty)
        let fresh = Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(store.apply(event("hermes", session, "started", tick: fresh, epoch: fresh), now: now))
        XCTAssertEqual(store.snapshot(now: now).first?.status, "active")
    }

    private func generation(_ path: String, _ scope: ExternalProviderV2Scope) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path + "/generations-v2.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let values = try XCTUnwrap(object["generations"] as? [String: String])
        return try XCTUnwrap(values[scope.provider + ":" + scope.scope])
    }

    private func send(_ runtime: ExternalProviderV2Runtime, _ scope: ExternalProviderV2Scope,
                      _ generation: String, kind: String, ticket: String? = nil,
                      sequence: Int? = nil, session: String = "task") throws -> [String: Any] {
        var frame: [String: Any] = ["version": 2, "provider": scope.provider, "scope": scope.scope,
            "generation": generation, "instance": String(repeating: "c", count: 32), "kind": kind]
        if kind == "event" {
            frame["ticket"] = ticket.map { $0 as Any } ?? NSNull()
            frame["seq"] = sequence.map { $0 as Any } ?? NSNull()
            frame["event"] = ["version": 1, "provider": scope.provider,
                              "session": scope.scope + "_" + session, "kind": "active"]
        }
        return runtime.broker.receive(try JSONSerialization.data(withJSONObject: frame),
                                      now: DispatchTime.now().uptimeNanoseconds)
    }

    func testV2CapacityWarningSurvivesScopeRemovalReconnectAndRestart() throws {
        let path = try directory("v2")
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        let a = ExternalProviderV2Scope(provider: "deepseek", scope: scopeA)
        let b = ExternalProviderV2Scope(provider: "deepseek", scope: scopeB)
        try runtime.setScopes([a, b])
        let ga = try generation(path, a), gb = try generation(path, b)
        _ = try send(runtime, b, gb, kind: "hello")
        XCTAssertTrue(runtime.acknowledge(b))
        let ticket = try XCTUnwrap(send(runtime, b, gb, kind: "hello")["ticket"] as? String)
        XCTAssertEqual(try send(runtime, b, gb, kind: "event", ticket: ticket, sequence: 1, session: "healthy")["accepted"] as? Bool, true)
        for index in 0..<255 {
            XCTAssertEqual(try send(runtime, a, ga, kind: "event", session: "old\(index)")["accepted"] as? Bool, true)
        }
        XCTAssertEqual(runtime.snapshot().count, 256)
        XCTAssertEqual(try send(runtime, a, ga, kind: "event", session: "lost")["accepted"] as? Bool, true)
        let limited = runtime.snapshot()
        XCTAssertTrue(runtime.capacityLimitedScopes.contains(a))
        XCTAssertTrue(limited.contains { $0.id == "deepseek:" + scopeB + "_healthy" && $0.isActive && !$0.isUnconfirmed })
        try runtime.setScopes([b])
        XCTAssertTrue(runtime.capacityLimitedScopes.contains(a))
        try runtime.setScopes([a, b])
        XCTAssertTrue(runtime.capacityLimitedScopes.contains(a))
        let next = try generation(path, a)
        _ = try send(runtime, a, next, kind: "hello")
        XCTAssertTrue(runtime.acknowledge(a))
        XCTAssertTrue(runtime.capacityLimitedScopes.contains(a))
        XCTAssertTrue(runtime.snapshot().contains { $0.id == "deepseek:" + scopeB + "_healthy" && $0.isActive && !$0.isUnconfirmed })
    }

    #if DEBUG
    @MainActor
    func testTaskStoreKeepsCapacityWarningAfterPartialAndReconnect() throws {
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["opencode"])
        seed.markGap(provider: "opencode")
        for index in 0..<256 { XCTAssertTrue(seed.apply(event("opencode", "s\(index)"), now: now)) }
        XCTAssertFalse(seed.apply(event("opencode", "lost"), now: now))
        var connection: OpenCodeIntegration.State = .connected
        var first = true
        let root = try directory("v1")
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: root + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: root + "/events")),
                              previewTasks: [], openCodeConnection: { connection },
                              additionalExternalConnections: [.deepseek: { .disconnected }, .kimi: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: {
            let path = root + "-" + String(UUID().uuidString.prefix(6))
            let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
            if first { runtime.adoptState(seed); first = false }
            return runtime
        })
        let initial = store.testExternalFallback(previous: [], deepSeekRosters: [])
        XCTAssertTrue(initial.1.contains(.opencode))
        XCTAssertEqual(initial.0.count, 256)
        connection = .partial
        let partial = store.testExternalFallback(previous: initial.0, deepSeekRosters: [])
        XCTAssertTrue(partial.1.contains(.opencode))
        XCTAssertEqual(partial.0.count, 256)
        connection = .connected
        let restored = store.testExternalFallback(previous: partial.0, deepSeekRosters: [])
        XCTAssertTrue(restored.1.contains(.opencode))
        XCTAssertEqual(restored.0.count, 256)
    }
    #endif
}
