import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class V1IsolationFixTests: XCTestCase {
    private enum FixtureError: Error { case unableToOpen }
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let c = String(repeating: "c", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ name: String, _ state: String, _ scope: String? = nil) -> DeepSeekProfile {
        DeepSeekProfile(name: name, state: state, scope: scope, error: nil)
    }

    private func task(_ provider: TaskProvider, _ session: String) -> MonitoredTask {
        MonitoredTask(id: "\(provider.rawValue):\(session)", provider: provider, title: "Synthetic", activity: "",
                      isActive: false, progress: nil, progressKind: .none, steps: [], updatedAt: now,
                      isUnconfirmed: true)
    }

    private func event(_ provider: String, _ session: String, _ kind: String = "active") throws -> ExternalProviderEvent {
        let value = "{\"version\":1,\"provider\":\"\(provider)\",\"session\":\"\(session)\",\"kind\":\"\(kind)\"}"
        return try XCTUnwrap(ExternalProviderEventParser.parse(Data(value.utf8)))
    }

    private func send(_ json: String, directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(json.utf8), length = body.count
        let header = Data([UInt8(length & 255), UInt8((length >> 8) & 255),
                           UInt8((length >> 16) & 255), UInt8((length >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    func testDisconnectedClaimAndScopeConflictDoNotAffectNeighbour() {
        var history = ProviderScopeHistory()
        XCTAssertTrue(history.update([profile("A", "connected", a), profile("B", "connected", b)]))
        let disabled = [profile("A", "disconnected"), profile("B", "connected", b)]
        XCTAssertTrue(history.update(disabled))
        XCTAssertEqual(history.allowed(disabled, scanFailed: false), [b])
        XCTAssertFalse(history.uncertain(disabled, scanFailed: false).contains(a))
        let collision = [profile("A", "disconnected"), profile("B", "connected", b), profile("C", "connected", a)]
        XCTAssertTrue(history.update(collision))
        XCTAssertTrue(history.ambiguous(collision).contains(a))
        XCTAssertEqual(history.allowed(collision, scanFailed: false), [b])
        let changed = [profile("A", "connected", c), profile("B", "connected", b)]
        XCTAssertTrue(history.update(changed))
        XCTAssertTrue(history.historyLost)
        XCTAssertEqual(history.allowed(changed, scanFailed: false), [b])
    }

    func testBoundedChurnDoesNotOverflowTwoHealthyProfilesOrAcceptForgottenClaim() {
        var history = ProviderScopeHistory()
        var old = [profile("healthy", "connected", b)]
        for index in 0..<255 {
            old.append(profile("old\(index)", "connected", String(format: "%032x", index)))
        }
        XCTAssertTrue(history.update(old))
        let oldClaims = history.seen
        let next = [profile("healthy", "connected", b), profile("new", "connected", c)]
        XCTAssertTrue(history.update(next))
        XCTAssertTrue(history.historyLost)
        XCTAssertEqual(history.allowed(next, scanFailed: false), [b, c])
        XCTAssertLessThanOrEqual(history.seen.count, 256)
        XCTAssertLessThanOrEqual(history.disabled.count, 256)
        XCTAssertLessThanOrEqual(history.stable.count, 256)
        let forgotten = oldClaims.first { history.seen[$0.key] == nil }?.value
        XCTAssertNotNil(forgotten)
        let impostor = [profile("healthy", "connected", b), profile("impostor", "connected", forgotten)]
        XCTAssertTrue(history.update(impostor))
        XCTAssertEqual(history.allowed(impostor, scanFailed: false), [b])
    }

    func testManyDisabledNamesAndAmbiguousUnicodeAreHandledFailClosed() {
        var history = ProviderScopeHistory()
        let wide = [profile("A", "connected", a), profile("B", "connected", b)] +
            (0..<300).map { profile("disabled\($0)", "disconnected") }
        XCTAssertTrue(history.update(wide))
        XCTAssertEqual(history.allowed(wide, scanFailed: false), [a, b])
        let prior = history.seen
        let tooMany = (0..<257).map { profile("live\($0)", "connected", String(format: "%032x", $0)) }
        XCTAssertFalse(history.update(tooMany))
        XCTAssertEqual(history.seen, prior)
        let visuallyEquivalent = [profile("e\u{301}", "connected", a), profile("\u{00e9}", "connected", b)]
        XCTAssertFalse(history.update(visuallyEquivalent))
        XCTAssertEqual(history.seen, prior)
    }

    func testFallbackUsesOnlyLiveOrKnownUncertainNonconflictingScopes() {
        let candidates = [task(.deepseek, "\(a)_old"), task(.deepseek, "\(b)_live"),
                          task(.deepseek, "\(c)_conflict"), task(.kimi, "\(a)_kimi"),
                          task(.hermes, "\(b)_hermes"), task(.opencode, "open"),
                          task(.deepseek, "\(b)_"), task(.deepseek, "unscoped")]
        let filtered = ExternalProfileVisibility.filter(candidates, allowed: [.deepseek, .kimi, .hermes, .opencode],
            profileScopes: [.deepseek: [b], .hermes: [b]], uncertainScopes: [.deepseek: [c]],
            ambiguousScopes: [.deepseek: [c]])
        XCTAssertEqual(Set(filtered.map(\.id)), ["deepseek:\(b)_live", "hermes:\(b)_hermes", "opencode:open"])
        let noMetadata = ExternalProfileVisibility.filter(candidates, allowed: [.deepseek, .kimi, .hermes, .opencode],
            profileScopes: [:], uncertainScopes: [:], ambiguousScopes: [:])
        XCTAssertEqual(noMetadata.map(\.id), ["opencode:open"])
    }

    @MainActor
    private func fixtureStore(runtime: @escaping () throws -> ExternalProviderRuntime) -> TaskStore {
        let synthetic = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-fixture-" + UUID().uuidString)
        return TaskStore(codexReader: CodexTaskReader(codexHome: synthetic),
                         claudeReader: ClaudeTaskReader(eventFile: synthetic.appendingPathComponent("events")),
                         previewTasks: [], openCodeConnection: { .connected }, makeExternalRuntime: runtime)
    }

    #if DEBUG
    @MainActor
    func testTaskStoreRuntimeCreationFailureDoesNotReturnDisconnectedProfile() {
        let store = fixtureStore { throw FixtureError.unableToOpen }
        let first = [profile("A", "connected", a), profile("B", "connected", b)]
        let second = [profile("A", "disconnected"), profile("B", "connected", b)]
        var live = task(.deepseek, "\(b)_live"); live.isActive = true; live.isUnconfirmed = false
        let result = store.testExternalFallback(previous: [task(.deepseek, "\(a)_old"), live, task(.opencode, "open")],
                                                deepSeekRosters: [first, second])
        XCTAssertEqual(Set(result.0.map(\.id)), ["deepseek:\(b)_live", "opencode:open"])
        XCTAssertTrue(result.0.allSatisfy { $0.isUnconfirmed && !$0.isActive && !$0.isWaiting })
        XCTAssertTrue(result.1.contains(.deepseek))
        XCTAssertTrue(result.1.contains(.opencode))
    }

    @MainActor
    func testTaskStoreScanFailureKeepsKnownScopeButNotDisabledNeighbour() {
        let store = fixtureStore { throw FixtureError.unableToOpen }
        let initial = [profile("A", "connected", a), profile("B", "connected", b)]
        let disabled = [profile("A", "disconnected"), profile("B", "connected", b)]
        let result = store.testExternalFallback(previous: [task(.deepseek, "\(a)_old"), task(.deepseek, "\(b)_live")],
                                                deepSeekRosters: [initial, disabled], deepSeekFailure: true)
        XCTAssertEqual(result.0.map(\.id), ["deepseek:\(b)_live"])
        XCTAssertTrue(result.0[0].isUnconfirmed)
        XCTAssertTrue(result.1.contains(.deepseek))
    }

    @MainActor
    func testTaskStoreFailureHidesHermesScopeWithTwoClaims() {
        let store = fixtureStore { throw FixtureError.unableToOpen }
        let first = [HermesProfile(id: "root", name: "default", state: "prepared", scope: a, error: nil, enabled: true),
                     HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: b, error: nil, enabled: true)]
        let second = [HermesProfile(id: "root", name: "default", state: "error", scope: nil, error: "synthetic"),
                      HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: a, error: nil, enabled: true)]
        let result = store.testExternalFallback(previous: [task(.hermes, "\(a)_old"), task(.deepseek, "\(c)_healthy")],
            deepSeekRosters: [[profile("healthy", "connected", c)]], hermesRosters: [first, second])
        XCTAssertEqual(result.0.map(\.id), ["deepseek:\(c)_healthy"])
        XCTAssertTrue(result.0[0].isUnconfirmed)
        XCTAssertTrue(result.1.contains(.hermes))
    }

    @MainActor
    func testTaskStoreFailureHidesHermesDisabledReassignmentAndKeepsNeighbour() {
        let store = fixtureStore { throw FixtureError.unableToOpen }
        let first = [HermesProfile(id: "root", name: "default", state: "prepared", scope: a, error: nil, enabled: true),
                     HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: b, error: nil, enabled: true),
                     HermesProfile(id: "profile:stable", name: "stable", state: "prepared", scope: c, error: nil, enabled: true)]
        let disabled = [HermesProfile(id: "root", name: "default", state: "absent", scope: nil, error: nil),
                        first[1], first[2]]
        let moved = [disabled[0], HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: a, error: nil, enabled: true), first[2]]
        let result = store.testExternalFallback(previous: [task(.hermes, "\(a)_old"), task(.hermes, "\(c)_stable")],
                                               deepSeekRosters: [], hermesRosters: [first, disabled, moved])
        XCTAssertEqual(result.0.map(\.id), ["hermes:\(c)_stable"])
        XCTAssertTrue(result.0[0].isUnconfirmed)
        XCTAssertTrue(result.1.contains(.hermes))
    }

    @MainActor
    func testTaskStoreDetectsStoppedRuntimeAndReturnsUnconfirmedFallback() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-v1-store-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = try ExternalProviderChannel(directory: directory.path)
        let runtime = ExternalProviderRuntime(channel: channel)
        XCTAssertTrue(channel.stop())
        let store = fixtureStore { runtime }
        var previous = task(.opencode, "one"); previous.isActive = true; previous.isUnconfirmed = false
        let result = store.testExternalFallback(previous: [previous], deepSeekRosters: [])
        XCTAssertTrue(runtime.transportUnavailable)
        XCTAssertEqual(result.0.count, 1)
        XCTAssertTrue(result.0[0].isUnconfirmed)
        XCTAssertFalse(result.0[0].isActive)
        XCTAssertTrue(result.1.contains(.opencode))
    }
    #endif

    func testCapacityCannotEvictUnconfirmedV1CardOrTaintOtherProfile() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode", "deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [b])
        store.markGap(provider: "opencode")
        for index in 0..<255 { XCTAssertTrue(store.apply(try event("opencode", "s\(index)"), now: now)) }
        XCTAssertTrue(store.apply(try event("deepseek", "\(b)_healthy"), now: now))
        XCTAssertFalse(store.apply(try event("kimi", "\(a)_other"), now: now))
        let tasks = store.snapshot(now: now)
        XCTAssertEqual(tasks.count, 256)
        XCTAssertTrue(tasks.contains { $0.session == "s0" && $0.status == "unknown" })
        XCTAssertTrue(tasks.contains { $0.session == "\(b)_healthy" && $0.status == "active" })
        XCTAssertEqual(store.capacityLimitedProviders, ["kimi"])
    }

    func testStoppedChannelFailsClosedAndMarksParkedStateUnconfirmed() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-v1-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = try ExternalProviderChannel(directory: directory.path)
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode"])
        XCTAssertTrue(store.apply(try event("opencode", "one"), now: now))
        let runtime = ExternalProviderRuntime(channel: channel)
        runtime.adoptState(store)
        XCTAssertTrue(channel.stop())
        XCTAssertTrue(runtime.snapshot(allowed: [.opencode], now: now).isEmpty)
        XCTAssertTrue(runtime.transportUnavailable)
        XCTAssertEqual(runtime.parkState(markTransportGap: false).snapshot(now: now).first?.status, "unknown")
    }

    #if DEBUG
    func testStopBetweenDrainAndReductionDiscardsBatchAndMarksGap() throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-v1-stop-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = try ExternalProviderChannel(directory: directory.path)
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode"])
        XCTAssertTrue(store.apply(try event("opencode", "one"), now: now))
        let runtime = ExternalProviderRuntime(channel: channel)
        runtime.adoptState(store)
        channel.setAllowedProviders(["opencode"])
        try send(#"{"version":1,"provider":"opencode","session":"new","kind":"active"}"#, directory: directory.path)
        runtime.testAfterDrain = { _ = channel.stop() }
        XCTAssertTrue(runtime.snapshot(allowed: [.opencode], now: now).isEmpty)
        XCTAssertTrue(runtime.transportUnavailable)
        let parked = runtime.parkState(markTransportGap: false).snapshot(now: now)
        XCTAssertEqual(parked.first?.status, "unknown")
        XCTAssertFalse(parked.contains { $0.session == "new" })
    }
    #endif
}
