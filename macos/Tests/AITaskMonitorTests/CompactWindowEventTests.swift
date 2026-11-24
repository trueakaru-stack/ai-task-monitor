import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AITaskMonitor

#if DEBUG
final class CompactWindowEventTests: XCTestCase {
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

    private func task(_ id: String, provider: TaskProvider) -> MonitoredTask {
        MonitoredTask(id: id, provider: provider, title: "Synthetic task", activity: "Synthetic activity",
                      isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date(),
                      startKey: "synthetic-turn")
    }

    @MainActor
    private func exercise(blockClaude: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITM_MACOS_UI_EVENT_TEST"] == "1", environment["AITM_SYNTHETIC_REQUIRED"] == "1",
              environment["AITM_MACOS_TEST_SANDBOX"] == "1", environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS" else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let root = try codexSyntheticDirectory(prefix: "aitm-dot-window-")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()
        defer { gate.release.signal() }
        let home = root.appendingPathComponent("codex", isDirectory: true)
        let journal = root.appendingPathComponent("claude-events-v2.jsonl")
        if blockClaude {
            let row: [String: Any] = ["session_id": "first", "hook_event_name": "UserPromptSubmit"]
            var record = ClaudeHook.makeRecord(from: row)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            record["timestamp"] = formatter.string(from: Date().addingTimeInterval(1))
            var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); bytes.append(10)
            try bytes.write(to: journal)
        } else {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try Data().write(to: home.appendingPathComponent("session_index.jsonl"))
        }
        let codex = CodexTaskReader(codexHome: home, afterDiscoveryForTests: blockClaude ? nil : { gate.waitOnce() })
        let claude = ClaudeTaskReader(eventFile: journal, afterJournalLockForTests: blockClaude ? { gate.waitOnce() } : nil)
        let first = task(blockClaude ? "claude:first" : "10000000-0000-0000-0000-000000000001",
                         provider: blockClaude ? .claude : .codex)
        let second = task(blockClaude ? "claude:second" : "10000000-0000-0000-0000-000000000002",
                          provider: blockClaude ? .claude : .codex)
        let store = TaskStore(codexReader: codex, claudeReader: claude, previewTasks: [first, second])
        if blockClaude { store.testSeedClaudeTasks([first, second]) }
        else { store.testSeedCodexTasks([first, second]) }
        defer {
            gate.release.signal()
            let deadline = Date().addingTimeInterval(5)
            while (blockClaude ? store.testClaudeReadInFlight : store.testCodexReadInFlight) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        store.isCompact = true
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hosting = NSHostingView(rootView: RootView().environmentObject(store).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 182),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        store.refresh()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        let targets = store.compactDots
        XCTAssertEqual(targets.count, 2)
        guard targets.count == 2 else { return }
        let targetIndex = store.compactSelectedIndex == 0 ? 1 : 0
        let target = targets[targetIndex].task.id
        // RootView places two 6-point dots 7 points apart, centered above its
        // 16-point bottom inset. This sends AppKit events to the real window.
        let dotY = hosting.isFlipped ? hosting.bounds.maxY - 19 : hosting.bounds.minY + 19
        let dotX = hosting.bounds.midX + (targetIndex == 0 ? -6.5 : 6.5)
        let point = hosting.convert(NSPoint(x: dotX, y: dotY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let started = ProcessInfo.processInfo.systemUptime
        window.sendEvent(try mouse(.leftMouseDown))
        window.sendEvent(try mouse(.leftMouseUp))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(blockClaude ? store.testClaudeReadInFlight : store.testCodexReadInFlight)
        XCTAssertEqual(store.compactTasks[store.compactSelectedIndex].id, target,
                       "The window click must switch before the blocked reader is released")
        gate.release.signal()
        if blockClaude { waitForClaudeRead(store, timeout: 8) }
        else { waitForCodexRead(store, timeout: 8) }
    }

    @MainActor
    func testWindowDotWhileCodexReaderIsBlocked() throws { try exercise(blockClaude: false) }

    @MainActor
    func testWindowDotWhileClaudeReaderIsBlocked() throws { try exercise(blockClaude: true) }
}
#endif
