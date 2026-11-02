import Foundation
import XCTest
@testable import AITaskMonitor

final class DiagnosticWorkerTests: XCTestCase {
    func testWorkerKeepsTaskNamesOnlyInMemoryAndClearsEvents() throws {
        try withWorker { worker, directory in
            let now = Date()
            let title = "SYNTHETIC_PRIVATE_TITLE"
            let saved = expectation(description: "saved")
            worker.update([DiagnosticInput(source: .codex, taskID: "session-1", type: .taskObserved, time: now)],
                          references: [DiagnosticTaskReference(source: .codex, id: "session-1", title: title)], now: now) { result in
                do {
                    let view = try XCTUnwrap(result.get())
                    XCTAssertEqual(view.events.count, 1)
                    let key = try XCTUnwrap(view.events.first?.task)
                    XCTAssertEqual(view.taskNames[key], title)
                } catch { XCTFail("Worker failed: \(error)") }
                saved.fulfill()
            }
            wait(for: [saved], timeout: 10)
            let stored = try String(contentsOf: directory.appendingPathComponent("events-v1.jsonl"), encoding: .utf8)
            XCTAssertFalse(stored.contains(title))
            let cleared = expectation(description: "cleared")
            worker.clear { result in
                if case .failure(let error) = result { XCTFail("Clear failed: \(error)") }
                cleared.fulfill()
            }
            wait(for: [cleared], timeout: 10)
            XCTAssertTrue(try DiagnosticJournal(directory: directory).read(now: now).isEmpty)
        }
    }

    func testFailedWriteIsRetriedWithoutReplacingForeignFile() throws {
        try withWorker { worker, directory in
            let journal = DiagnosticJournal(directory: directory)
            _ = try journal.loadSettings()
            let file = directory.appendingPathComponent("events-v1.jsonl")
            let foreign = Data("unrelated content\n".utf8)
            try foreign.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let failed = expectation(description: "write refused")
            worker.update([DiagnosticInput(source: .codex, taskID: "session-1", type: .taskObserved, time: Date())], references: nil) { result in
                if case .success = result { XCTFail("Foreign content must not be replaced.") }
                failed.fulfill()
            }
            wait(for: [failed], timeout: 10)
            XCTAssertEqual(try Data(contentsOf: file), foreign)
            try FileManager.default.removeItem(at: file)
            let retried = expectation(description: "retried")
            worker.update([], references: []) { result in
                do { XCTAssertEqual(try XCTUnwrap(result.get()).events.count, 1) }
                catch { XCTFail("Retry failed: \(error)") }
                retried.fulfill()
            }
            wait(for: [retried], timeout: 10)
        }
    }

    private func withWorker(_ body: (DiagnosticWorker, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("diagnostics", isDirectory: true)
        try body(DiagnosticWorker(journal: DiagnosticJournal(directory: directory)), directory)
    }
}
