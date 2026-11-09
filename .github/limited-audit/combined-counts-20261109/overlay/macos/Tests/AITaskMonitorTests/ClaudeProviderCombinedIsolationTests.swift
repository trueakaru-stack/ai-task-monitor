import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// The Claude journal and both provider channels are unique synthetic fixtures.
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

    private func sendOpenCodeV1(_ directory: String) throws {
        let descriptor = try XCTUnwrap(ClaudeLoopSocket.connect(path: directory + "/events.sock"))
        defer { Darwin.close(descriptor) }
        let body = Data(#"{"version":1,"provider":"opencode","session":"synthetic","kind":"started"}"#.utf8)
        let count = body.count
        let header = Data([UInt8(count & 255), UInt8((count >> 8) & 255),
                           UInt8((count >> 16) & 255), UInt8((count >> 24) & 255)])
        XCTAssertTrue(ClaudeLoopSocket.write(descriptor, data: header + body))
        XCTAssertEqual(ClaudeLoopSocket.read(descriptor, count: 1), Data([0x06]))
    }

    private func generation(_ directory: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/generations-v2.json"))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let generations = try XCTUnwrap(value["generations"] as? [String: String])
        return try XCTUnwrap(generations["opencode:global"])
    }

    @MainActor
    private func waitFor(_ message: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        XCTFail(message)
        throw CocoaError(.fileReadUnknown)
    }

    @MainActor
    func testClaudeLossAndProviderReconnectRemainIsolatedWithV2Enabled() throws {
        let previousHandler = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previousHandler) }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("aitm-combined-providers-" + UUID().uuidString, isDirectory: true)
        // This shape is accepted by the unmodified sender, but never targets the UID directory.
        let channelDirectory = "/private/tmp/aitm-provider-" + UUID().uuidString
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
        var activeV2: ExternalProviderV2Runtime?
        var v2FactoryCalls = 0
        var children: [(Process, Pipe)] = []
        let environment = ProcessInfo.processInfo.environment
        let node = try XCTUnwrap(environment["AITM_TEST_NODE"])
        let script = try XCTUnwrap(environment["AITM_V2_SENDER_FIXTURE"])
        XCTAssertTrue(node.hasPrefix("/")); XCTAssertTrue(script.hasPrefix("/"))
        func startSender(_ generation: String) throws -> (Process, Pipe) {
            let child = Process(), input = Pipe()
            child.executableURL = URL(fileURLWithPath: node)
            child.arguments = [script, channelDirectory, generation]
            child.environment = [:]
            child.standardInput = input
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            children.append((child, input))
            return (child, input)
        }
        func stopSender(_ pair: (Process, Pipe)) {
            try? pair.1.fileHandleForWriting.close()
            if pair.0.isRunning { pair.0.terminate(); pair.0.waitUntilExit() }
        }
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
            makeExternalV2Runtime: {
                let runtime = try ExternalProviderV2Runtime(directory: channelDirectory)
                v2FactoryCalls += 1
                activeV2 = runtime
                return runtime
            },
            discoverDeepSeekContext: { nil },
            inspectKimiConnection: { KimiConnection(state: "disconnected", scope: nil) },
            discoverHermesContext: { nil },
            enableExternalV2: true)
        defer {
            for child in children { stopSender(child) }
            store = nil
            activeRuntime?.stop()
            activeV2?.stop()
            try? manager.removeItem(at: URL(fileURLWithPath: channelDirectory))
            try? manager.removeItem(at: root)
        }
        let monitor = try XCTUnwrap(store)
        let firstRuntime = try XCTUnwrap(activeV2)
        XCTAssertNotNil(activeRuntime)
        XCTAssertFalse(monitor.externalV2Failed)
        XCTAssertEqual(v2FactoryCalls, 1)
        XCTAssertEqual(monitor.tasks.first(where: { $0.id == "claude:case" })?.steps.map(\.title), ["Old title"])

        try sendOpenCodeV1(channelDirectory)
        let firstGeneration = try generation(channelDirectory)
        let firstSender = try startSender(firstGeneration)
        try waitFor("Both synthetic v1 and v2 observations should be visible") {
            monitor.refresh()
            return monitor.openCodeRestartAvailable &&
                monitor.tasks.contains { $0.id == "opencode:synthetic" && $0.isUnconfirmed } &&
                monitor.tasks.contains { $0.id == "opencode:before" && $0.isUnconfirmed }
        }
        monitor.acknowledgeOpenCodeRestart()
        try firstSender.1.fileHandleForWriting.write(contentsOf: Data("fresh\n".utf8))
        try waitFor("OpenCode remains unconfirmed after a real v2 post-restart event") {
            monitor.refresh()
            return monitor.tasks.contains { $0.id == "opencode:after" && $0.isUnconfirmed && !$0.isActive }
        }

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
        XCTAssertTrue(try XCTUnwrap(monitor.tasks.first { $0.id == "opencode:after" }).isUnconfirmed)

        stopSender(firstSender)
        connection = .disconnected
        monitor.refresh()
        XCTAssertTrue(firstRuntime.isStopped)
        XCTAssertFalse(monitor.tasks.contains { $0.provider == .opencode })
        XCTAssertEqual(monitor.tasks.first(where: { $0.id == "claude:case" })?.steps.map(\.title), ["Old title", "New title"])
        connection = .connected
        monitor.refresh()
        XCTAssertEqual(v2FactoryCalls, 2)
        XCTAssertFalse(monitor.externalV2Failed)
        XCTAssertFalse(monitor.openCodeRestartAvailable)
        let nextGeneration = try generation(channelDirectory)
        XCTAssertNotEqual(firstGeneration, nextGeneration)
        _ = try startSender(nextGeneration)
        try waitFor("A new synthetic process must exchange v2 frames after reconnect") {
            monitor.refresh()
            return monitor.openCodeRestartAvailable &&
                monitor.tasks.contains { $0.id == "opencode:before" && $0.isUnconfirmed && !$0.isActive }
        }
        XCTAssertEqual(monitor.tasks.first(where: { $0.id == "claude:case" })?.steps.map(\.title), ["Old title", "New title"])
    }
}
