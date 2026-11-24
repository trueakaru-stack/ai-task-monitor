import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeSourceWorkerTests: XCTestCase {
    private final class Gate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var first = true
        private(set) var count = 0

        func waitOnce() {
            lock.lock()
            count += 1
            let shouldWait = first
            first = false
            lock.unlock()
            guard shouldWait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    private final class LockedValues {
        private let lock = NSLock()
        private var strings: [String] = []
        private var count = 0
        let second = DispatchSemaphore(value: 0)
        func add(_ value: String) { lock.lock(); strings.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return strings }
        func tick() {
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 2 { second.signal() }
        }
        var ticks: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private final class SecondReadGate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        func observe() {
            lock.lock(); count += 1; let isSecond = count == 2; lock.unlock()
            guard isSecond else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    private func eventFile(in root: URL) throws -> URL {
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        var event = ClaudeHook.makeRecord(from: ["session_id": "fixture", "hook_event_name": "UserPromptSubmit"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        event["timestamp"] = formatter.string(from: Date().addingTimeInterval(-3))
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0a)
        try data.write(to: file)
        return file
    }

    private func task(_ id: String) -> MonitoredTask {
        MonitoredTask(id: id, provider: .codex, title: id, activity: "Synthetic", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: "turn-\(id)")
    }

    private func append(_ name: String, to file: URL, offset: TimeInterval) throws {
        var input: [String: Any] = ["session_id": "fixture", "hook_event_name": name]
        if name == "Stop" { input["background_tasks"] = [String](); input["session_crons"] = [String]() }
        var event = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        event["timestamp"] = formatter.string(from: Date().addingTimeInterval(offset))
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    @MainActor
    func testFrozenActualReaderAllowsSelectionAndInvalidatesLateResult() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let gate = Gate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() })
        let worker = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false, connection: { .connected })
        defer { worker.close() }
        var observed: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { observed = $0 })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                              previewTasks: [task("first"), task("second")])
        let dot = try XCTUnwrap(store.compactDots.first { $0.task.id == "second" })
        store.selectCompactTask(dot: dot)
        XCTAssertEqual(store.tasks[store.compactIndex].id, "second")
        XCTAssertNil(observed, "Selection must finish while the real reader is still blocked")
        XCTAssertFalse(worker.tryRead(observedSince: Date()) { _ in XCTFail("A second reader must not start") })
        worker.invalidate()
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while observed == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let result = try XCTUnwrap(observed)
        guard case .changed = result.outcome else { return XCTFail("A late result must be invalidated") }
        XCTAssertTrue(result.phasePoisoned)
        XCTAssertTrue(result.after.affectsAll)
    }

    @MainActor
    func testClosingWhileReaderIsBlockedDoesNotWaitOrPublish() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let gate = Gate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() })
        var worker: ClaudeSourceWorker? = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false, connection: { .connected })
        var received = false
        XCTAssertTrue(worker!.tryRead(observedSince: Date().addingTimeInterval(-60)) { _ in received = true })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let start = ProcessInfo.processInfo.systemUptime
        worker?.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        weak var weakWorker = worker
        worker = nil
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while weakWorker != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertNil(weakWorker)
        XCTAssertFalse(received)
    }

    @MainActor
    func testNewPromptAfterCapturedStopInvalidatesSnapshot() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        try append("Stop", to: file, offset: -2)
        let stopped = try ClaudeTaskReader(eventFile: file).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(stopped.neutralEndedIDs.contains("claude:fixture"), "The first snapshot must contain a real Stop")
        let gate = Gate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.waitOnce() })
        let worker = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        try append("UserPromptSubmit", to: file, offset: -1)
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .changed = try XCTUnwrap(result).outcome else { return XCTFail("The stale Stop must not be published") }
        result = nil
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let retryDeadline = Date().addingTimeInterval(5)
        while result == nil && Date() < retryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .snapshot(let current) = try XCTUnwrap(result).outcome else { return XCTFail("The new prompt must be reread") }
        XCTAssertTrue(current.tasks.contains { $0.id == "claude:fixture" && $0.isActive })
        XCTAssertFalse(current.neutralEndedIDs.contains("claude:fixture"))
    }

    @MainActor
    func testLateMainDeliveryDoesNotPublishConfirmedSnapshot() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let reads = LockedValues()
        let ready = DispatchSemaphore(value: 0)
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in reads.tick() })
        let worker = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false,
                                        beforeDeliveryForTests: { ready.signal() }, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        XCTAssertEqual(ready.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(reads.ticks, 2)
        Thread.sleep(forTimeInterval: 2.5)
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .changed = try XCTUnwrap(result).outcome else { return XCTFail("Late delivery must not confirm an old snapshot") }
    }

    @MainActor
    func testFrozenSecondReadDoesNotPublishOldSnapshot() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let gate = SecondReadGate()
        defer { gate.release.signal() }
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in gate.observe() })
        let worker = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .changed = try XCTUnwrap(result).outcome else { return XCTFail("A frozen second read must remain unconfirmed") }
    }

    @MainActor
    func testLanguageChangeDuringReadInvalidatesOldResult() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let oldLanguage = AppLanguage.previewOverride
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = oldLanguage }
        let gate = Gate()
        defer { gate.release.signal() }
        let observations = LockedValues()
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in
            observations.add(tr("Русский", "English"))
            gate.waitOnce()
            observations.add(tr("Русский", "English"))
        })
        let worker = ClaudeSourceWorker(reader: reader, channelProfile: nil, requiresChannel: false, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        AppLanguage.previewOverride = .ru
        gate.release.signal()
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .changed = try XCTUnwrap(result).outcome else { return XCTFail("Old-language output must not be published") }
        XCTAssertEqual(Array(observations.values.prefix(2)), ["English", "English"])
        XCTAssertEqual(AppLanguage.current, .ru)
    }

    @MainActor
    func testCancellationDuringConnectionDoesNotStartChannelOrReader() throws {
        for cancel in [false, true] {
            let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = try eventFile(in: root)
            let gate = Gate()
            defer { gate.release.signal() }
            let opened = LockedValues(), reads = LockedValues()
            let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in reads.tick() })
            var worker: ClaudeSourceWorker? = ClaudeSourceWorker(reader: reader, channelProfile: root, requiresChannel: true,
                beforeOpenChannelForTests: { opened.tick() }, connection: { gate.waitOnce(); return .connected })
            var result: ClaudeSourceRead?
            XCTAssertTrue(worker!.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
            XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
            if cancel { worker?.close() } else { worker?.invalidate() }
            gate.release.signal()
            if cancel {
                weak var old = worker
                worker = nil
                let deadline = Date().addingTimeInterval(5)
                while old != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                XCTAssertNil(old)
                XCTAssertNil(result)
            } else {
                let deadline = Date().addingTimeInterval(5)
                while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
                guard case .changed = try XCTUnwrap(result).outcome else { return XCTFail("Invalidation must reject the old read") }
                worker?.close()
            }
            XCTAssertEqual(opened.ticks, 0)
            XCTAssertEqual(reads.ticks, 0)
        }
    }

    @MainActor
    func testRequiredMissingChannelIsReportedUnavailable() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: file), channelProfile: nil,
                                        requiresChannel: true, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let current = try XCTUnwrap(result)
        XCTAssertTrue(current.channelUnavailable)
        XCTAssertTrue(current.phasePoisoned)
    }
}
