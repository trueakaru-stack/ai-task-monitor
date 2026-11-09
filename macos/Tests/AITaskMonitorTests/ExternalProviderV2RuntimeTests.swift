import Foundation
import XCTest
@testable import AITaskMonitor

final class ExternalProviderV2RuntimeTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let instance = String(repeating: "c", count: 32)

    private func directory() -> String { "/private/tmp/aitm-provider-\(UUID().uuidString)" }

    private func generation(_ directory: String, _ scope: ExternalProviderV2Scope) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/generations-v2.json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let generations = try XCTUnwrap(value["generations"] as? [String: String])
        return try XCTUnwrap(generations[scope.provider + ":" + scope.scope])
    }

    private func send(_ runtime: ExternalProviderV2Runtime, scope: ExternalProviderV2Scope, generation: String,
                      kind: String, ticket: String? = nil, seq: Int? = nil, session: String = "task",
                      eventKind: String = "active") throws -> [String: Any] {
        var frame: [String: Any] = ["version": 2, "provider": scope.provider, "scope": scope.scope,
            "generation": generation, "instance": instance, "kind": kind]
        if kind == "event" {
            frame["ticket"] = ticket.map { $0 as Any } ?? NSNull()
            frame["seq"] = seq.map { $0 as Any } ?? NSNull()
            var event: [String: Any] = ["version": 1, "provider": scope.provider,
                "session": scope.provider == "deepseek" ? scope.scope + "_" + session : session, "kind": eventKind]
            if eventKind == "plan" { event["steps"] = [["title": "Old step", "status": "done"]] }
            frame["event"] = event
        }
        let data = try JSONSerialization.data(withJSONObject: frame)
        return runtime.broker.receive(data, now: DispatchTime.now().uptimeNanoseconds)
    }

    func testSelectedProfileGetsNewStateAndDelayedFramesCannotRemoveIt() throws {
        let path = directory(), first = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([first, other])
        let ga = try generation(path, first), gb = try generation(path, other)
        _ = try send(runtime, scope: first, generation: ga, kind: "hello")
        _ = try send(runtime, scope: other, generation: gb, kind: "hello")
        _ = try send(runtime, scope: first, generation: ga, kind: "event", session: "old")
        _ = try send(runtime, scope: other, generation: gb, kind: "event", session: "neighbour")
        let initial = runtime.snapshot()
        XCTAssertEqual(initial.count, 2); XCTAssertTrue(initial.allSatisfy(\.isUnconfirmed))
        XCTAssertTrue(runtime.acknowledge(first))
        let ticket = try XCTUnwrap(send(runtime, scope: first, generation: ga, kind: "hello")["ticket"] as? String)
        _ = try send(runtime, scope: first, generation: ga, kind: "event", ticket: ticket, seq: 1, session: "work")
        _ = try send(runtime, scope: first, generation: ga, kind: "event", session: "work", eventKind: "plan")
        _ = try send(runtime, scope: first, generation: ga, kind: "event", session: "work", eventKind: "idle")
        let tasks = runtime.snapshot()
        let current = try XCTUnwrap(tasks.first { $0.id == "deepseek:" + a + "_work" })
        XCTAssertTrue(current.isActive); XCTAssertFalse(current.isUnconfirmed); XCTAssertTrue(current.steps.isEmpty)
        XCTAssertTrue(tasks.contains { $0.id == "deepseek:" + b + "_neighbour" && $0.isUnconfirmed })
        XCTAssertFalse(runtime.canAcknowledge(ExternalProviderV2Scope(provider: "deepseek", scope: String(repeating: "d", count: 32))))
        _ = try send(runtime, scope: first, generation: ga, kind: "event", ticket: ticket, seq: 2, session: "work", eventKind: "idle")
        XCTAssertFalse(runtime.snapshot().contains { $0.id == "deepseek:" + a + "_work" })
        XCTAssertTrue(runtime.terminalIDs.contains("deepseek:" + a + "_work"))
    }

    func testGapRevokesOnlySelectedProfileAndOldGenerationCannotRestoreIt() throws {
        let path = directory(), first = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([first, other])
        let ga = try generation(path, first), gb = try generation(path, other)
        for (scope, gen) in [(first, ga), (other, gb)] {
            _ = try send(runtime, scope: scope, generation: gen, kind: "hello")
            XCTAssertTrue(runtime.acknowledge(scope))
            let ticket = try XCTUnwrap(send(runtime, scope: scope, generation: gen, kind: "hello")["ticket"] as? String)
            _ = try send(runtime, scope: scope, generation: gen, kind: "event", ticket: ticket, seq: 1, session: "work")
        }
        XCTAssertEqual(runtime.snapshot().filter(\.isActive).count, 2)
        let ta = try XCTUnwrap(send(runtime, scope: first, generation: ga, kind: "hello")["ticket"] as? String)
        XCTAssertEqual(try send(runtime, scope: first, generation: ga, kind: "event", ticket: ta, seq: 3)["accepted"] as? Bool, false)
        let lost = runtime.snapshot()
        XCTAssertTrue(lost.contains { $0.id == "deepseek:" + a + "_work" && $0.isUnconfirmed })
        XCTAssertTrue(lost.contains { $0.id == "deepseek:" + b + "_work" && $0.isActive })
        try runtime.setScopes([other])
        try runtime.setScopes([first, other])
        let newer = try generation(path, first)
        XCTAssertNotEqual(ga, newer); XCTAssertEqual(gb, try generation(path, other))
        XCTAssertEqual(try send(runtime, scope: first, generation: ga, kind: "hello")["accepted"] as? Bool, false)
        XCTAssertTrue(runtime.snapshot().contains { $0.id == "deepseek:" + b + "_work" && $0.isActive })
    }

    func testFirstTerminalOrPlanDoesNotEraseOrConfirmOldCard() throws {
        let path = directory(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([scope]); let gen = try generation(path, scope)
        _ = try send(runtime, scope: scope, generation: gen, kind: "hello")
        _ = try send(runtime, scope: scope, generation: gen, kind: "event", session: "work")
        XCTAssertTrue(runtime.snapshot().contains { $0.isUnconfirmed })
        XCTAssertTrue(runtime.acknowledge(scope))
        let ticket = try XCTUnwrap(send(runtime, scope: scope, generation: gen, kind: "hello")["ticket"] as? String)
        _ = try send(runtime, scope: scope, generation: gen, kind: "event", ticket: ticket, seq: 1, session: "work", eventKind: "idle")
        _ = try send(runtime, scope: scope, generation: gen, kind: "event", ticket: ticket, seq: 2, session: "work", eventKind: "plan")
        let task = try XCTUnwrap(runtime.snapshot().first { $0.id == "deepseek:" + a + "_work" })
        XCTAssertTrue(task.isUnconfirmed); XCTAssertFalse(task.isActive); XCTAssertFalse(task.planConfirmed)
        XCTAssertFalse(runtime.terminalIDs.contains(task.id))
    }

    func testOpenCodeStillUnconfirmedAfterAction() throws {
        let path = directory(), source = ExternalProviderV2Scope(provider: "opencode", scope: "global")
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([source]); let gen = try generation(path, source)
        _ = try send(runtime, scope: source, generation: gen, kind: "hello")
        XCTAssertTrue(runtime.acknowledge(source))
        let ticket = try XCTUnwrap(send(runtime, scope: source, generation: gen, kind: "hello")["ticket"] as? String)
        _ = try send(runtime, scope: source, generation: gen, kind: "event", ticket: ticket, seq: 1)
        XCTAssertTrue(runtime.snapshot().contains { $0.isUnconfirmed && !$0.isActive })
    }

    func testSlowReplyDoesNotBlockSnapshotOrShowPendingConfirmation() throws {
        let path = directory(), scope = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([scope, other]); let gen = try generation(path, scope), otherGen = try generation(path, other)
        _ = try send(runtime, scope: scope, generation: gen, kind: "hello")
        XCTAssertTrue(runtime.acknowledge(scope))
        let ticket = try XCTUnwrap(send(runtime, scope: scope, generation: gen, kind: "hello")["ticket"] as? String)
        _ = try send(runtime, scope: scope, generation: gen, kind: "event", ticket: ticket, seq: 1, session: "work")
        _ = try send(runtime, scope: other, generation: otherGen, kind: "hello")
        XCTAssertTrue(runtime.acknowledge(other))
        let otherTicket = try XCTUnwrap(send(runtime, scope: other, generation: otherGen, kind: "hello")["ticket"] as? String)
        _ = try send(runtime, scope: other, generation: otherGen, kind: "event", ticket: otherTicket, seq: 1, session: "work")
        XCTAssertEqual(runtime.snapshot().filter(\.isActive).count, 2)
        let payload: [String: Any] = ["version": 2, "provider": "deepseek", "scope": a,
            "generation": gen, "instance": instance, "kind": "event", "ticket": ticket, "seq": 2,
            "event": ["version": 1, "provider": "deepseek", "session": a + "_work", "kind": "active"]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            runtime.broker.receiveResponding(data, now: DispatchTime.now().uptimeNanoseconds) { _ in
                started.signal(); _ = release.wait(timeout: .now() + 3); return true
            }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let begin = Date(), during = runtime.snapshot(), elapsed = Date().timeIntervalSince(begin)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(elapsed, 1)
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + a + "_work" && $0.isUnconfirmed && !$0.isActive })
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + b + "_work" && $0.isActive })
        XCTAssertEqual(runtime.snapshot().filter(\.isActive).count, 2)
    }
}
