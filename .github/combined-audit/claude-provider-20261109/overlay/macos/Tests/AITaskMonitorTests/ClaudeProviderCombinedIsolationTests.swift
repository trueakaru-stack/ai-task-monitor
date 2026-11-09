import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Uses only a temporary Claude journal and a synthetic local provider channel.
final class ClaudeProviderCombinedIsolationTests: XCTestCase {
    private func record(_ input: [String: Any], time: Date) -> [String: Any] {
        var result = ClaudeHook.makeRecord(from: input)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = formatter.string(from: time)
        return result
    }

    private func encoded(_ records: [[String: Any]]) throws -> Data {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(10)
        }
        return data
    }

    private func sendOpenCode(_ directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(#"{"version":1,"provider":"opencode","session":"synthetic","kind":"started"}"#.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255),
                           UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    @MainActor
    func testClaudeLossAndProviderReconnectRemainIsolatedWithV2Enabled() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("aitm-combined-providers-" + UUID().uuidString, isDirectory: true)
        let channelDirectory = "/private/tmp/aitm-combined-provider-" + UUID().uuidString
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("claude-events-v2.jsonl")
        let time = Date().addingTimeInterval(1)
        let first = record(["session_id": "case", "hook_event_name": "UserPromptSubmit"], time: time)
        let old = record(["session_id": "case", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                          "tool_input": ["subject": "Old title"],
                          "tool_response": ["task": ["id": "one", "subject": "Old title"]]], time: time.addingTimeInterval(0.1))
        try encoded([first, old]).write(to: file)
        var connection = OpenCodeIntegration.State.connected
        var activeRuntime: ExternalProviderRuntime?
        var store: TaskStore? = TaskStore(
            codexReader: CodexTaskReader(codexHome: root.appendingPathComponent("missing-codex")),
            claudeReader: ClaudeTaskReader(eventFile: file),
            journal: DiagnosticJournal(directory: root.appendingPathComponent("diagnostics")),
            enableExternalProviders: true,
            openCodeConnection: { connection },
            makeExternalRuntime: {
                let runtime = ExternalProviderRuntime(channel: try ExternalProviderChannel(directory: channelDirectory))
                activeRuntime = runtime
                return runtime
            },
            inspectKimiConnection: { KimiConnection(state: "disconnected", scope: nil) },
            discoverHermesContext: { nil },
            enableExternalV2: true)
        defer {
            store = nil
            activeRuntime?.stop()
            try? manager.removeItem(at: URL(fileURLWithPath: channelDirectory))
            try? manager.removeItem(at: root)
        }
        let monitor = try XCTUnwrap(store)
        XCTAssertNotNil(activeRuntime)
        XCTAssertFalse(monitor.externalV2Failed)
        XCTAssertEqual(monitor.tasks.first(where: { $0.id == "claude:case" })?.steps.map(\.title), ["Old title"])
        try sendOpenCode(channelDirectory)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline && !monitor.tasks.contains(where: { $0.id == "opencode:synthetic" }) {
            monitor.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let provider = try XCTUnwrap(monitor.tasks.first { $0.id == "opencode:synthetic" })
        XCTAssertTrue(provider.isUnconfirmed)
        XCTAssertFalse(provider.isActive)
        let loss = record(["session_id": "", "hook_event_name": "AITMSourceUncertain"], time: time.addingTimeInterval(0.2))
        let next = record(["session_id": "case", "hook_event_name": "UserPromptSubmit"], time: time.addingTimeInterval(0.3))
        let newer = record(["session_id": "case", "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                            "tool_input": ["subject": "New title"],
                            "tool_response": ["task": ["id": "one", "subject": "New title"]]], time: time.addingTimeInterval(0.4))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded([loss, next, newer]))
        try handle.close()
        monitor.refresh()
        let claude = try XCTUnwrap(monitor.tasks.first { $0.id == "claude:case" })
        XCTAssertEqual(claude.steps.map(\.title), ["Old title", "New title"])
        XCTAssertTrue(claude.isUnconfirmed)
        XCTAssertFalse(claude.planConfirmed)
        XCTAssertNil(claude.progress)
        XCTAssertTrue(try XCTUnwrap(monitor.tasks.first { $0.id == "opencode:synthetic" }).isUnconfirmed)
        connection = .disconnected
        monitor.refresh()
        XCTAssertFalse(monitor.tasks.contains { $0.provider == .opencode })
        XCTAssertEqual(monitor.tasks.first(where: { $0.id == "claude:case" })?.steps.map(\.title), ["Old title", "New title"])
    }
}
