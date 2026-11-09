import Foundation
import XCTest
@testable import AITaskMonitor

// Independent tests, copied from the reviewer; the invalid-roster test selects
// the explicit invalid-response seam in this candidate.
final class IndependentIsolationReviewTests: XCTestCase {
    private enum FixtureError: Error { case unavailable }
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let c = String(repeating: "c", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ name: String, _ state: String, _ scope: String? = nil) -> DeepSeekProfile {
        DeepSeekProfile(name: name, state: state, scope: scope, error: nil)
    }

    private func event(_ scope: String, _ session: String) throws -> ExternalProviderEvent {
        let json = #"{"version":1,"provider":"deepseek","session":"\#(scope)_\#(session)","kind":"active"}"#
        return try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
    }

    private func visible(_ store: ExternalProviderStateStore, history: ProviderScopeHistory,
                         profiles: [DeepSeekProfile]) -> [MonitoredTask] {
        let allowed = history.allowed(profiles, scanFailed: false)
        let uncertain = history.uncertain(profiles, scanFailed: false)
        return ExternalProfileVisibility.filter(
            ExternalProviderTaskMapper.tasks(store.snapshot(now: now)),
            allowed: [.deepseek], profileScopes: [.deepseek: allowed],
            uncertainScopes: [.deepseek: uncertain],
            ambiguousScopes: [.deepseek: history.ambiguous(profiles)])
    }

    func testDisabledThenErrorOrPartialCannotReviveStoredCard() throws {
        for last in ["error", "partial"] {
            var history = ProviderScopeHistory()
            let on = [profile("A", "connected", a), profile("B", "connected", b)]
            let off = [profile("A", "disconnected"), profile("B", "connected", b)]
            let failed = [profile("A", last), profile("B", "connected", b)]
            XCTAssertTrue(history.update(on))
            let store = ExternalProviderStateStore()
            store.retainProviders(["deepseek"])
            store.retainSessionScopes(provider: "deepseek", scopes: history.allowed(on, scanFailed: false))
            XCTAssertTrue(store.apply(try event(a, "old"), now: now))
            XCTAssertTrue(store.apply(try event(b, "healthy"), now: now))
            XCTAssertTrue(history.update(off))
            store.retainSessionScopes(provider: "deepseek", scopes: history.allowed(off, scanFailed: false))
            XCTAssertFalse(visible(store, history: history, profiles: off).contains { $0.id == "deepseek:\(a)_old" })
            XCTAssertTrue(history.update(failed))
            let uncertain = history.uncertain(failed, scanFailed: false)
            store.retainSessionScopes(provider: "deepseek", scopes: history.allowed(failed, scanFailed: false))
            store.markSessionScopesGap(provider: "deepseek", scopes: uncertain)
            let final = visible(store, history: history, profiles: failed)
            XCTAssertTrue(history.disabled.contains(Data("A".utf8)), "\(last): an error does not reconnect A")
            XCTAssertFalse(uncertain.contains(a), "\(last): disabled scope is not uncertain-visible")
            XCTAssertFalse(final.contains { $0.id == "deepseek:\(a)_old" }, "\(last): stored disabled task must stay hidden")
            XCTAssertTrue(final.contains { $0.id == "deepseek:\(b)_healthy" && $0.isActive })
        }
    }

    func testCompetingOwnerCannotBeForgottenAfterHistoryLoss() {
        var history = ProviderScopeHistory()
        XCTAssertTrue(history.update([profile("A", "connected", a), profile("healthy", "connected", b)]))
        XCTAssertTrue(history.update([profile("A", "connected", c), profile("healthy", "connected", b)]))
        XCTAssertTrue(history.historyLost)
        let conflict = [profile("healthy", "connected", b), profile("impostor", "connected", b)]
        XCTAssertTrue(history.update(conflict))
        XCTAssertTrue(history.ambiguous(conflict).contains(b))
        let many = [profile("healthy", "connected", b)] + (0..<255).map {
            profile("current\($0)", "connected", String(format: "%032x", $0))
        }
        XCTAssertTrue(history.update(many))
        XCTAssertNil(history.seen[Data("impostor".utf8)], "fixture must evict the competing owner")
        XCTAssertTrue(history.ambiguous(many).contains(b), "a conflict must remain closed after eviction")
        XCTAssertFalse(history.allowed(many, scanFailed: false).contains(b), "do not restore a formerly shared scope")
    }

    #if DEBUG
    @MainActor
    func testInitiallyDisabledHermesScopeRemainsOwnershipEvidence() {
        let synthetic = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-independent-" + UUID().uuidString)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: synthetic),
                              claudeReader: ClaudeTaskReader(eventFile: synthetic.appendingPathComponent("events")),
                              previewTasks: [], openCodeConnection: { .connected },
                              makeExternalRuntime: { throw FixtureError.unavailable })
        let old = [
            HermesProfile(id: "root", name: "default", state: "prepared", scope: a, error: nil, enabled: false),
            HermesProfile(id: "profile:work", name: "work", state: "absent", scope: nil, error: nil),
            HermesProfile(id: "profile:stable", name: "stable", state: "prepared", scope: c, error: nil, enabled: true)
        ]
        let next = [
            HermesProfile(id: "root", name: "default", state: "error", scope: nil, error: "synthetic"),
            HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: a, error: nil, enabled: true),
            old[2]
        ]
        XCTAssertTrue(HermesIntegration.validProfiles(old))
        XCTAssertTrue(HermesIntegration.validProfiles(next))
        let oldCard = MonitoredTask(id: "hermes:\(a)_old", provider: .hermes, title: "Synthetic",
                                    activity: "", isActive: false, progress: nil, progressKind: .none,
                                    steps: [], updatedAt: now, isUnconfirmed: true)
        let stableCard = MonitoredTask(id: "hermes:\(c)_stable", provider: .hermes, title: "Synthetic",
                                       activity: "", isActive: false, progress: nil, progressKind: .none,
                                       steps: [], updatedAt: now, isUnconfirmed: true)
        let result = store.testExternalFallback(previous: [oldCard, stableCard], deepSeekRosters: [], hermesRosters: [old, next])
        XCTAssertFalse(result.0.contains { $0.id == "hermes:\(a)_old" },
                       "scope of the disabled first owner must not be silently transferred")
        XCTAssertTrue(result.0.contains { $0.id == "hermes:\(c)_stable" }, "healthy neighbor remains visible")
    }

    @MainActor
    func testRejectedHermesDuplicateCannotExposeOldScopeInFallback() {
        let synthetic = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("aitm-independent-" + UUID().uuidString)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: synthetic),
                              claudeReader: ClaudeTaskReader(eventFile: synthetic.appendingPathComponent("events")),
                              previewTasks: [], openCodeConnection: { .connected },
                              makeExternalRuntime: { throw FixtureError.unavailable })
        let old = [
            HermesProfile(id: "root", name: "default", state: "prepared", scope: a, error: nil, enabled: true),
            HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: b, error: nil, enabled: true),
            HermesProfile(id: "profile:stable", name: "stable", state: "prepared", scope: c, error: nil, enabled: true)
        ]
        let duplicate = [
            old[0],
            HermesProfile(id: "profile:work", name: "work", state: "prepared", scope: a, error: nil, enabled: true),
            old[2]
        ]
        XCTAssertFalse(HermesIntegration.validProfiles(duplicate), "current parser rejects before the history can inspect the conflict")
        let oldCard = MonitoredTask(id: "hermes:\(a)_old", provider: .hermes, title: "Synthetic",
                                    activity: "", isActive: false, progress: nil, progressKind: .none,
                                    steps: [], updatedAt: now, isUnconfirmed: true)
        let result = store.testExternalFallback(previous: [oldCard], deepSeekRosters: [], hermesRosters: [old], hermesInvalid: true)
        XCTAssertFalse(result.0.contains { $0.id == "hermes:\(a)_old" },
                       "rejected competing roster must not resurrect a task whose identity cannot be resolved")
    }
    #endif
}
