import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeHookLockTests: XCTestCase {
    func testBusyEventLogFailsOpenAfterBoundedWait() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-hook-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("claude-events.lock").path
        let descriptor = path.withCString { open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let started = Date()
        let result = ClaudeHook.process(["hook_event_name": "UserPromptSubmit", "session_id": "synthetic"], directory: root)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result, 0)
        XCTAssertGreaterThanOrEqual(elapsed, 1.6)
        XCTAssertLessThan(elapsed, 4.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude-events-v2.jsonl").path))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(ClaudeHook.process(["hook_event_name": "UserPromptSubmit", "session_id": "synthetic"], directory: root), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude-events-v2.jsonl").path))
    }
}
