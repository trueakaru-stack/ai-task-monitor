import Foundation
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class ClaudeTaskStoreBackgroundTests: XCTestCase {
    private final class Gate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var first = true
        func waitOnce() {
            lock.lock(); let wait = first; first = false; lock.unlock()
            guard wait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    private final class TwoReadsGate {
        let enteredFirst = DispatchSemaphore(value: 0)
        let enteredSecond = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        func waitForFirstTwo() {
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 1 {
                enteredFirst.signal()
                _ = releaseFirst.wait(timeout: .now() + 10)
            } else if current == 2 {
                enteredSecond.signal()
                _ = releaseSecond.wait(timeout: .now() + 10)
            }
        }
    }

    private final class Connection {
        private let lock = NSLock()
        private var connected = true
        func read() -> ClaudeIntegration.ConnectionState {
            lock.lock(); defer { lock.unlock() }
            return connected ? .connected : .disconnected
        }
        func update(_ value: Bool) { lock.lock(); connected = value; lock.unlock() }
    }

    private func event(_ name: String, offset: TimeInterval) throws -> Data {
        var input: [String: Any] = ["session_id": "fixture", "hook_event_name": name]
        if name == "Stop" { input["background_tasks"] = [String](); input["session_crons"] = [String]() }
        var record = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        record["timestamp"] = formatter.string(from: Date().addingTimeInterval(offset))
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func task(_ id: String) -> MonitoredTask {
        MonitoredTask(id: "claude:" + id, provider: .claude, title: id, activity: "Synthetic action",
                      isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date(),
                      startKey: "turn-" + id)
    }

    @MainActor
    func testBlockedClaudeReaderDoesNotBlockManualSelection() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-store-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try event("UserPromptSubmit", offset: 1).write(to: file)
        let gate = Gate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() })
        let first = task("first"), second = task("second")
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                              claudeReader: reader, previewTasks: [first, second])
        store.testSeedClaudeTasks([first, second])
        let start = ProcessInfo.processInfo.systemUptime
        store.refresh()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let dot = try XCTUnwrap(store.compactDots.first { $0.task.id == second.id })
        store.selectCompactTask(dot: dot)
        XCTAssertEqual(store.tasks[store.compactIndex].id, second.id)
        XCTAssertTrue(store.testClaudeReadInFlight)
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        store.testPeriodicRefresh()
        XCTAssertTrue(store.tasks.filter { $0.provider == .claude }.allSatisfy { $0.isUnconfirmed && !$0.isActive })
        gate.release.signal()
        waitForClaudeRead(store, timeout: 8)
        XCTAssertEqual(store.tasks[store.compactIndex].id, second.id)
        XCTAssertTrue(store.tasks.contains { $0.id == "claude:fixture" && $0.isActive })
    }

    @MainActor
    func testStopThenNewPromptNeverRemovesCurrentCard() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-store-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try event("UserPromptSubmit", offset: -3).write(to: file)
        let gate = Gate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() })
        let existing = task("fixture")
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                              claudeReader: reader, previewTasks: [existing])
        store.testSeedClaudeTasks([existing])
        Thread.sleep(forTimeInterval: 0.02)
        let stopped = try FileHandle(forWritingTo: file)
        try stopped.seekToEnd()
        try stopped.write(contentsOf: event("Stop", offset: 0))
        try stopped.close()
        XCTAssertTrue(try ClaudeTaskReader(eventFile: file)
            .readSnapshot(observedSince: Date().addingTimeInterval(-1)).neutralEndedIDs.contains(existing.id))
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        Thread.sleep(forTimeInterval: 0.02)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: event("UserPromptSubmit", offset: 0))
        try handle.close()
        gate.release.signal()
        waitForClaudeRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == existing.id && $0.isUnconfirmed && !$0.isActive })
        store.refresh()
        waitForClaudeRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == existing.id && $0.isActive })
    }

    @MainActor
    func testReconnectDoesNotApplyOldTerminalBeforeFreshRead() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-store-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try event("UserPromptSubmit", offset: -3).write(to: file)
        let gate = TwoReadsGate()
        defer { gate.releaseFirst.signal(); gate.releaseSecond.signal() }
        let state = Connection()
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitForFirstTwo() })
        let existing = task("fixture")
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                              claudeReader: reader, previewTasks: [existing],
                              inspectClaudeConnection: { state.read() }, updateClaudeConnection: { state.update($0) })
        store.testSeedClaudeTasks([existing])
        Thread.sleep(forTimeInterval: 0.02)
        let old = try FileHandle(forWritingTo: file)
        try old.seekToEnd()
        try old.write(contentsOf: event("Stop", offset: 0))
        try old.close()
        XCTAssertTrue(try ClaudeTaskReader(eventFile: file)
            .readSnapshot(observedSince: Date().addingTimeInterval(-1)).neutralEndedIDs.contains(existing.id))
        store.refresh()
        XCTAssertEqual(gate.enteredFirst.wait(timeout: .now() + 3), .success)
        store.setClaudeConnected(false)
        store.setClaudeConnected(true)
        Thread.sleep(forTimeInterval: 0.02)
        let current = try FileHandle(forWritingTo: file)
        try current.seekToEnd()
        try current.write(contentsOf: event("UserPromptSubmit", offset: 0))
        try current.close()
        gate.releaseFirst.signal()
        var secondStarted = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if gate.enteredSecond.wait(timeout: .now()) == .success { secondStarted = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(secondStarted, "The replacement read must start after invalidating the old one")
        XCTAssertTrue(store.tasks.contains { $0.id == existing.id && $0.isUnconfirmed && !$0.isActive })
        gate.releaseSecond.signal()
        waitForClaudeRead(store, timeout: 8)
        XCTAssertTrue(store.tasks.contains { $0.id == existing.id && $0.isActive })
    }

    @MainActor
    func testClosingStoreDoesNotWaitForBlockedClaudeReader() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-store-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        try event("UserPromptSubmit", offset: 1).write(to: file)
        let gate = Gate()
        defer { gate.release.signal() }
        var store: TaskStore? = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                                          claudeReader: ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() }),
                                          previewTasks: [])
        weak var worker = store?.testClaudeWorker
        store?.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        weak var releasedStore = store
        let start = ProcessInfo.processInfo.systemUptime
        store = nil
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertNil(releasedStore)
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while worker != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(worker, "The blocked owner must be released when its reader returns")
    }
}
#endif
