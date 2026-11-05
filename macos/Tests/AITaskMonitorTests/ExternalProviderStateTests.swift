import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ json: String) -> ExternalProviderEvent? {
        ExternalProviderEventParser.parse(Data(json.utf8))
    }

    private func apply(_ store: ExternalProviderStateStore, _ json: String, _ now: Date) throws {
        let event = try XCTUnwrap(parse(json))
        XCTAssertTrue(store.apply(event, now: now))
    }

    func testSessionsPlansWaitingAndResumption() throws {
        let store = ExternalProviderStateStore()
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"1"}"#, now)
        try apply(store, #"{"version":1,"provider":"opencode","session":"shared","kind":"active"}"#, now)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[{"title":"One","status":"done"},{"title":"Two","status":"active"}]}"#, now)
        let tasks = store.snapshot(now: now)
        XCTAssertEqual(tasks.count, 2)
        let deep = try XCTUnwrap(tasks.first { $0.provider == "deepseek" })
        XCTAssertEqual(deep.status, "active")
        XCTAssertTrue(deep.planConfirmed)
        XCTAssertEqual(deep.steps.map(\.status), ["done", "active"])
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"tool_started","call":"c1","action":"command"}"#, now)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"tool_started","call":"c2","action":"edit"}"#, now)
        XCTAssertEqual(store.snapshot(now: now).first { $0.provider == "deepseek" }?.activity, "edit")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"tool_finished","call":"c2"}"#, now)
        XCTAssertEqual(store.snapshot(now: now).first { $0.provider == "deepseek" }?.activity, "command")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"tool_finished","call":"c1"}"#, now)
        XCTAssertEqual(store.snapshot(now: now).first { $0.provider == "deepseek" }?.activity, "")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"waiting"}"#, now.addingTimeInterval(1))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(1)).first { $0.provider == "deepseek" }?.status, "waiting")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"unknown"}"#, now.addingTimeInterval(2))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(2)).first { $0.provider == "deepseek" }?.status, "unknown")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"completed"}"#, now.addingTimeInterval(3))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(3)).count, 1)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"started","turn":"2"}"#, now.addingTimeInterval(4))
        let resumed = try XCTUnwrap(store.snapshot(now: now.addingTimeInterval(4)).first { $0.provider == "deepseek" })
        XCTAssertFalse(resumed.planConfirmed)
        XCTAssertEqual(resumed.steps.count, 2)
        XCTAssertNotEqual(resumed.startKey, deep.startKey)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"shared","kind":"plan","steps":[]}"#, now.addingTimeInterval(5))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(5)).first { $0.provider == "deepseek" }?.steps.count, 0)
    }

    func testGapAndStaleActivityBecomeUnknown() throws {
        let store = ExternalProviderStateStore()
        try apply(store, #"{"version":1,"provider":"deepseek","session":"one","kind":"active"}"#, now)
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(1_800)).first?.status, "unknown")
        try apply(store, #"{"version":1,"provider":"deepseek","session":"one","kind":"plan","steps":[]}"#, now.addingTimeInterval(10_800))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(10_800)).first?.status, "unknown")
        let epoch = DispatchTime.now().uptimeNanoseconds
        try apply(store, #"{"version":1,"provider":"hermes","session":"two","kind":"started","turn":"one","epoch":\#(epoch),"tick":\#(epoch + 1)}"#, now)
        try apply(store, #"{"version":1,"provider":"hermes","session":"two","kind":"plan","steps":[{"title":"One","status":"done"}],"epoch":\#(epoch),"tick":\#(epoch + 2)}"#, now)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"one","kind":"gap"}"#, now)
        let unaffected = try XCTUnwrap(store.snapshot(now: now).first { $0.provider == "hermes" })
        XCTAssertEqual(unaffected.status, "active")
        XCTAssertTrue(unaffected.planConfirmed)
        store.markGap()
        XCTAssertTrue(store.snapshot(now: now).allSatisfy { $0.status == "unknown" })
        XCTAssertFalse(try XCTUnwrap(store.snapshot(now: now).first { $0.provider == "hermes" }).planConfirmed)
    }

    func testKimiEventsRemainUnconfirmedEvenIfTheyArriveOutOfOrder() throws {
        let store = ExternalProviderStateStore()
        for kind in ["started", "waiting", "interrupted", "active", "completed"] {
            try apply(store, #"{"version":1,"provider":"kimi","session":"one","kind":"\#(kind)"}"#, now)
            let state = try XCTUnwrap(store.snapshot(now: now).first)
            XCTAssertEqual(state.status, "unknown")
            XCTAssertFalse(state.planConfirmed)
            XCTAssertTrue(state.steps.isEmpty)
            let task = try XCTUnwrap(ExternalProviderTaskMapper.tasks([state]).first)
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.isActive)
            XCTAssertFalse(task.isWaiting)
            XCTAssertNil(task.progress)
        }
    }

    func testInvalidPrivateAndOversizedInputsAreRejected() {
        for invalid in [
            #"{"version":1,"provider":"opencode","session":"../../bad","kind":"active"}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"active","prompt":"secret"}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"plan","steps":[{"title":"One","status":"cancelled"}]}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"active","steps":[]}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"tool_started","call":"c","action":"secret"}"#,
            #"{"version":1,"provider":"opencode","session":"one","kind":"heartbeat","turn":"1"}"#,
            #"{"version":true,"provider":"opencode","session":"one","kind":"active"}"#,
            #"{"version":2,"provider":"opencode","session":"one","kind":"active"}"#
        ] { XCTAssertNil(parse(invalid)) }
        XCTAssertNil(parse(String(repeating: "x", count: 65_537)))
    }

    func testHeartbeatNeverCreatesOrRevivesAndLongRunningIsNotProgress() throws {
        let store = ExternalProviderStateStore()
        let beat = #"{"version":1,"provider":"opencode","session":"long","kind":"heartbeat"}"#
        try apply(store, beat, now)
        XCTAssertTrue(store.snapshot(now: now).isEmpty)
        try apply(store, #"{"version":1,"provider":"opencode","session":"long","kind":"tool_started","call":"cmd","action":"command"}"#, now)
        try apply(store, #"{"version":1,"provider":"opencode","session":"long","kind":"plan","steps":[{"title":"One","status":"active"}]}"#, now)
        try apply(store, beat, now.addingTimeInterval(1_740))
        try apply(store, beat, now.addingTimeInterval(1_800))
        let long = try XCTUnwrap(store.snapshot(now: now.addingTimeInterval(1_800)).first)
        XCTAssertEqual(long.status, "active")
        XCTAssertTrue(long.longRunning)
        XCTAssertEqual(long.updatedAt, now)
        XCTAssertTrue(long.planConfirmed)
        let lost = try XCTUnwrap(store.snapshot(now: now.addingTimeInterval(1_981)).first)
        XCTAssertEqual(lost.status, "unknown")
        XCTAssertFalse(lost.longRunning)
        XCTAssertFalse(lost.planConfirmed)
        try apply(store, beat, now.addingTimeInterval(2_040))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(2_040)).first?.status, "unknown")
        try apply(store, #"{"version":1,"provider":"opencode","session":"long","kind":"active"}"#, now.addingTimeInterval(2_100))
        XCTAssertFalse(try XCTUnwrap(store.snapshot(now: now.addingTimeInterval(2_100)).first).planConfirmed)
        try apply(store, #"{"version":1,"provider":"opencode","session":"long","kind":"gap"}"#, now.addingTimeInterval(2_100))
        try apply(store, beat, now.addingTimeInterval(2_100))
        XCTAssertEqual(store.snapshot(now: now.addingTimeInterval(2_100)).first?.status, "unknown")
        try apply(store, #"{"version":1,"provider":"opencode","session":"long","kind":"completed"}"#, now.addingTimeInterval(2_160))
        try apply(store, beat, now.addingTimeInterval(2_160))
        XCTAssertTrue(store.snapshot(now: now.addingTimeInterval(2_160)).isEmpty)
    }

    func testHeartbeatKeepsApprovalWaitingRatherThanRunning() throws {
        let store = ExternalProviderStateStore()
        try apply(store, #"{"version":1,"provider":"deepseek","session":"wait","kind":"waiting"}"#, now)
        try apply(store, #"{"version":1,"provider":"deepseek","session":"wait","kind":"heartbeat"}"#, now.addingTimeInterval(1_740))
        let task = try XCTUnwrap(store.snapshot(now: now.addingTimeInterval(1_800)).first)
        XCTAssertEqual(task.status, "waiting")
        XCTAssertFalse(task.longRunning)
        XCTAssertFalse(task.startKey.isEmpty)
        XCTAssertEqual(task.startedAt, now)
    }

    func testOverflowInvalidatesActiveClaims() throws {
        let store = ExternalProviderStateStore()
        for index in 0..<256 {
            try apply(store, #"{"version":1,"provider":"deepseek","session":"s\#(index)","kind":"active"}"#, now)
        }
        let overflow = try XCTUnwrap(parse(#"{"version":1,"provider":"deepseek","session":"overflow","kind":"active"}"#))
        XCTAssertFalse(store.apply(overflow, now: now))
        XCTAssertTrue(store.snapshot(now: now).allSatisfy { $0.status == "unknown" })
    }
}
