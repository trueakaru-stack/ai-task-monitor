import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderV2BrokerTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let c = String(repeating: "c", count: 32)
    private let d = String(repeating: "d", count: 32)
    private let t = String(repeating: "e", count: 32)
    private let t2 = String(repeating: "f", count: 32)

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func frame(_ scope: ExternalProviderV2Scope, generation: String, instance: String, kind: String) -> [String: Any] {
        ["version": 2, "provider": scope.provider, "scope": scope.scope, "generation": generation,
         "instance": instance, "kind": kind]
    }

    private func event(_ scope: ExternalProviderV2Scope, generation: String, instance: String,
                       ticket: String?, seq: Int?, session: String, kind: String = "active") -> [String: Any] {
        var value = frame(scope, generation: generation, instance: instance, kind: "event")
        value["ticket"] = ticket.map { $0 as Any } ?? NSNull()
        value["seq"] = seq.map { $0 as Any } ?? NSNull()
        value["event"] = ["version": 1, "provider": scope.provider, "session": session, "kind": kind]
        return value
    }

    private func hello(_ broker: ExternalProviderV2Broker, _ scope: ExternalProviderV2Scope,
                       generation: String, instance: String, now: UInt64 = 10) throws -> [String: Any] {
        broker.receive(try data(frame(scope, generation: generation, instance: instance, kind: "hello")), now: now)
    }

    func testOnlyActionAndNewHelloIssueTicket() throws {
        let broker = ExternalProviderV2Broker(), source = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(source, generation: a))
        XCTAssertEqual(try hello(broker, source, generation: a, instance: b)["state"] as? String, "wait")
        let unknown = event(source, generation: a, instance: b, ticket: nil, seq: nil, session: "old")
        XCTAssertEqual(broker.receive(try data(unknown), now: 11)["accepted"] as? Bool, true)
        let before = try XCTUnwrap(broker.drain().first)
        XCTAssertFalse(broker.isCurrent(before))
        XCTAssertTrue(broker.acknowledgeRestart(source, generation: a, ticket: t))
        XCTAssertEqual(try hello(broker, source, generation: a, instance: c)["ticket"] as? String, t)
        let fresh = event(source, generation: a, instance: c, ticket: t, seq: 1, session: "new")
        XCTAssertEqual(broker.receive(try data(fresh), now: 12)["accepted"] as? Bool, true)
        let notice = try XCTUnwrap(broker.drain().first { $0.event?.session == "new" })
        XCTAssertTrue(broker.isCurrent(notice))
    }

    func testDeepSeekSelectedScopeDoesNotRevokeNeighbour() throws {
        let broker = ExternalProviderV2Broker()
        let first = ExternalProviderV2Scope(provider: "deepseek", scope: a), second = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        XCTAssertTrue(broker.configure(first, generation: c)); XCTAssertTrue(broker.configure(second, generation: d))
        _ = try hello(broker, first, generation: c, instance: a); _ = try hello(broker, second, generation: d, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(first, generation: c, ticket: t))
        XCTAssertTrue(broker.acknowledgeRestart(second, generation: d, ticket: t2))
        _ = try hello(broker, first, generation: c, instance: a); _ = try hello(broker, second, generation: d, instance: b)
        let frame = event(second, generation: d, instance: b, ticket: t2, seq: 1, session: b + "_task")
        XCTAssertEqual(broker.receive(try data(frame), now: 11)["accepted"] as? Bool, true)
        let other = try XCTUnwrap(broker.drain().first { $0.event != nil })
        XCTAssertTrue(broker.acknowledgeRestart(first, generation: c, ticket: t2))
        XCTAssertTrue(broker.isCurrent(other))
    }

    func testOldDetachedFrameCannotBecomeCurrentAfterActionOrReconfigure() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(scope, generation: a)); _ = try hello(broker, scope, generation: a, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t)); _ = try hello(broker, scope, generation: a, instance: b)
        _ = broker.receive(try data(event(scope, generation: a, instance: b, ticket: t, seq: 1, session: "s")), now: 11)
        let detached = try XCTUnwrap(broker.drain().first { $0.event != nil })
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t2))
        XCTAssertFalse(broker.isCurrent(detached))
        XCTAssertTrue(broker.configure(scope, generation: c))
        XCTAssertFalse(broker.acknowledgeRestart(scope, generation: a, ticket: t))
        XCTAssertFalse(broker.isCurrent(detached))
    }

    func testSequenceGapRevokesOnlyOrigin() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(scope, generation: a)); _ = try hello(broker, scope, generation: a, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t))
        _ = try hello(broker, scope, generation: a, instance: b); _ = try hello(broker, scope, generation: a, instance: c)
        _ = broker.receive(try data(event(scope, generation: a, instance: b, ticket: t, seq: 1, session: "one")), now: 11)
        _ = broker.receive(try data(event(scope, generation: a, instance: c, ticket: t, seq: 1, session: "two")), now: 11)
        let notices = broker.drain(), neighbour = try XCTUnwrap(notices.first { $0.instance == c })
        XCTAssertEqual(broker.receive(try data(event(scope, generation: a, instance: b, ticket: t, seq: 3, session: "one")), now: 12)["accepted"] as? Bool, false)
        XCTAssertTrue(broker.drain().contains { $0.gap && $0.instance == b })
        XCTAssertTrue(broker.isCurrent(neighbour))
        XCTAssertEqual(try hello(broker, scope, generation: a, instance: b)["state"] as? String, "wait")
    }

    func testRejectsWrongScopeAndExtraFields() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        XCTAssertTrue(broker.configure(scope, generation: c)); _ = try hello(broker, scope, generation: c, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: c, ticket: t)); _ = try hello(broker, scope, generation: c, instance: b)
        let wrong = event(scope, generation: c, instance: b, ticket: t, seq: 1, session: d + "_wrong")
        XCTAssertEqual(broker.receive(try data(wrong), now: 11)["accepted"] as? Bool, false)
        var extra = event(scope, generation: c, instance: b, ticket: t, seq: 1, session: a + "_ok")
        extra["prompt"] = "private"
        XCTAssertEqual(broker.receive(try data(extra), now: 11)["accepted"] as? Bool, false)
        let notices = broker.drain()
        XCTAssertTrue(notices.contains { $0.gap && $0.instance == b })
        XCTAssertFalse(notices.contains { $0.event != nil })
    }

    func testExpiredHelloInvalidatesAffectedProducerOnly() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(scope, generation: a)); _ = try hello(broker, scope, generation: a, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t))
        _ = try hello(broker, scope, generation: a, instance: b, now: 10)
        _ = try hello(broker, scope, generation: a, instance: c, now: 20)
        broker.expire(now: 25, timeout: 10)
        let gaps = broker.drain().filter(\.gap)
        XCTAssertEqual(gaps.map(\.instance), [b])
        XCTAssertEqual(try hello(broker, scope, generation: a, instance: b, now: 26)["state"] as? String, "wait")
        XCTAssertEqual(try hello(broker, scope, generation: a, instance: c, now: 26)["state"] as? String, "ready")
    }

    func testUndeliveredReplyRevokesOnlyMatchingProducer() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(scope, generation: a)); _ = try hello(broker, scope, generation: a, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t))
        _ = try hello(broker, scope, generation: a, instance: b); _ = try hello(broker, scope, generation: a, instance: c)
        let lost = try data(event(scope, generation: a, instance: b, ticket: t, seq: 1, session: "one"))
        let other = try data(event(scope, generation: a, instance: c, ticket: t, seq: 1, session: "two"))
        _ = broker.receive(lost, now: 11); _ = broker.receive(other, now: 11)
        let notices = broker.drain(), own = try XCTUnwrap(notices.first { $0.instance == b })
        let neighbour = try XCTUnwrap(notices.first { $0.instance == c })
        broker.replyUndelivered(lost)
        XCTAssertFalse(broker.isCurrent(own)); XCTAssertTrue(broker.isCurrent(neighbour))
        XCTAssertTrue(broker.drain().contains { $0.gap && $0.instance == b })
    }

    func testFailedReplyCannotExposeCurrentFrame() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        XCTAssertTrue(broker.configure(scope, generation: c)); _ = try hello(broker, scope, generation: c, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: c, ticket: t))
        _ = try hello(broker, scope, generation: c, instance: b)
        let payload = try data(event(scope, generation: c, instance: b, ticket: t, seq: 1, session: a + "_task"))
        broker.receiveResponding(payload, now: 11) { _ in false }
        let notices = broker.drain()
        XCTAssertFalse(notices.contains { $0.event != nil && broker.isCurrent($0) })
        XCTAssertTrue(notices.contains { $0.gap && $0.instance == b })
    }

    func testNestedSourceGapRevokesTicketAndCannotBeReused() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        XCTAssertTrue(broker.configure(scope, generation: c)); _ = try hello(broker, scope, generation: c, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: c, ticket: t))
        _ = try hello(broker, scope, generation: c, instance: b)
        let frame = event(scope, generation: c, instance: b, ticket: t, seq: 1, session: a + "_task", kind: "gap")
        XCTAssertEqual(broker.receive(try data(frame), now: 11)["accepted"] as? Bool, true)
        XCTAssertTrue(broker.drain().contains { $0.gap && $0.instance == b })
        XCTAssertEqual(try hello(broker, scope, generation: c, instance: b)["state"] as? String, "wait")
        XCTAssertFalse(broker.acknowledgeRestart(scope, generation: c, ticket: t))
        XCTAssertFalse(broker.configure(scope, generation: c))
    }

    func testQueueOverflowRevokesAffectedProducerAndReportsGap() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        XCTAssertTrue(broker.configure(scope, generation: a)); _ = try hello(broker, scope, generation: a, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: a, ticket: t)); _ = try hello(broker, scope, generation: a, instance: b)
        for index in 1...1024 {
            XCTAssertEqual(broker.receive(try data(event(scope, generation: a, instance: b, ticket: t, seq: index, session: "s")), now: 11)["accepted"] as? Bool, true)
        }
        XCTAssertEqual(broker.receive(try data(event(scope, generation: a, instance: b, ticket: t, seq: 1025, session: "s")), now: 11)["accepted"] as? Bool, false)
        let notices = broker.drain()
        XCTAssertTrue(notices.contains { $0.gap && $0.instance == b })
        XCTAssertFalse(notices.filter { $0.event != nil }.contains { broker.isCurrent($0) })
    }

    func testRepeatedGenerationsBoundGapHistory() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        for index in 0..<100 {
            let generation = String(format: "%032x", index + 1), instance = String(format: "%032x", index + 200)
            XCTAssertTrue(broker.configure(scope, generation: generation)); _ = try hello(broker, scope, generation: generation, instance: instance)
            XCTAssertTrue(broker.acknowledgeRestart(scope, generation: generation, ticket: t))
            _ = try hello(broker, scope, generation: generation, instance: instance)
        }
        let gaps = broker.drain().filter(\.gap)
        XCTAssertLessThanOrEqual(gaps.count, 32)
        XCTAssertTrue(gaps.contains { $0.instance.isEmpty && $0.generation.isEmpty })
    }

    func testTooManyProducersReportScopeLoss() throws {
        let broker = ExternalProviderV2Broker(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        XCTAssertTrue(broker.configure(scope, generation: c)); _ = try hello(broker, scope, generation: c, instance: b)
        XCTAssertTrue(broker.acknowledgeRestart(scope, generation: c, ticket: t))
        for index in 0..<32 {
            let id = String(format: "%032x", index + 100)
            XCTAssertEqual(try hello(broker, scope, generation: c, instance: id)["state"] as? String, "ready")
        }
        XCTAssertEqual(try hello(broker, scope, generation: c, instance: b)["state"] as? String, "wait")
        XCTAssertTrue(broker.drain().contains { $0.gap && $0.instance == "overflow" })
        XCTAssertEqual(try hello(broker, scope, generation: c, instance: String(format: "%032x", 100))["state"] as? String, "wait")
    }
}
