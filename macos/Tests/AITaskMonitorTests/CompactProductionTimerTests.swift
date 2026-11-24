import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class CompactProductionTimerTests: XCTestCase {
    private final class Gate {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var armed = false

        func arm() { lock.lock(); armed = true; lock.unlock() }
        func waitIfArmed() {
            lock.lock(); let shouldWait = armed; armed = false; lock.unlock()
            guard shouldWait else { return }
            entered.signal()
            _ = release.wait(timeout: .now() + 12)
        }
    }

    private final class Calls {
        private let lock = NSLock()
        private var count = 0
        func disconnected() -> ExternalProviderConnectionState {
            lock.lock(); count += 1; lock.unlock()
            return .disconnected
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func fixture(_ root: URL, ids: [String]) throws -> (home: URL, claude: URL) {
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions/2026/11/16", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date().addingTimeInterval(30))
        var index = Data()
        for (position, id) in ids.enumerated() {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Task \(position)"], options: [.sortedKeys]))
            index.append(10)
            let rows: [[String: Any]] = [
                ["timestamp": stamp, "type": "session_meta", "payload": ["id": id, "source": "exec", "thread_source": "user"]],
                ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "turn-\(id)"]]
            ]
            var events = Data()
            for row in rows {
                events.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                events.append(10)
            }
            let file = sessions.appendingPathComponent("rollout-2026-11-16T15-31-00-\(id).jsonl")
            try events.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(35)], ofItemAtPath: file.path)
        }
        try index.write(to: home.appendingPathComponent("session_index.jsonl"))
        let claude = root.appendingPathComponent("claude-events-v2.jsonl")
        try Data().write(to: claude)
        return (home, claude)
    }

    @MainActor
    private func exercise(blockClaude: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_MACOS_UI_EVENT_TEST"] == "1", env["AITM_SYNTHETIC_REQUIRED"] == "1",
              env["AITM_MACOS_TEST_SANDBOX"] == "1", env["GITHUB_ACTIONS"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS" else {
            throw CocoaError(.fileWriteNoPermission)
        }
        // The enclosing isolated runner removes this directory after the test
        // process exits, once queued diagnostic writes and readers are closed.
        let root = try codexSyntheticDirectory(prefix: "aitm-timer-window-")
        let ids = ["019127f4-35ae-7c73-9e72-a10123456781", "019127f4-35ae-7c73-9e72-a10123456782"]
        let files = try fixture(root, ids: ids), gate = Gate(), calls = Calls()
        defer { gate.release.signal() }
        let codex = CodexTaskReader(codexHome: files.home,
                                    afterDiscoveryForTests: blockClaude ? nil : { gate.waitIfArmed() })
        let claude = ClaudeTaskReader(eventFile: files.claude,
                                      afterJournalLockForTests: blockClaude ? { gate.waitIfArmed() } : nil)
        let disconnected: () throws -> ExternalProviderConnectionState = { .disconnected }
        let store = TaskStore(codexReader: codex, claudeReader: claude,
            journal: DiagnosticJournal(directory: root.appendingPathComponent("diagnostics", isDirectory: true)),
            enableExternalProviders: true, openCodeConnection: { calls.disconnected() },
            additionalExternalConnections: [.kimi: disconnected, .deepseek: disconnected, .hermes: disconnected],
            makeExternalRuntime: { throw CocoaError(.fileWriteNoPermission) },
            makeExternalV2Runtime: { throw CocoaError(.fileWriteNoPermission) },
            discoverDeepSeekContext: { nil }, enableExternalV2: true)

        func wait(_ condition: () -> Bool, timeout: TimeInterval = 8) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            return condition()
        }
        XCTAssertTrue(wait {
            Set(store.tasks.filter { ids.contains($0.id) }.map(\.id)) == Set(ids) &&
                !store.testCodexReadInFlight && !store.testClaudeReadInFlight
        }, "The normal store must first load both synthetic tasks")
        store.isCompact = true
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 182),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close(); window.contentView = nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let initialTicks = store.testPeriodicRefreshCount, initialCalls = calls.value
        gate.arm()
        var entered = false
        XCTAssertTrue(wait {
            if !entered { entered = gate.entered.wait(timeout: .now()) == .success }
            return entered && store.testPeriodicRefreshCount > initialTicks && calls.value > initialCalls
        }, "The production timer must refresh while the source reader is held")
        XCTAssertTrue(blockClaude ? store.testClaudeReadInFlight : store.testCodexReadInFlight)
        hosting.layoutSubtreeIfNeeded()
        let dots = store.compactDots
        XCTAssertEqual(dots.count, 2)
        guard dots.count == 2 else { return }
        let targetIndex = store.compactSelectedIndex == 0 ? 1 : 0
        let target = dots[targetIndex].task.id
        let dotY = hosting.isFlipped ? hosting.bounds.maxY - 19 : hosting.bounds.minY + 19
        let dotX = hosting.bounds.midX + (targetIndex == 0 ? -6.5 : 6.5)
        let point = hosting.convert(NSPoint(x: dotX, y: dotY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let started = ProcessInfo.processInfo.systemUptime
        window.sendEvent(try mouse(.leftMouseDown)); window.sendEvent(try mouse(.leftMouseUp))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertEqual(store.compactTasks[store.compactSelectedIndex].id, target)
        XCTAssertTrue(blockClaude ? store.testClaudeReadInFlight : store.testCodexReadInFlight,
                      "The click must be processed before the blocked reader resumes")
        gate.release.signal()
        XCTAssertTrue(wait { blockClaude ? !store.testClaudeReadInFlight : !store.testCodexReadInFlight })
        XCTAssertEqual(store.compactTasks[store.compactSelectedIndex].id, target)
    }

    @MainActor
    func testNormalTimerWindowSwitchesDuringBlockedCodexRead() throws { try exercise(blockClaude: false) }

    @MainActor
    func testNormalTimerWindowSwitchesDuringBlockedClaudeRead() throws { try exercise(blockClaude: true) }
}
#endif
