import Foundation
import XCTest
@testable import AITaskMonitor

final class DiagnosticJournalTests: XCTestCase {
    func testSettingsAreBoundedAndPersisted() throws {
        try withJournal { journal, _ in
            XCTAssertEqual(try journal.loadSettings(), DiagnosticSettings())
            let settings = DiagnosticSettings(retentionDays: 1, maximumMB: 2, loopThreshold: 3, loopWindowMinutes: 30)
            try journal.saveSettings(settings)
            XCTAssertEqual(try journal.loadSettings(), settings)
            XCTAssertThrowsError(try journal.saveSettings(DiagnosticSettings(retentionDays: 8)))
            XCTAssertEqual(try journal.loadSettings(), settings)
        }
    }

    func testMetadataIsPseudonymousAndOlderEventsAreRemoved() throws {
        try withJournal { journal, directory in
            let now = Date()
            let secret = "SYNTHETIC_SECRET_9D42EBF6"
            try journal.append([
                DiagnosticInput(source: .codex, taskID: secret, type: .taskObserved, time: now.addingTimeInterval(-8 * 86_400)),
                DiagnosticInput(source: .codex, taskID: secret, type: .taskObserved, time: now),
                DiagnosticInput(source: .claude, taskID: nil, type: .sourceUnavailable, time: now)
            ], now: now)
            let events = try journal.read(now: now)
            XCTAssertEqual(events.count, 2)
            let task = try XCTUnwrap(events.first { $0.type == .taskObserved })
            XCTAssertEqual(task.task, try journal.taskKey(source: .codex, taskID: secret))
            XCTAssertEqual(task.task?.count, 64)
            XCTAssertNil(events.first { $0.type == .sourceUnavailable }?.task)
            let stored = try String(contentsOf: directory.appendingPathComponent("events-v1.jsonl"), encoding: .utf8)
            XCTAssertFalse(stored.contains(secret))
            XCTAssertFalse(stored.contains("prompt"))
            XCTAssertFalse(stored.contains("command"))
            XCTAssertFalse(stored.contains("output"))
            XCTAssertFalse(stored.contains("/synthetic/project"))
        }
    }

    func testConfiguredSizeKeepsOnlyNewestEvents() throws {
        try withJournal { journal, directory in
            try journal.saveSettings(DiagnosticSettings(retentionDays: 7, maximumMB: 1))
            let now = Date()
            let inputs = (0..<8_000).map { index in
                DiagnosticInput(source: .codex, taskID: "session-1", type: .toolStarted, time: now.addingTimeInterval(Double(index - 8_000)))
            }
            try journal.append(inputs, now: now)
            let events = try journal.read(now: now)
            let file = directory.appendingPathComponent("events-v1.jsonl")
            let bytes = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertLessThanOrEqual(bytes, 1_000_000)
            XCTAssertLessThan(events.count, inputs.count)
            XCTAssertGreaterThan(events.count, 0)
            XCTAssertGreaterThan(try XCTUnwrap(events.first).time, inputs[0].time)
            XCTAssertEqual(events.last?.type, .toolStarted)
        }
    }

    func testClockChangeDoesNotDeleteFutureDatedEvents() throws {
        try withJournal { journal, _ in
            let now = Date()
            try journal.append([DiagnosticInput(source: .codex, taskID: "session-1", type: .taskObserved, time: now.addingTimeInterval(3_600))], now: now)
            XCTAssertEqual(try journal.read(now: now).count, 1)
        }
    }

    func testRepeatedSourceEventIsDeduplicatedWithoutStoringItsReference() throws {
        try withJournal { journal, directory in
            let now = Date()
            let reference = "SYNTHETIC_REFERENCE_217"
            let input = DiagnosticInput(source: .codex, taskID: "session-1", type: .toolStarted, time: now, reference: reference)
            try journal.append([input, input], now: now)
            try journal.append([input], now: now)
            XCTAssertEqual(try journal.read(now: now).count, 1)
            let text = try String(contentsOf: directory.appendingPathComponent("events-v1.jsonl"), encoding: .utf8)
            XCTAssertFalse(text.contains(reference))
            XCTAssertFalse(text.contains("session-1"))
        }
    }

    func testInvalidInputAndForeignFilesAreNotOverwritten() throws {
        try withJournal { journal, directory in
            let now = Date()
            try journal.append([DiagnosticInput(source: .codex, taskID: "safe", type: .taskObserved, time: now)], now: now)
            let file = directory.appendingPathComponent("events-v1.jsonl")
            let before = try Data(contentsOf: file)
            XCTAssertThrowsError(try journal.append([DiagnosticInput(source: .codex, taskID: "invalid/path", type: .taskObserved, time: now)], now: now))
            XCTAssertEqual(try Data(contentsOf: file), before)
            let foreign = Data("foreign user data\n".utf8)
            try foreign.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try journal.clear())
            XCTAssertEqual(try Data(contentsOf: file), foreign)
        }
    }

    func testSymlinkTargetIsNotChanged() throws {
        try withJournal { journal, directory in
            _ = try journal.loadSettings()
            let outside = directory.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
            let contents = Data("do not replace".utf8)
            try contents.write(to: outside)
            let link = directory.appendingPathComponent("events-v1.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try journal.append([], now: Date()))
            XCTAssertEqual(try Data(contentsOf: outside), contents)
        }
    }

    func testClearRemovesOnlyJournalEvents() throws {
        try withJournal { journal, directory in
            let now = Date()
            let settings = DiagnosticSettings(retentionDays: 2, maximumMB: 3)
            try journal.saveSettings(settings)
            try journal.append([DiagnosticInput(source: .codex, taskID: "session-1", type: .taskObserved, time: now)], now: now)
            let unrelated = directory.appendingPathComponent("unrelated.txt")
            try Data("keep".utf8).write(to: unrelated)
            let key = try journal.taskKey(source: .codex, taskID: "session-1")
            try journal.clear()
            XCTAssertTrue(try journal.read(now: now).isEmpty)
            XCTAssertEqual(try journal.loadSettings(), settings)
            XCTAssertEqual(try journal.taskKey(source: .codex, taskID: "session-1"), key)
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        }
    }

    func testMalformedJournalIsPreservedUntilConfirmedClear() throws {
        try withJournal { journal, directory in
            _ = try journal.loadSettings()
            let file = directory.appendingPathComponent("events-v1.jsonl")
            let corrupt = Data("{\"format\":\"ai-task-monitor-diagnostics\",\"version\":1}\n{\"partial\":".utf8)
            try corrupt.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try journal.read())
            XCTAssertThrowsError(try journal.append([DiagnosticInput(source: .codex, taskID: "safe", type: .taskObserved, time: Date())]))
            XCTAssertEqual(try Data(contentsOf: file), corrupt)
            try journal.clear()
            XCTAssertTrue(try journal.read().isEmpty)
        }
    }

    private func withJournal(_ body: (DiagnosticJournal, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        try body(DiagnosticJournal(directory: directory), directory)
    }
}
