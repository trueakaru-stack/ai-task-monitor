import Foundation
import XCTest
@testable import AITaskMonitor

final class LoopDetectorTests: XCTestCase {
    func testRepeatedFailuresWarnAndDismissUntilSequenceResets() {
        let now = Date()
        var detector = LoopDetector()
        for index in 0..<5 {
            XCTAssertEqual(detector.consume(failure(id: "failure-\(index)", at: now.addingTimeInterval(Double(index))), now: now.addingTimeInterval(10)), .toolFailed)
        }
        XCTAssertEqual(detector.warning, LoopWarning(threshold: 5, windowMinutes: 10))
        XCTAssertNil(detector.consume(failure(id: "failure-4", at: now.addingTimeInterval(4)), now: now.addingTimeInterval(10)))
        detector.dismiss()
        XCTAssertNil(detector.warning)
        _ = detector.consume(failure(id: "failure-5", at: now.addingTimeInterval(5)), now: now.addingTimeInterval(10))
        XCTAssertNil(detector.warning)
        _ = detector.consume(event(id: "changed", kind: .fileFinished, at: now.addingTimeInterval(6)), now: now.addingTimeInterval(10))
        for index in 0..<5 {
            _ = detector.consume(failure(id: "next-\(index)", at: now.addingTimeInterval(Double(index + 7))), now: now.addingTimeInterval(20))
        }
        XCTAssertNotNil(detector.warning)
    }

    func testDifferentCommandsCodesSuccessAndUnknownCommandsReset() {
        let now = Date()
        var detector = LoopDetector(threshold: 3, windowMinutes: 10)
        _ = detector.consume(failure(id: "one", at: now), now: now)
        _ = detector.consume(failure(id: "two", at: now.addingTimeInterval(1)), now: now)
        _ = detector.consume(failure(id: "other", at: now.addingTimeInterval(2), command: ["other"]), now: now)
        XCTAssertNil(detector.warning)
        _ = detector.consume(failure(id: "new-code", at: now.addingTimeInterval(3), code: 2), now: now)
        _ = detector.consume(event(id: "success", kind: .commandFinished, at: now.addingTimeInterval(4), status: "completed", code: 0), now: now)
        _ = detector.consume(failure(id: "three", at: now.addingTimeInterval(5)), now: now)
        _ = detector.consume(failure(id: "four", at: now.addingTimeInterval(6)), now: now)
        _ = detector.consume(event(id: "unknown", kind: .commandStarted, at: now.addingTimeInterval(7), command: nil), now: now)
        _ = detector.consume(failure(id: "five", at: now.addingTimeInterval(8)), now: now)
        XCTAssertNil(detector.warning)
    }

    func testSettingsWindowExpiryAndTaskIsolation() {
        let now = Date()
        var first = LoopDetector(threshold: 3, windowMinutes: 1)
        var second = LoopDetector(threshold: 3, windowMinutes: 1)
        for index in 0..<3 {
            _ = first.consume(failure(id: "same-\(index)", at: now.addingTimeInterval(Double(index))), now: now.addingTimeInterval(3))
        }
        XCTAssertNotNil(first.warning)
        XCTAssertNil(second.warning)
        _ = second.consume(failure(id: "same-0", at: now), now: now)
        first.refresh(now: now.addingTimeInterval(100))
        XCTAssertNil(first.warning)
        first.configure(threshold: 10, windowMinutes: 30)
        XCTAssertEqual(first.threshold, 10)
        XCTAssertEqual(first.windowMinutes, 30)
        first.configure(threshold: 2, windowMinutes: 31)
        XCTAssertEqual(first.threshold, 10)
        XCTAssertEqual(first.windowMinutes, 30)
    }

    func testParserAcceptsOnlyBoundedStructuredEvents() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(id: String, event: String, itemType: String, exit: Any) throws -> String {
            let item: [String: Any] = ["id": id, "type": itemType, "command": ["synthetic"], "cwd": "/synthetic", "status": "failed", "exit_code": exit]
            let record: [String: Any] = ["timestamp": formatter.string(from: now), "type": "event_msg", "payload": ["type": event, "item": item]]
            return String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        }
        let valid = try line(id: "one", event: "item_completed", itemType: "CommandExecution", exit: 1)
        let invalidID = try line(id: "bad/path", event: "item_completed", itemType: "CommandExecution", exit: 1)
        let booleanCode = try line(id: "two", event: "item_completed", itemType: "CommandExecution", exit: true)
        let file = try line(id: "three", event: "item_completed", itemType: "FileChange", exit: 0)
        let parsed = CodexToolEventParser.parse(tail: [valid, invalidID, booleanCode, file].joined(separator: "\n"), since: now.addingTimeInterval(-1), now: now)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed[0].exitCode, 1)
        XCTAssertNil(parsed[1].exitCode)
        XCTAssertEqual(parsed[2].kind, .fileFinished)
        XCTAssertTrue(CodexToolEventParser.parse(tail: valid, since: now.addingTimeInterval(1), now: now).isEmpty)
    }

    private func failure(id: String, at: Date, command: [String] = ["synthetic"], code: Int = 1) -> CodexToolEvent {
        event(id: id, kind: .commandFinished, at: at, command: command, status: "failed", code: code)
    }

    private func event(id: String, kind: CodexToolEventKind, at: Date, command: [String]? = ["synthetic"], status: String = "", code: Int? = nil) -> CodexToolEvent {
        CodexToolEvent(id: id, kind: kind, time: at, command: command, workingDirectory: "/synthetic", status: status, exitCode: code)
    }
}
