import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic states only; the independent AF_UNIX regressions are separate.
final class NeutralTerminalTransitionTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ provider: String, _ session: String, _ kind: String) throws -> ExternalProviderEvent {
        let object: [String: Any] = ["version": 1, "provider": provider, "session": session, "kind": kind]
        return try XCTUnwrap(ExternalProviderEventParser.parse(JSONSerialization.data(withJSONObject: object)))
    }

    func testScopeLossAndLatePlanDoNotReviveCompletedButNewActivityCanBeNeutral() throws {
        let store = ExternalProviderStateStore(), session = a + "_session", neighbor = b + "_neighbor"
        store.retainProviders(["deepseek"])
        store.retainSessionScopes(provider: "deepseek", scopes: [a, b])
        XCTAssertTrue(store.apply(try event("deepseek", session, "active"), now: now))
        XCTAssertTrue(store.apply(try event("deepseek", session, "completed"), now: now))
        XCTAssertTrue(store.apply(try event("deepseek", neighbor, "active"), now: now))
        store.retainSessionScopes(provider: "deepseek", scopes: [b])
        store.markDeepSeekOwnershipUnknown(allowed: [b], ambiguous: [a], historyLost: true, disabled: [])
        let plan: [String: Any] = ["version": 1, "provider": "deepseek", "session": session, "kind": "plan",
                                   "steps": [["title": "Synthetic late plan", "status": "done"]]]
        let latePlan = try XCTUnwrap(ExternalProviderEventParser.parse(JSONSerialization.data(withJSONObject: plan)))
        XCTAssertTrue(store.applyUnassignedDeepSeek(latePlan, now: now))
        XCTAssertTrue(store.applyUnassignedDeepSeek(try event("deepseek", session, "unknown"), now: now))
        XCTAssertFalse(store.snapshot(now: now).contains { $0.session == session })
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == neighbor }?.status, "active")
        XCTAssertTrue(store.applyUnassignedDeepSeek(try event("deepseek", session, "active"), now: now))
        let reopened = try XCTUnwrap(store.snapshot(now: now).first { $0.session == session })
        XCTAssertEqual(reopened.status, "unknown")
        XCTAssertTrue(reopened.deepSeekUnassigned)
        XCTAssertTrue(reopened.steps.isEmpty)
        XCTAssertFalse(reopened.planConfirmed)
    }

    func testProviderGapDoesNotReviveCompletedOpenCodeSession() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode"])
        XCTAssertTrue(store.apply(try event("opencode", "closed", "active"), now: now))
        XCTAssertTrue(store.apply(try event("opencode", "closed", "completed"), now: now))
        store.markGap(provider: "opencode")
        XCTAssertFalse(store.snapshot(now: now).contains { $0.session == "closed" })
        XCTAssertTrue(store.apply(try event("opencode", "closed", "active"), now: now))
        XCTAssertEqual(store.snapshot(now: now).first { $0.session == "closed" }?.status, "unknown")
    }
}
