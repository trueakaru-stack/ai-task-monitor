import Foundation
import XCTest
@testable import AITaskMonitor

final class V1ProtectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)

    private func send(_ store: ExternalProviderStateStore, _ json: String) throws {
        let event = try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
        XCTAssertTrue(store.apply(event, now: now))
    }

    func testReconnectDoesNotConfirmOrRemoveAndOtherProfileStaysActive() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode", "deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [a,b])
        try send(store, #"{"version":1,"provider":"opencode","session":"open","kind":"active"}"#)
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_one\",\"kind\":\"active\"}")
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(b)_two\",\"kind\":\"active\"}")
        XCTAssertEqual(store.snapshot(now: now).filter { $0.status == "active" }.count, 3)
        store.retainProviders(["deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [b])
        store.retainProviders(["opencode", "deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [a,b])
        try send(store, #"{"version":1,"provider":"opencode","session":"open","kind":"completed"}"#)
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_one\",\"kind\":\"completed\"}")
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_one\",\"kind\":\"plan\",\"steps\":[{\"title\":\"Наблюдаемый этап\",\"status\":\"done\"}]}")
        let tasks = store.snapshot(now: now)
        let open = try XCTUnwrap(tasks.first { $0.provider == "opencode" })
        let first = try XCTUnwrap(tasks.first { $0.session == "\(a)_one" })
        let second = try XCTUnwrap(tasks.first { $0.session == "\(b)_two" })
        XCTAssertEqual(open.status, "unknown")
        XCTAssertFalse(open.planConfirmed)
        XCTAssertEqual(first.status, "unknown")
        XCTAssertFalse(first.planConfirmed)
        XCTAssertEqual(first.steps.first?.title, "Наблюдаемый этап")
        XCTAssertEqual(second.status, "active")
        let mapped = try XCTUnwrap(ExternalProviderTaskMapper.tasks(tasks).first { $0.id == "deepseek:\(a)_one" })
        XCTAssertTrue(mapped.isUnconfirmed)
        XCTAssertNil(mapped.progress)
        XCTAssertEqual(mapped.progressKind, .none)
        XCTAssertFalse(mapped.planConfirmed)
    }

    func testGapAndNewNamespaceStayScoped() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode", "deepseek", "kimi"])
        store.retainSessionScopes(provider: "deepseek", scopes: [a,b])
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(b)_two\",\"kind\":\"started\"}")
        try send(store, #"{"version":1,"provider":"kimi","session":"other","kind":"started"}"#)
        store.markSessionScopesGap(provider: "deepseek", scopes: [a])
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_one\",\"kind\":\"waiting\"}")
        let c = String(repeating: "c", count: 32)
        store.retainSessionScopes(provider: "deepseek", scopes: [b,c])
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(c)_new\",\"kind\":\"active\"}")
        let tasks = store.snapshot(now: now)
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.session == "\(b)_two" }).status, "active")
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.session == "\(c)_new" }).status, "unknown")
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.provider == "kimi" }).status, "unknown")
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(c)_ghost\",\"kind\":\"completed\"}")
        XCTAssertFalse(store.snapshot(now: now).contains { $0.session == "\(c)_ghost" })
    }

    @MainActor
    func testDuplicateProfileNamespacesAreNotUnique() {
        let profiles = [
            DeepSeekProfile(name: "one", state: "connected", scope: a, error: nil),
            DeepSeekProfile(name: "two", state: "connected", scope: a, error: nil),
            DeepSeekProfile(name: "three", state: "connected", scope: b, error: nil)
        ]
        XCTAssertEqual(TaskStore.ambiguousDeepSeekScopes(profiles), [a])
        let partial = [
            DeepSeekProfile(name: "one", state: "partial", scope: nil, error: nil),
            DeepSeekProfile(name: "two", state: "connected", scope: a, error: nil),
            DeepSeekProfile(name: "three", state: "connected", scope: b, error: nil)
        ]
        XCTAssertEqual(TaskStore.ambiguousDeepSeekScopes(partial, seenScopes: ["one":a,"two":a,"three":b]), [a])
    }

    func testRepeatedReconnectsAndCapacityStayScoped() throws {
        let store = ExternalProviderStateStore()
        store.retainProviders(["opencode", "deepseek"])
        store.retainSessionScopes(provider: "deepseek", scopes: [a,b])
        try send(store, #"{"version":1,"provider":"opencode","session":"healthy","kind":"active"}"#)
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_stable\",\"kind\":\"active\"}")
        try send(store, "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(b)_healthy\",\"kind\":\"active\"}")
        let active = try XCTUnwrap(ExternalProviderEventParser.parse(Data("{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_stable\",\"kind\":\"active\"}".utf8)))
        let terminal = try XCTUnwrap(ExternalProviderEventParser.parse(Data("{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(a)_stable\",\"kind\":\"completed\"}".utf8)))
        for _ in 0..<1_000 {
            store.retainSessionScopes(provider: "deepseek", scopes: [b])
            store.retainSessionScopes(provider: "deepseek", scopes: [a,b])
            XCTAssertTrue(store.apply(active, now: now))
            XCTAssertTrue(store.apply(terminal, now: now))
        }
        var tasks = store.snapshot(now: now)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.session == "\(a)_stable" }).status, "unknown")
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.session == "\(b)_healthy" }).status, "active")
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.provider == "opencode" }).status, "active")
        var accepted = 0
        for index in 0..<1_000 {
            let scope = String(format: "%032x", index)
            store.retainSessionScopes(provider: "deepseek", scopes: [b,scope])
            let json = "{\"version\":1,\"provider\":\"deepseek\",\"session\":\"\(scope)_task\",\"kind\":\"active\"}"
            let event = try XCTUnwrap(ExternalProviderEventParser.parse(Data(json.utf8)))
            if store.apply(event, now: now) { accepted += 1 }
        }
        tasks = store.snapshot(now: now)
        XCTAssertEqual(accepted, 253)
        XCTAssertEqual(tasks.count, 256)
        XCTAssertEqual(try XCTUnwrap(tasks.first { $0.session == "\(b)_healthy" }).status, "active")
    }
}
