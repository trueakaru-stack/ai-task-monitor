import Foundation
import Darwin
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

    @MainActor
    private func readOnce(_ worker: ClaudeSourceWorker) throws -> ClaudeSourceRead {
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return try XCTUnwrap(result)
    }

    @MainActor
    func testAbsentJournalIsDistinctFromAccessDenied() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-access-")
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("missing.jsonl")
        let missingWorker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: absent), channelProfile: nil,
                                               requiresChannel: false, connection: { .connected })
        defer { missingWorker.close() }
        guard case .noEvents = try readOnce(missingWorker).outcome else {
            return XCTFail("A genuinely absent journal should be reported as no events")
        }

        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        guard denied.path.withCString({ chmod($0, 0) }) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { _ = denied.path.withCString { chmod($0, mode_t(0o700)) } }
        let inaccessible = denied.appendingPathComponent("events.jsonl")
        var info = stat()
        let probe = inaccessible.path.withCString { lstat($0, &info) }
        let reason = errno
        guard probe != 0, reason == EACCES || reason == EPERM else {
            return XCTFail("The synthetic runner must actually deny traversal for this test")
        }
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: inaccessible), channelProfile: nil,
                                        requiresChannel: false, connection: { .connected })
        defer { worker.close() }
        guard case .failed(let error) = try readOnce(worker).outcome else {
            return XCTFail("An inaccessible journal must not be treated as empty")
        }
        XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
        XCTAssertTrue([Int(EACCES), Int(EPERM)].contains((error as NSError).code))

        let store = TaskStore(codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("no-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: inaccessible), previewTasks: [])
        store.refresh()
        waitForClaudeRead(store)
        XCTAssertTrue(store.unavailableSources.contains(.claude))
    }

    private func append(_ name: String, to file: URL, offset: TimeInterval, tool: String? = nil) throws {
        var input: [String: Any] = ["session_id": "fixture", "hook_event_name": name]
        if name == "Stop" { input["background_tasks"] = [String](); input["session_crons"] = [String]() }
        if let tool { input["tool_name"] = tool }
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
        let raced = try XCTUnwrap(result)
        guard case .snapshot(let uncertain) = raced.outcome else { return XCTFail("The changed session must stay visible") }
        XCTAssertTrue(raced.changedSessionIDs.contains("claude:fixture"))
        XCTAssertTrue(uncertain.tasks.contains { $0.id == "claude:fixture" && $0.isUnconfirmed })
        XCTAssertFalse(uncertain.neutralEndedIDs.contains("claude:fixture"), "The stale Stop must not be applied")
        result = nil
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let retryDeadline = Date().addingTimeInterval(5)
        while result == nil && Date() < retryDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        guard case .snapshot(let current) = try XCTUnwrap(result).outcome else { return XCTFail("The new prompt must be reread") }
        XCTAssertTrue(current.tasks.contains { $0.id == "claude:fixture" && $0.isActive })
        XCTAssertFalse(current.neutralEndedIDs.contains("claude:fixture"))
    }

    @MainActor
    func testUnchanneledReadAfterSecondSnapshotPreventsApplyingOldStop() throws {
        let root = try codexSyntheticDirectory(prefix: "aitm-claude-source-")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try eventFile(in: root)
        try append("Stop", to: file, offset: -2)
        let before = try ClaudeTaskReader(eventFile: file).readSnapshot(observedSince: Date().addingTimeInterval(-60))
        XCTAssertTrue(before.neutralEndedIDs.contains("claude:fixture"))
        let input: [String: Any] = ["session_id": "fixture", "hook_event_name": "PreToolUse", "tool_name": "Read"]
        XCTAssertNil(ClaudeLoopInput.classify(input), "Read does not send a loop channel event")
        var injected = false
        var writeError: Error?
        let worker = ClaudeSourceWorker(reader: ClaudeTaskReader(eventFile: file), channelProfile: nil,
                                        requiresChannel: false, afterSecondReadForTests: {
            guard !injected else { return }
            injected = true
            do { try self.append("PreToolUse", to: file, offset: -1, tool: "Read") }
            catch { writeError = error }
        }, connection: { .connected })
        defer { worker.close() }
        var result: ClaudeSourceRead?
        XCTAssertTrue(worker.tryRead(observedSince: Date().addingTimeInterval(-60)) { result = $0 })
        let deadline = Date().addingTimeInterval(5)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(injected)
        XCTAssertNil(writeError)
        let read = try XCTUnwrap(result)
        guard case .snapshot(let snapshot) = read.outcome else { return XCTFail("The changed session must be retained") }
        XCTAssertTrue(read.changedSessionIDs.contains("claude:fixture"))
        XCTAssertTrue(snapshot.tasks.contains { $0.id == "claude:fixture" && $0.isUnconfirmed })
        XCTAssertFalse(snapshot.neutralEndedIDs.contains("claude:fixture"))
    }

    func testChangedSessionDoesNotUnconfirmUnchangedNeighbor() {
        let now = Date()
        let step = TaskStep(id: "step", title: "Synthetic step", status: .active)
        let first = MonitoredTask(id: "claude:first", provider: .claude, title: "First", activity: "Old",
                                  isActive: true, progress: 50, progressKind: .approximate, steps: [step], updatedAt: now)
        let neighbor = MonitoredTask(id: "claude:neighbor", provider: .claude, title: "Neighbor", activity: "Working",
                                     isActive: true, progress: 50, progressKind: .approximate, steps: [step], updatedAt: now)
        var old = ClaudeTaskSnapshot()
        old.tasks = [first, neighbor]
        var newer = ClaudeTaskSnapshot()
        newer.tasks = [neighbor]
        newer.neutralEndedIDs = [first.id]
        var middle = ClaudeSourceEvents()
        middle.affectedSessions = ["first"]
        let result = ClaudeSourceWorker.compareSnapshots(old, newer, middle: middle)
        XCTAssertFalse(result.affectsAll)
        XCTAssertEqual(result.changed, [first.id])
        XCTAssertTrue(result.snapshot.neutralEndedIDs.isEmpty)
        XCTAssertEqual(result.snapshot.tasks, [neighbor])
        XCTAssertTrue(result.snapshot.tasks[0].planConfirmed)

        var lifecycle = ClaudeSourceEvents()
        lifecycle.lifecycleSessions = ["first"]
        let withNewEvent = ClaudeSourceWorker.compareSnapshots(old, old, middle: lifecycle)
        XCTAssertTrue(withNewEvent.snapshot.tasks.first { $0.id == first.id }?.isUnconfirmed == true)
        XCTAssertTrue(withNewEvent.snapshot.tasks.first { $0.id == neighbor.id }?.planConfirmed == true)
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
