import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class CodexBackgroundReadTests: XCTestCase {
    private final class OneReadGate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var first = true
        private var calls = 0
        private var active = 0
        private var peak = 0

        var observedCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var peakConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }

        func waitOnce() {
            lock.lock()
            let shouldWait = first
            first = false
            calls += 1
            active += 1
            peak = max(peak, active)
            lock.unlock()
            defer { lock.lock(); active -= 1; lock.unlock() }
            guard shouldWait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 10)
        }
    }

    private final class SlowReadProbe {
        private let lock = NSLock()
        private var enabled = false
        private var calls = 0
        private var active = 0
        private var peak = 0

        func start() { lock.lock(); enabled = true; lock.unlock() }
        var observations: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (calls, peak) }
        func observe() {
            lock.lock()
            let slow = enabled
            if slow { calls += 1; active += 1; peak = max(peak, active) }
            lock.unlock()
            guard slow else { return }
            Thread.sleep(forTimeInterval: 2.1)
            lock.lock(); active -= 1; lock.unlock()
        }
    }

    private final class LockedStrings {
        private let lock = NSLock()
        private var strings: [String] = []
        func append(_ value: String) { lock.lock(); strings.append(value); lock.unlock() }
        var values: [String] { lock.lock(); defer { lock.unlock() }; return strings }
    }

    private func root() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              let configured = env["AITM_SYNTHETIC_TEST_ROOT"] else {
            throw XCTSkip("Synthetic Codex reads require the isolated hosted runner")
        }
        let base = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        let resolved = base.resolvingSymlinksInPath().standardizedFileURL
        let runnerTemp = URL(fileURLWithPath: "/Users/runner/work/_temp", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let container = resolved.deletingLastPathComponent()
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard base == resolved, resolved.lastPathComponent == "temp",
              container.lastPathComponent.hasPrefix("aitm-card-tests."),
              container.deletingLastPathComponent() == runnerTemp,
              values.isDirectory == true, values.isSymbolicLink == false else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = resolved.appendingPathComponent("aitm-codex-background-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func task(_ id: String, title: String) -> MonitoredTask {
        MonitoredTask(id: id, provider: .codex, title: title, activity: "Synthetic action", isActive: true,
                      progress: nil, progressKind: .none, steps: [], updatedAt: Date(), startKey: "turn-\(id)")
    }

    private func write(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private func writeTasks(_ rows: [(String, String)], root: URL) throws {
        let directory = root.appendingPathComponent("sessions/2026/11/16", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date().addingTimeInterval(30))
        var index = Data()
        for (id, title) in rows {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": title], options: [.sortedKeys]))
            index.append(0x0a)
            let events: [[String: Any]] = [
                ["timestamp": stamp, "type": "session_meta", "payload": ["id": id, "source": "exec", "thread_source": "user"]],
                ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-\(id)"]]
            ]
            var data = Data()
            for event in events {
                data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
                data.append(0x0a)
            }
            let rollout = directory.appendingPathComponent("rollout-2026-11-16T15-31-00-\(id).jsonl")
            try write(data, to: rollout)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(35)], ofItemAtPath: rollout.path)
        }
        try write(index, to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func appendEvent(_ kind: String, turn: String, id: String, root: URL) throws {
        let file = root.appendingPathComponent("sessions/2026/11/16/rollout-2026-11-16T15-31-00-\(id).jsonl")
        let descriptor = file.path.withCString { open($0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event: [String: Any] = ["timestamp": formatter.string(from: Date().addingTimeInterval(31)),
                                    "type": "event_msg", "payload": ["type": kind, "turn_id": turn]]
        var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        data.append(0x0a)
        try handle.write(contentsOf: data)
    }

    @MainActor
    private func waitForRead(_ store: TaskStore, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while store.testCodexReadInFlight && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(store.testCodexReadInFlight, "The isolated source read must finish")
    }

    @MainActor
    func testFrozenRealReaderDoesNotBlockSelectionOrRetainStore() throws {
        let root = try root()
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterDiscoveryForTests: { gate.waitOnce() })
        let first = task("019127f4-35ae-7c73-9e72-a10123456781", title: "First")
        let second = task("019127f4-35ae-7c73-9e72-a10123456782", title: "Second")
        var store: TaskStore? = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [first, second])
        store?.testSeedCodexTasks([first, second])
        let started = ProcessInfo.processInfo.systemUptime
        store?.refresh()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1, "The source read must not block refresh")
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        for _ in 0..<4 { store?.refresh() }
        XCTAssertEqual(gate.observedCalls, 1, "Refresh bursts must not start a second reader")
        store?.testPeriodicRefresh()
        XCTAssertFalse(store?.testCodexReadDelayed == true, "A timer tick before two elapsed seconds is not a delay")
        let dot = try XCTUnwrap(store?.compactDots.first { $0.task.id == second.id })
        store?.selectCompactTask(dot: dot)
        XCTAssertEqual(store?.tasks[store!.compactIndex].id, second.id, "Selection must work before the reader is released")
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        store?.testPeriodicRefresh()
        XCTAssertTrue(store?.testCodexReadDelayed == true)
        XCTAssertTrue(store?.tasks.allSatisfy { $0.isUnconfirmed && !$0.isActive } == true)
        XCTAssertEqual(gate.peakConcurrent, 1)

        weak var releasedStore = store
        store = nil
        XCTAssertNil(releasedStore, "A blocked source reader must not retain its closed store")
    }

    @MainActor
    func testInitialFrozenReaderDoesNotClaimThereAreNoActiveTasks() throws {
        let root = try root()
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterDiscoveryForTests: { gate.waitOnce() })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(store.compactEmptyMessage, tr("Нет отображаемых задач", "No tasks to display"))
        XCTAssertEqual(store.expandedEmptyMessage, tr("Нет отображаемых задач", "No tasks to display"))
    }

    @MainActor
    func testInvalidHomeWaitsForNextScheduledPoll() throws {
        let root = try root()
        let file = root.appendingPathComponent("not-a-directory")
        try write(Data("synthetic".utf8), to: file)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: file),
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        waitForRead(store)
        XCTAssertEqual(store.testCodexReadGeneration, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(store.testCodexReadGeneration, 1, "A persistent invalid home must not cause a tight retry")
        store.testPeriodicRefresh()
        waitForRead(store)
        XCTAssertEqual(store.testCodexReadGeneration, 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(store.testCodexReadGeneration, 2)
    }

    @MainActor
    func testManualSelectionWinsAgainstInFlightReadAndLaterNewTaskTakesFocus() throws {
        let root = try root()
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterDiscoveryForTests: { gate.waitOnce() })
        let first = task("019127f4-35ae-7c73-9e72-a10123456781", title: "First")
        let second = task("019127f4-35ae-7c73-9e72-a10123456782", title: "Second")
        let third = "019127f4-35ae-7c73-9e72-a10123456783"
        let fourth = "019127f4-35ae-7c73-9e72-a10123456784"
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [first, second])
        store.testSeedCodexTasks([first, second])
        try writeTasks([(third, "Third")], root: root)
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let dot = try XCTUnwrap(store.compactDots.first { $0.task.id == second.id })
        store.selectCompactTask(dot: dot)
        gate.release.signal()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == third })
        XCTAssertEqual(store.tasks[store.compactIndex].id, second.id, "A late read must respect a newer manual choice")

        try writeTasks([(third, "Third"), (fourth, "Fourth")], root: root)
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == fourth })
        XCTAssertEqual(store.tasks[store.compactIndex].id, fourth, "A subsequently started task can still take focus")
    }

    @MainActor
    func testManualSelectionSurvivesNewTurnAndNewNeighborDuringRead() throws {
        let root = try root()
        let first = "019127f4-35ae-7c73-9e72-a10123456781"
        let selected = "019127f4-35ae-7c73-9e72-a10123456782"
        let neighbor = "019127f4-35ae-7c73-9e72-a10123456783"
        try writeTasks([(first, "First"), (selected, "Selected")], root: root)
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { snapshot in
            if snapshot.tasks.contains(where: { $0.id == neighbor }) { gate.waitOnce() }
        })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        waitForRead(store)
        let old = try XCTUnwrap(store.tasks.first { $0.id == selected })
        let oldFile = try XCTUnwrap(old.lastActivityFileIdentity)
        try writeTasks([(first, "First"), (selected, "Selected"), (neighbor, "New neighbor")], root: root)
        try appendEvent("task_started", turn: "selected-next", id: selected, root: root)
        try appendEvent("task_started", turn: "neighbor-next", id: neighbor, root: root)
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let dot = try XCTUnwrap(store.compactDots.first { $0.task.id == selected })
        store.selectCompactTask(dot: dot)
        XCTAssertEqual(store.tasks[store.compactIndex].id, selected)
        gate.release.signal()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == neighbor && $0.isActive })
        let actual = store.tasks[store.compactIndex]
        XCTAssertEqual(actual.id, selected, "A newer neighboring task must not override the in-flight click")
        XCTAssertEqual(actual.lastActivityFileIdentity, oldFile)
        XCTAssertEqual(actual.startKey, "turn:selected-next")
    }

    @MainActor
    func testStableSlowReadIsRevalidatedWithoutParallelReader() throws {
        let root = try root()
        let id = "019127f4-35ae-7c73-9e72-a10123456781"
        try writeTasks([(id, "Synthetic")], root: root)
        let probe = SlowReadProbe()
        let reader = CodexTaskReader(codexHome: root, afterDiscoveryForTests: { probe.observe() })
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        _ = try reader.readSnapshot()
        reader.waitForAmbiguousObservationForTests()
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        probe.start()
        store.refresh()
        waitForRead(store, timeout: 8)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isActive && !$0.isUnconfirmed })
        XCTAssertEqual(probe.observations.0, 2, "A slow successful read must be revalidated")
        XCTAssertEqual(probe.observations.1, 1, "Revalidation must use the same serial reader")
    }

    @MainActor
    func testLateEndingCannotCloseNewTurn() throws {
        let root = try root()
        let id = "019127f4-35ae-7c73-9e72-a10123456781"
        try writeTasks([(id, "Synthetic")], root: root)
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { snapshot in
            if snapshot.terminalIDs.contains(id) { gate.waitOnce() }
        })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isActive })
        try appendEvent("task_complete", turn: "turn-\(id)", id: id, root: root)
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        RunLoop.current.run(until: Date().addingTimeInterval(2.1))
        try appendEvent("task_started", turn: "new-turn", id: id, root: root)
        gate.release.signal()
        waitForRead(store, timeout: 7)
        XCTAssertTrue(store.testPendingCodexTerminalIDs.contains(id))
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isUnconfirmed && !$0.isActive })
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.testPendingCodexTerminalIDs.contains(id))
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isUnconfirmed && $0.startKey == "turn:new-turn" })
    }

    @MainActor
    func testFastEndingIsRecheckedBeforePublishingNewTurn() throws {
        let root = try root()
        let id = "019127f4-35ae-7c73-9e72-a10123456781"
        try writeTasks([(id, "Synthetic")], root: root)
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { snapshot in
            if snapshot.terminalIDs.contains(id) { gate.waitOnce() }
        })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isActive })
        try appendEvent("task_complete", turn: "turn-\(id)", id: id, root: root)
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        try appendEvent("task_started", turn: "new-turn", id: id, root: root)
        gate.release.signal()
        waitForRead(store)
        XCTAssertTrue(store.testPendingCodexTerminalIDs.contains(id))
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isUnconfirmed && !$0.isActive })
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isUnconfirmed && $0.startKey == "turn:new-turn" })
    }

    @MainActor
    func testRewrittenSameInodeDoesNotConfirmAnOlderTurn() throws {
        let root = try root()
        let id = "019127f4-35ae-7c73-9e72-a10123456781"
        try writeTasks([(id, "Synthetic")], root: root)
        let file = root.appendingPathComponent("sessions/2026/11/16/rollout-2026-11-16T15-31-00-\(id).jsonl")
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: root, afterSnapshotForTests: { snapshot in
            if snapshot.terminalIDs.contains(id) { gate.waitOnce() }
        })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isActive })
        try appendEvent("task_complete", turn: "turn-\(id)", id: id, root: root)
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(-30))
        let rows: [[String: Any]] = [
            ["timestamp": timestamp, "type": "session_meta", "payload": ["id": id, "source": "exec", "thread_source": "user"]],
            ["timestamp": timestamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "older-turn"]]
        ]
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0a)
        }
        try write(data, to: file)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        gate.release.signal()
        waitForRead(store)
        XCTAssertTrue(store.testPendingCodexTerminalIDs.contains(id))
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == id && $0.isUnconfirmed && !$0.isActive })
        XCTAssertFalse(store.tasks.contains { $0.id == id && $0.isActive })
    }

    @MainActor
    func testLanguageChangeDoesNotPublishMixedSourceLabels() throws {
        let root = try root()
        let id = "019127f4-35ae-7c73-9e72-a10123456781"
        try writeTasks([(id, "")], root: root)
        let original = AppLanguage.previewOverride
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = original }
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let observed = LockedStrings()
        let reader = CodexTaskReader(codexHome: root, afterDiscoveryForTests: {
            observed.append(tr("Русский", "English"))
            gate.waitOnce()
            observed.append(tr("Русский", "English"))
        })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [])
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        AppLanguage.previewOverride = .ru
        gate.release.signal()
        waitForRead(store, timeout: 7)
        XCTAssertEqual(Array(observed.values.prefix(2)), ["English", "English"])
        let current = try XCTUnwrap(store.tasks.first { $0.id == id })
        XCTAssertEqual(current.title, "Задача Codex")
        XCTAssertEqual(current.activity, "Выполняется")
        XCTAssertEqual(AppLanguage.current, .ru, "Worker language must not leak to the main thread")
    }

    @MainActor
    func testReplacedHomeDoesNotPublishOldSnapshot() throws {
        let root = try root()
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let old = task("019127f4-35ae-7c73-9e72-a10123456781", title: "Old")
        let newID = "019127f4-35ae-7c73-9e72-a10123456782"
        try writeTasks([(old.id, old.title)], root: home)
        let gate = OneReadGate()
        defer { gate.release.signal() }
        let reader = CodexTaskReader(codexHome: home, afterDiscoveryForTests: { gate.waitOnce() })
        let store = TaskStore(codexReader: reader,
            claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("no-claude")), previewTasks: [old])
        store.testSeedCodexTasks([old])
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        try FileManager.default.moveItem(at: home, to: root.appendingPathComponent("old-home"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        try writeTasks([(newID, "New")], root: home)
        gate.release.signal()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == old.id && $0.isUnconfirmed })
        XCTAssertFalse(store.tasks.contains { $0.id == newID && $0.isActive })
        store.refresh()
        waitForRead(store)
        XCTAssertTrue(store.tasks.contains { $0.id == newID && $0.isActive })
    }
}
#endif
