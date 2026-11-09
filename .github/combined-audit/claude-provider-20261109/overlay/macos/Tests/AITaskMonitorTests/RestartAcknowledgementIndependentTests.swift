import Foundation
import XCTest
@testable import AITaskMonitor

final class RestartAcknowledgementIndependentTests: XCTestCase {
    private let a = String(repeating: "a", count: 32)
    private let b = String(repeating: "b", count: 32)
    private let instance = String(repeating: "c", count: 32)

    private func generation(_ directory: String, _ scope: ExternalProviderV2Scope) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/generations-v2.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let values = try XCTUnwrap(json["generations"] as? [String: String])
        return try XCTUnwrap(values[scope.provider + ":" + scope.scope])
    }

    private func frame(_ scope: ExternalProviderV2Scope, _ generation: String, _ kind: String,
                       ticket: String? = nil, sequence: Int? = nil, eventKind: String = "active") throws -> Data {
        var value: [String: Any] = ["version": 2, "provider": scope.provider, "scope": scope.scope,
            "generation": generation, "instance": instance, "kind": kind]
        if kind == "event" {
            value["ticket"] = ticket.map { $0 as Any } ?? NSNull()
            value["seq"] = sequence.map { $0 as Any } ?? NSNull()
            value["event"] = ["version": 1, "provider": scope.provider,
                "session": scope.scope + "_work", "kind": eventKind]
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    private func send(_ runtime: ExternalProviderV2Runtime, _ payload: Data) -> [String: Any] {
        runtime.broker.receive(payload, now: DispatchTime.now().uptimeNanoseconds)
    }

    func testOtherProfilePendingReplyDoesNotRejectOrBlockRestartAction() throws {
        let path = "/private/tmp/aitm-provider-ack-" + UUID().uuidString
        let first = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([first, other])
        let ga = try generation(path, first), gb = try generation(path, other)
        _ = send(runtime, try frame(first, ga, "hello"))
        _ = send(runtime, try frame(other, gb, "hello"))
        _ = send(runtime, try frame(first, ga, "event"))
        _ = send(runtime, try frame(other, gb, "event"))
        XCTAssertEqual(runtime.snapshot().filter(\.isUnconfirmed).count, 2)

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var observedFinish = false
        let pending = try frame(other, gb, "hello")
        DispatchQueue.global().async {
            runtime.broker.receiveResponding(pending, now: DispatchTime.now().uptimeNanoseconds) { _ in
                started.signal(); _ = release.wait(timeout: .now() + 4); return true
            }
            finished.signal()
        }
        defer { release.signal(); if !observedFinish { _ = finished.wait(timeout: .now() + 5) } }
        guard started.wait(timeout: .now() + 2) == .success else { XCTFail("Reply did not reach the checkpoint"); return }
        XCTAssertTrue(runtime.canAcknowledge(first))
        let began = Date()
        let accepted = runtime.acknowledge(first)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "The window must not wait for another profile's reply")
        guard accepted else { XCTFail("An in-flight reply for a neighbour rejected the restart action"); return }
        let during = runtime.snapshot()
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + a + "_work" && $0.isUnconfirmed })
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + b + "_work" && $0.isUnconfirmed })
        release.signal()
        observedFinish = finished.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(observedFinish)
        let ticket = try XCTUnwrap(send(runtime, try frame(first, ga, "hello"))["ticket"] as? String)
        _ = send(runtime, try frame(first, ga, "event", ticket: ticket, sequence: 1))
        let after = runtime.snapshot()
        XCTAssertTrue(after.contains { $0.id == "deepseek:" + a + "_work" && $0.isActive })
        XCTAssertTrue(after.contains { $0.id == "deepseek:" + b + "_work" && $0.isUnconfirmed })
    }

    func testPendingOldReplyCannotPromoteOldFrameOrAffectNeighbour() throws {
        let path = "/private/tmp/aitm-provider-ack-" + UUID().uuidString
        let first = ExternalProviderV2Scope(provider: "deepseek", scope: a)
        let other = ExternalProviderV2Scope(provider: "deepseek", scope: b)
        let runtime = try ExternalProviderV2Runtime(directory: path)
        defer { _ = runtime.stop(); try? FileManager.default.removeItem(atPath: path) }
        try runtime.setScopes([first, other])
        let ga = try generation(path, first), gb = try generation(path, other)
        _ = send(runtime, try frame(first, ga, "hello"))
        _ = send(runtime, try frame(other, gb, "hello"))
        XCTAssertTrue(runtime.acknowledge(first)); XCTAssertTrue(runtime.acknowledge(other))
        let oldTicket = try XCTUnwrap(send(runtime, try frame(first, ga, "hello"))["ticket"] as? String)
        let otherTicket = try XCTUnwrap(send(runtime, try frame(other, gb, "hello"))["ticket"] as? String)
        _ = send(runtime, try frame(first, ga, "event", ticket: oldTicket, sequence: 1))
        _ = send(runtime, try frame(other, gb, "event", ticket: otherTicket, sequence: 1))
        XCTAssertEqual(runtime.snapshot().filter(\.isActive).count, 2)

        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var observedFinish = false
        let pending = try frame(first, ga, "event", ticket: oldTicket, sequence: 2)
        DispatchQueue.global().async {
            runtime.broker.receiveResponding(pending, now: DispatchTime.now().uptimeNanoseconds) { _ in
                started.signal(); _ = release.wait(timeout: .now() + 4); return true
            }
            finished.signal()
        }
        defer { release.signal(); if !observedFinish { _ = finished.wait(timeout: .now() + 5) } }
        guard started.wait(timeout: .now() + 2) == .success else { XCTFail("Reply did not reach the checkpoint"); return }
        let began = Date()
        let accepted = runtime.acknowledge(first)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "The window must not wait for this profile's reply")
        guard accepted else { XCTFail("The pending old frame rejected the restart action"); return }
        let during = runtime.snapshot()
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + a + "_work" && $0.isUnconfirmed && !$0.isActive })
        XCTAssertTrue(during.contains { $0.id == "deepseek:" + b + "_work" && $0.isActive })
        release.signal()
        observedFinish = finished.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(observedFinish)
        let newTicket = try XCTUnwrap(send(runtime, try frame(first, ga, "hello"))["ticket"] as? String)
        XCTAssertNotEqual(newTicket, oldTicket)
        _ = send(runtime, try frame(first, ga, "event", ticket: newTicket, sequence: 1))
        _ = send(runtime, try frame(first, ga, "event", eventKind: "idle"))
        let after = runtime.snapshot()
        XCTAssertTrue(after.contains { $0.id == "deepseek:" + a + "_work" && $0.isActive && !$0.isUnconfirmed })
        XCTAssertTrue(after.contains { $0.id == "deepseek:" + b + "_work" && $0.isActive })
    }
}
