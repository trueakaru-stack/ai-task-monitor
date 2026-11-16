import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
@testable import AITaskMonitor

private final class CapacityKimiFixture {
    private let lock = NSLock()
    private var value: Result<KimiConnection, Error>
    init(_ value: Result<KimiConnection, Error>) { self.value = value }
    func set(_ value: Result<KimiConnection, Error>) {
        lock.lock(); self.value = value; lock.unlock()
    }
    func inspect() throws -> KimiConnection {
        lock.lock(); defer { lock.unlock() }
        return try value.get()
    }
}

final class ExternalCapacityRegressionTests: XCTestCase {
    private let scopeA = String(repeating: "a", count: 32)
    private let scopeB = String(repeating: "b", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ provider: String, _ session: String, _ kind: String = "active",
                       tick: Int64 = 0, epoch: Int64 = 0) -> ExternalProviderEvent {
        ExternalProviderEvent(provider: provider, session: session, kind: kind, turn: "synthetic",
                              call: "", action: "", steps: nil, tick: tick, epoch: epoch, request: "")
    }

    private enum FixtureFailure: Error { case unsafeEnvironment, unsafeRoot, existingFixture }

    func directory(_ name: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS",
              environment["HOME"] == nil, environment["CODEX_HOME"] == nil,
              let root = environment["AITM_SYNTHETIC_TEST_ROOT"],
              let marker = environment["AITM_CI_DENIED_FILE"],
              marker.hasPrefix("/Users/runner/work/_temp/aitm-profile-deny.") else {
            throw FixtureFailure.unsafeEnvironment
        }
        let descriptor = marker.withCString { open($0, O_RDONLY) }
        let denied = errno
        if descriptor >= 0 { close(descriptor) }
        guard descriptor < 0, denied == EACCES || denied == EPERM else { throw FixtureFailure.unsafeEnvironment }
        let url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let taskDirectory = url.deletingLastPathComponent()
        guard url.path == root, url.resolvingSymlinksInPath().path == root, url.lastPathComponent == "temp",
              taskDirectory.deletingLastPathComponent().path == "/Users/runner/work/_temp",
              taskDirectory.lastPathComponent.range(of: #"^aitm-card-tests\.[A-Za-z0-9]{8}$"#, options: .regularExpression) != nil else {
            throw FixtureFailure.unsafeRoot
        }
        var current = ""
        for component in url.path.split(separator: "/") {
            current += "/" + String(component)
            var information = stat()
            guard current.withCString({ lstat($0, &information) }) == 0,
                  (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw FixtureFailure.unsafeRoot
            }
        }
        guard name.range(of: #"^[a-z][a-z0-9-]{0,24}$"#, options: .regularExpression) != nil else {
            throw FixtureFailure.unsafeRoot
        }
        let fixture = url.appendingPathComponent(name + "-" + String(UUID().uuidString.prefix(8))).path
        guard fixture.hasPrefix(root + "/") else { throw FixtureFailure.unsafeRoot }
        var information = stat()
        guard fixture.withCString({ lstat($0, &information) }) != 0, errno == ENOENT else {
            throw FixtureFailure.existingFixture
        }
        return fixture
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

    func testReclaimingHermesTerminalDoesNotDegradeOtherScope() {
        let store = ExternalProviderStateStore()
        store.retainProviders(["hermes", "kimi"])
        store.retainSessionScopes(provider: "hermes", scopes: [scopeA, scopeB])
        let tick = Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(store.apply(event("hermes", scopeA + "_finished", "started", tick: tick, epoch: tick), now: now))
        XCTAssertTrue(store.apply(event("hermes", scopeA + "_finished", "completed", tick: tick + 1, epoch: tick), now: now.addingTimeInterval(1)))
        XCTAssertTrue(store.apply(event("hermes", scopeB + "_healthy", "started", tick: tick + 2, epoch: tick + 2), now: now.addingTimeInterval(2)))
        for index in 0..<254 {
            XCTAssertTrue(store.apply(event("kimi", scopeA + "_k\(index)"), now: now.addingTimeInterval(Double(index + 3))))
        }
        XCTAssertTrue(store.apply(event("kimi", scopeA + "_new"), now: now.addingTimeInterval(300)))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(300)).first { $0.session == scopeB + "_healthy" }?.status, "active")
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
        defer { _ = runtime.stop() }
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


    func testV2WarningHistoryStaysBoundedAndSignalsUntrackedScopes() throws {
        let path = try directory("v2bound")
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop() }
        let scopes = (0..<257).map { ExternalProviderV2Scope(provider: "deepseek", scope: String(format: "%032x", $0)) }
        try runtime.setScopes(Set(scopes))
        let file = try Data(contentsOf: URL(fileURLWithPath: path + "/generations-v2.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: file) as? [String: Any])
        let generations = try XCTUnwrap(object["generations"] as? [String: String])
        func gen(_ scope: ExternalProviderV2Scope) throws -> String {
            try XCTUnwrap(generations["deepseek:" + scope.scope])
        }
        let first = try XCTUnwrap(scopes.first), initialGeneration = try gen(first)
        for index in 0..<256 {
            XCTAssertEqual(try send(runtime, first, initialGeneration, kind: "event", session: "existing\(index)")["accepted"] as? Bool, true)
        }
        XCTAssertEqual(runtime.snapshot().count, 256)
        for scope in scopes {
            XCTAssertEqual(try send(runtime, scope, gen(scope), kind: "event", session: "lost")["accepted"] as? Bool, true)
        }
        _ = runtime.snapshot()
        XCTAssertLessThanOrEqual(runtime.capacityLimitedScopes.count, 256)
        XCTAssertTrue(runtime.capacityLimitedProviders.contains("deepseek"))
        try runtime.setScopes([scopes[0]])
        XCTAssertTrue(runtime.capacityLimitedProviders.contains("deepseek"))
    }

    private func sendV1(_ directory: String, session: String, kind: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let payload = try JSONSerialization.data(withJSONObject: ["version": 1, "provider": "kimi",
                                                                   "session": session, "kind": kind])
        let size = payload.count
        let header = Data([UInt8(size & 255), UInt8((size >> 8) & 255), UInt8((size >> 16) & 255), UInt8((size >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + payload))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    @MainActor
    func testKimiTemporaryInspectionFailureRetainsCardUntilExplicitDisconnect() throws {
        let path = try directory("ki")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let channelPath = path + "/ch"
        let fixture = CapacityKimiFixture(.success(KimiConnection(state: "connected", scope: scopeA)))
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        var runtime: ExternalProviderRuntime?
        defer { runtime?.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              journal: DiagnosticJournal(directory: URL(fileURLWithPath: path + "/journal")),
                              enableExternalProviders: true, openCodeConnection: { .connected },
                              additionalExternalConnections: [.deepseek: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: {
            let created = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: channelPath))
            runtime = created
            return created
        }, discoverDeepSeekContext: { nil }, inspectKimiConnection: { try fixture.inspect() },
                              kimiScanInterval: 0.1, discoverHermesContext: { nil },
                              makeCodexCloudClient: { nil })
        func wait(_ message: String, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && !predicate() {
                store.refresh()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
            XCTAssertTrue(predicate(), message)
        }
        let session = scopeA + "_seen"
        wait("Kimi was not connected") { store.kimiState == "connected" && runtime != nil }
        try sendV1(channelPath, session: session, kind: "started")
        wait("Kimi task did not arrive") { store.tasks.contains { $0.id == "kimi:" + session } }
        fixture.set(.failure(KimiIntegrationError(code: "modified-bundle")))
        wait("Kimi check failure was not reported") { store.unavailableSources.contains(.kimi) }
        XCTAssertTrue(store.tasks.contains { $0.id == "kimi:" + session && $0.isUnconfirmed })
        fixture.set(.success(KimiConnection(state: "connected", scope: scopeA)))
        wait("Kimi inspection did not recover") { store.kimiState == "connected" && !store.unavailableSources.contains(.kimi) }
        XCTAssertTrue(store.tasks.contains { $0.id == "kimi:" + session && $0.isUnconfirmed },
                      "A temporary inspection error is not evidence that this task finished.")
        fixture.set(.success(KimiConnection(state: "disabled", scope: nil)))
        wait("Kimi was not disabled") { store.kimiState == "disabled" }
        XCTAssertFalse(store.tasks.contains { $0.id == "kimi:" + session })
        fixture.set(.success(KimiConnection(state: "connected", scope: scopeA)))
        wait("Kimi did not reconnect") { store.kimiState == "connected" }
        XCTAssertFalse(store.tasks.contains { $0.id == "kimi:" + session },
                       "An explicit disconnect must not revive an old Kimi task.")
    }

    #if DEBUG
    @MainActor
    func testPartialScopeKeepsPriorCardAndHealthyNeighbourAfterReconnect() throws {
        let path = try directory("scope")
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["deepseek"])
        seed.retainSessionScopes(provider: "deepseek", scopes: [scopeA, scopeB])
        XCTAssertTrue(seed.apply(event("deepseek", scopeB + "_healthy"), now: now))
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
        runtime.adoptState(seed)
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [], openCodeConnection: { .disconnected },
                              additionalExternalConnections: [.kimi: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: { runtime })
        let a = MonitoredTask(id: "deepseek:" + scopeA + "_previous", provider: .deepseek, title: "Synthetic A",
                              activity: "", isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: now)
        let b = MonitoredTask(id: "deepseek:" + scopeB + "_healthy", provider: .deepseek, title: "Synthetic B",
                              activity: "", isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: now)
        let connected = [DeepSeekProfile(name: "A", state: "connected", scope: scopeA, error: nil),
                         DeepSeekProfile(name: "B", state: "connected", scope: scopeB, error: nil)]
        let partial = [DeepSeekProfile(name: "A", state: "partial", scope: nil, error: "synthetic"),
                       DeepSeekProfile(name: "B", state: "connected", scope: scopeB, error: nil)]
        let degraded = store.testExternalFallback(previous: [a, b], deepSeekRosters: [connected, partial])
        XCTAssertTrue(degraded.0.contains { $0.id == a.id && $0.isUnconfirmed && !$0.isActive })
        XCTAssertTrue(degraded.0.contains { $0.id == b.id && $0.isActive && !$0.isUnconfirmed })
        let recovered = store.testExternalFallback(previous: degraded.0, deepSeekRosters: [connected])
        XCTAssertTrue(recovered.0.contains { $0.id == a.id && $0.isUnconfirmed && !$0.isActive })
        XCTAssertTrue(recovered.0.contains { $0.id == b.id && $0.isActive && !$0.isUnconfirmed })
    }

    @MainActor
    func testTaskStoreBoundKeepsVisibleNeighbourBeforeUnseenTasks() throws {
        let path = try directory("bound")
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["opencode"])
        XCTAssertTrue(seed.apply(event("opencode", "healthy"), now: now))
        for index in 0..<10 {
            XCTAssertTrue(seed.apply(event("opencode", "new\(index)"), now: now))
        }
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
        runtime.adoptState(seed)
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [], openCodeConnection: { .connected },
                              additionalExternalConnections: [.deepseek: { .disconnected }, .kimi: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: { runtime })
        var old = (0..<511).map { index in
            MonitoredTask(id: "opencode:old\(index)", provider: .opencode, title: "Synthetic",
                          activity: "", isActive: false, progress: nil, progressKind: .none,
                          steps: [], updatedAt: now, isUnconfirmed: true)
        }
        old.append(MonitoredTask(id: "opencode:healthy", provider: .opencode, title: "Synthetic healthy",
                                 activity: "", isActive: true, progress: nil, progressKind: .none,
                                 steps: [], updatedAt: now))
        let result = store.testExternalFallback(previous: old, deepSeekRosters: [])
        XCTAssertEqual(result.0.count, 512)
        XCTAssertTrue(result.0.contains { $0.id == "opencode:healthy" && $0.isActive && !$0.isUnconfirmed })
        XCTAssertFalse(result.0.contains { $0.id.hasPrefix("opencode:new") })
        XCTAssertTrue(result.1.contains(.opencode))
    }

    @MainActor
    func testFullAndPartialAvailabilityMessagesStayDistinctInBothLanguages() throws {
        let path = try directory("label")
        let item = MonitoredTask(id: "deepseek:" + scopeA + "_seen", provider: .deepseek,
                                 title: "Synthetic", activity: "", isActive: true,
                                 progress: nil, progressKind: .none, steps: [], updatedAt: now)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [])
        defer { AppLanguage.previewOverride = nil }
        store.testSetExternalAvailability(previous: [item], unavailable: [.deepseek, .kimi], partiallyUnavailable: [.deepseek])
        AppLanguage.previewOverride = .ru
        XCTAssertEqual(store.unavailableMessage, "Нет данных от Kimi Code. Часть данных DeepSeek Harness недоступна")
        AppLanguage.previewOverride = .en
        XCTAssertEqual(store.unavailableMessage, "No data from Kimi Code. Some DeepSeek Harness data is unavailable")
        store.testSetExternalAvailability(previous: [], unavailable: [.deepseek])
        XCTAssertEqual(store.unavailableMessage, "No data from DeepSeek Harness")
        store.testSetExternalAvailability(previous: [item], unavailable: [.deepseek], partiallyUnavailable: [.deepseek])
        XCTAssertEqual(store.unavailableMessage, "Some DeepSeek Harness data is unavailable")
        store.testSetExternalAvailability(previous: [], unavailable: [.deepseek], partiallyUnavailable: [.deepseek])
        XCTAssertEqual(store.unavailableMessage, "Some DeepSeek Harness data is unavailable")
        store.testSetExternalAvailability(previous: [item], unavailable: [.deepseek])
        XCTAssertEqual(store.unavailableMessage, "No data from DeepSeek Harness")
    }

    @MainActor
    func testHermesLateEventAndConfirmedTerminalDoNotReviveOldCard() throws {
        let path = try directory("hermes")
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["hermes", "opencode"])
        seed.retainSessionScopes(provider: "hermes", scopes: [scopeA])
        let session = scopeA + "_old"
        XCTAssertFalse(seed.apply(event("hermes", session, "started", tick: 1, epoch: 1), now: now))
        let fresh = Int64(clamping: DispatchTime.now().uptimeNanoseconds)
        XCTAssertTrue(seed.apply(event("hermes", session, "started", tick: fresh, epoch: fresh), now: now))
        XCTAssertTrue(seed.apply(event("hermes", session, "completed", tick: fresh + 1, epoch: fresh), now: now))
        XCTAssertTrue(seed.apply(event("opencode", "healthy"), now: now))
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
        runtime.adoptState(seed)
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [], openCodeConnection: { .connected },
                              additionalExternalConnections: [.kimi: { .disconnected }, .deepseek: { .disconnected }],
                              makeExternalRuntime: { runtime })
        let stale = MonitoredTask(id: "hermes:" + session, provider: .hermes, title: "Synthetic Hermes",
                                  activity: "", isActive: false, progress: nil, progressKind: .none,
                                  steps: [], updatedAt: now, isUnconfirmed: true)
        let roster = [HermesProfile(id: "root", name: "default", state: "prepared",
                                    scope: scopeA, error: nil, enabled: true)]
        let result = store.testExternalFallback(previous: [stale], deepSeekRosters: [], hermesRosters: [roster])
        XCTAssertFalse(result.0.contains { $0.id == stale.id })
        XCTAssertTrue(result.0.contains { $0.id == "opencode:healthy" && $0.isActive && !$0.isUnconfirmed })
    }

    @MainActor
    func testDeepSeekCapacityWarningFollowsAffectedScopeThroughDisableAndReconnect() throws {
        let path = try directory("scope-warning")
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["deepseek", "kimi"])
        seed.retainSessionScopes(provider: "deepseek", scopes: [scopeA, scopeB])
        XCTAssertTrue(seed.apply(event("deepseek", scopeB + "_healthy"), now: now))
        for index in 0..<255 { XCTAssertTrue(seed.apply(event("kimi", scopeA + "_k\(index)"), now: now)) }
        XCTAssertFalse(seed.apply(event("deepseek", scopeA + "_lost"), now: now))
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
        runtime.adoptState(seed)
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [], openCodeConnection: { .disconnected },
                              additionalExternalConnections: [.kimi: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: { runtime })
        let connected = [DeepSeekProfile(name: "A", state: "connected", scope: scopeA, error: nil),
                         DeepSeekProfile(name: "B", state: "connected", scope: scopeB, error: nil)]
        let disabled = [DeepSeekProfile(name: "A", state: "disconnected", scope: nil, error: nil),
                        DeepSeekProfile(name: "B", state: "connected", scope: scopeB, error: nil)]
        let initial = store.testExternalFallback(previous: [], deepSeekRosters: [connected])
        XCTAssertTrue(initial.1.contains(.deepseek))
        XCTAssertTrue(initial.0.contains { $0.id == "deepseek:" + scopeB + "_healthy" && $0.isActive && !$0.isUnconfirmed })
        let withoutA = store.testExternalFallback(previous: initial.0, deepSeekRosters: [disabled])
        XCTAssertFalse(withoutA.1.contains(.deepseek))
        XCTAssertTrue(withoutA.0.contains { $0.id == "deepseek:" + scopeB + "_healthy" && $0.isActive && !$0.isUnconfirmed })
        let reconnected = store.testExternalFallback(previous: withoutA.0, deepSeekRosters: [connected])
        XCTAssertTrue(reconnected.1.contains(.deepseek))
        XCTAssertTrue(reconnected.0.contains { $0.id == "deepseek:" + scopeB + "_healthy" && $0.isActive && !$0.isUnconfirmed })
    }

    @MainActor
    func testConnectedScopeWithoutCardsStillReportsPartialLoss() throws {
        let path = try directory("empty-scope")
        let seed = ExternalProviderStateStore()
        seed.retainProviders(["deepseek", "kimi"])
        seed.retainSessionScopes(provider: "deepseek", scopes: [scopeA, scopeB])
        for index in 0..<256 { XCTAssertTrue(seed.apply(event("kimi", scopeA + "_k\(index)"), now: now)) }
        XCTAssertFalse(seed.apply(event("deepseek", scopeA + "_lost"), now: now))
        let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: path))
        runtime.adoptState(seed)
        defer { runtime.stop() }
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/codex")),
                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/events")),
                              previewTasks: [], openCodeConnection: { .disconnected },
                              additionalExternalConnections: [.kimi: { .disconnected }, .hermes: { .disconnected }],
                              makeExternalRuntime: { runtime })
        let connected = [DeepSeekProfile(name: "A", state: "connected", scope: scopeA, error: nil),
                         DeepSeekProfile(name: "B", state: "connected", scope: scopeB, error: nil)]
        let result = store.testExternalFallback(previous: [], deepSeekRosters: [connected])
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertTrue(result.1.contains(.deepseek))
        XCTAssertTrue(store.testPartialExternalSources.contains(.deepseek))
        store.testSetExternalAvailability(previous: [], unavailable: result.1,
                                          partiallyUnavailable: store.testPartialExternalSources)
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        XCTAssertEqual(store.unavailableMessage, "Some DeepSeek Harness data is unavailable")
    }

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

    @MainActor
    func testRenderExistingWarningForFullAndPartialSources() throws {
        let path = try directory("render")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        let output = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("renders", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { AppLanguage.previewOverride = nil }
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for dark in [false, true] {
                for compact in [false, true] {
                    for kind in ["reference", "partial", "partial-empty", "full", "mixed"] {
                        let provider: TaskProvider = kind == "reference" ? .codex : (kind == "full" ? .opencode : .deepseek)
                        let item = MonitoredTask(id: provider.rawValue + ":synthetic", provider: provider,
                            title: tr("Проверка задачи", "Synthetic task"),
                            activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false,
                            progress: nil, progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true)
                        let initial = kind == "partial-empty" ? [] : [item]
                        let store = TaskStore(codexReader: CodexTaskReader(codexHome: URL(fileURLWithPath: path + "/fake-codex")),
                                              claudeReader: ClaudeTaskReader(eventFile: URL(fileURLWithPath: path + "/fake-events")),
                                              previewTasks: initial)
                        switch kind {
                        case "reference":
                            store.setPreviewCodexPartial()
                        case "partial", "partial-empty":
                            store.testSetExternalAvailability(previous: initial, unavailable: [.deepseek], partiallyUnavailable: [.deepseek])
                        case "full":
                            store.testSetExternalAvailability(previous: initial, unavailable: [.kimi])
                        default:
                            store.testSetExternalAvailability(previous: initial, unavailable: [.kimi, .deepseek], partiallyUnavailable: [.deepseek])
                        }
                        store.isCompact = compact
                        let size = compact ? NSSize(width: 372, height: 206) : NSSize(width: 560, height: 700)
                        let view = RootView().environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
                        let hosting = NSHostingView(rootView: view)
                        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        hosting.frame = NSRect(origin: .zero, size: size)
                        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                              styleMask: [.borderless], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentView = hosting
                        window.orderFrontRegardless()
                        hosting.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                        hosting.layoutSubtreeIfNeeded()
                        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        let name = "\(kind)-\(language.rawValue)-\(dark ? "dark" : "light")-\(compact ? "compact" : "expanded").png"
                        try bytes.write(to: output.appendingPathComponent(name), options: .atomic)
                        window.close()
                    }
                }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path).count, 40)
    }
    #endif
}
