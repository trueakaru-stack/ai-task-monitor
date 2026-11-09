import Foundation
import XCTest
@testable import AITaskMonitor

// Independent protective regressions, carried forward from the review.
// This file has not been compiled or run on macOS.
final class HistoryUnstableFallbackTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let c = String(repeating: "c", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ name: String, _ state: String, _ scope: String? = nil) -> DeepSeekProfile {
        DeepSeekProfile(name: name, state: state, scope: scope, error: nil)
    }

    private func event(_ scope: String, _ suffix: String) throws -> ExternalProviderEvent {
        let json = #"{"version":1,"provider":"deepseek","session":"\#(scope)_\#(suffix)","kind":"active"}"#
        return try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
    }

    private func snapshot(_ store: ExternalProviderStateStore, history: ProviderScopeHistory,
                          profiles: [DeepSeekProfile]) -> [MonitoredTask] {
        let allowed = history.allowed(profiles, scanFailed: false)
        let uncertain = history.uncertain(profiles, scanFailed: false)
        let conflicts = history.ambiguous(profiles)
        store.retainSessionScopes(provider: "deepseek", scopes: allowed)
        store.markSessionScopesGap(provider: "deepseek", scopes: uncertain)
        return ExternalProfileVisibility.filter(
            ExternalProviderTaskMapper.tasks(store.snapshot(now: now)),
            allowed: [.deepseek], profileScopes: [.deepseek: allowed],
            uncertainScopes: [.deepseek: uncertain], ambiguousScopes: [.deepseek: conflicts])
    }

    func testUnstableErrorScopeDoesNotReviveEvictedFormerOwner() throws {
        var history = ProviderScopeHistory()
        let initial = [profile("A", "connected", a), profile("old", "connected", c), profile("healthy", "connected", b)]
        XCTAssertTrue(history.update(initial))
        let store = ExternalProviderStateStore()
        store.retainProviders(["deepseek"])
        store.retainSessionScopes(provider: "deepseek", scopes: history.allowed(initial, scanFailed: false))
        XCTAssertTrue(store.apply(try event(c, "old"), now: now))
        XCTAssertTrue(store.apply(try event(b, "healthy"), now: now))
        XCTAssertTrue(snapshot(store, history: history, profiles: initial).contains { $0.id == "deepseek:\(c)_old" })

        let changed = [profile("A", "connected", c), profile("healthy", "connected", b)]
        XCTAssertTrue(history.update(changed))
        XCTAssertTrue(history.historyLost)
        XCTAssertTrue(history.ambiguous(changed).contains(c))
        XCTAssertFalse(snapshot(store, history: history, profiles: changed).contains { $0.id == "deepseek:\(c)_old" })

        let churn = changed + (0..<254).map { profile("current\($0)", "connected", String(format: "%032x", $0)) }
        XCTAssertTrue(history.update(churn))
        XCTAssertNil(history.seen[Data("old".utf8)], "the synthetic previous owner must be evicted")
        XCTAssertFalse(snapshot(store, history: history, profiles: churn).contains { $0.id == "deepseek:\(c)_old" })

        let failed = [profile("A", "error"), profile("healthy", "connected", b)]
        XCTAssertTrue(history.update(failed))
        XCTAssertEqual(history.allowed(failed, scanFailed: false), [b], "unaffected neighbor stays available")
        XCTAssertFalse(history.uncertain(failed, scanFailed: false).contains(c), "an unverified changed owner must not restore an old scope via uncertainty")
        let tasks = snapshot(store, history: history, profiles: failed)
        XCTAssertFalse(tasks.contains { $0.id == "deepseek:\(c)_old" }, "scope of evicted owner must not be reassigned through fallback")
        XCTAssertTrue(tasks.contains { $0.id == "deepseek:\(b)_healthy" && $0.isActive })
    }

    func testChangedOwnerScopeCannotReturnThroughNewOwnerError() throws {
        var history = ProviderScopeHistory()
        let initial = [profile("A", "connected", a), profile("healthy", "connected", b)]
        XCTAssertTrue(history.update(initial))
        let store = ExternalProviderStateStore()
        store.retainProviders(["deepseek"])
        store.retainSessionScopes(provider: "deepseek", scopes: history.allowed(initial, scanFailed: false))
        XCTAssertTrue(store.apply(try event(a, "old"), now: now))
        XCTAssertTrue(store.apply(try event(b, "healthy"), now: now))

        let changed = [profile("A", "connected", c), profile("healthy", "connected", b)]
        XCTAssertTrue(history.update(changed))
        XCTAssertTrue(history.historyLost)
        XCTAssertFalse(snapshot(store, history: history, profiles: changed).contains { $0.id == "deepseek:\(a)_old" })
        let claimed = changed + [profile("new", "connected", a)]
        XCTAssertTrue(history.update(claimed))
        XCTAssertTrue(history.ambiguous(claimed).contains(a))
        XCTAssertFalse(snapshot(store, history: history, profiles: claimed).contains { $0.id == "deepseek:\(a)_old" })

        let failed = changed + [profile("new", "error")]
        XCTAssertTrue(history.update(failed))
        XCTAssertFalse(history.uncertain(failed, scanFailed: false).contains(a),
                       "a new unverified owner with an error must not re-expose A's old scope")
        let tasks = snapshot(store, history: history, profiles: failed)
        XCTAssertFalse(tasks.contains { $0.id == "deepseek:\(a)_old" })
        XCTAssertTrue(tasks.contains { $0.id == "deepseek:\(b)_healthy" && $0.isActive })
    }

    func testUnstablePartialAndMissingScopeStayHiddenWhileNeighbourWorks() {
        for state in ["partial", "missing"] {
            var history = ProviderScopeHistory()
            XCTAssertTrue(history.update([profile("A", "connected", a), profile("healthy", "connected", b)]))
            let changed = [profile("A", "connected", c), profile("healthy", "connected", b)]
            XCTAssertTrue(history.update(changed))
            XCTAssertTrue(history.historyLost)
            XCTAssertTrue(history.update(changed + [profile("new", "connected", a)]))
            let failed = state == "missing" ? changed : changed + [profile("new", state)]
            XCTAssertTrue(history.update(failed))
            XCTAssertFalse(history.uncertain(failed, scanFailed: false).contains(a), state)
            XCTAssertEqual(history.allowed(failed, scanFailed: false), [b], state)
        }
    }

    func testInterruptedStableProfileDoesNotHideOtherStableNeighbour() {
        for state in ["error", "partial", "disconnected", "missing"] {
            var history = ProviderScopeHistory()
            let d = String(repeating: "d", count: 32)
            let first = [profile("A", "connected", a), profile("first", "connected", b), profile("second", "connected", d)]
            XCTAssertTrue(history.update(first))
            let changed = [profile("A", "connected", c), profile("first", "connected", b), profile("second", "connected", d)]
            XCTAssertTrue(history.update(changed))
            XCTAssertTrue(history.historyLost)
            let unwell = [profile("A", "connected", c), profile("second", "connected", d)] +
                (state == "missing" ? [] : [profile("first", state)])
            XCTAssertTrue(history.update(unwell))
            XCTAssertFalse(history.uncertain(unwell, scanFailed: false).contains(b), state)
            XCTAssertEqual(history.allowed(unwell, scanFailed: false), [d], state)
        }
    }
}
