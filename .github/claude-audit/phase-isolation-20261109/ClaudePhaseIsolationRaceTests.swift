import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic fixtures exercise the real file snapshot and AF_UNIX receiver.
final class ClaudePhaseIsolationRaceTests: XCTestCase {
    private func record(_ input: [String: Any], time: Date) -> [String: Any] {
        var result = ClaudeHook.makeRecord(from: input)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        result["timestamp"] = f.string(from: time)
        return result
    }

    private func rows(_ id: String, time: Date) -> [[String: Any]] {
        [record(["session_id": id, "hook_event_name": "UserPromptSubmit"], time: time),
         record(["session_id": id, "hook_event_name": "PostToolUse", "tool_name": "TaskCreate",
                 "tool_input": ["subject": "Synthetic \(id)"],
                 "tool_response": ["task": ["id": "step", "subject": "Synthetic \(id)"]]], time: time.addingTimeInterval(0.1)),
         record(["session_id": id, "hook_event_name": "PostToolUse", "tool_name": "TaskUpdate",
                 "tool_input": ["taskId": "step", "status": "completed"],
                 "tool_response": ["success": true, "taskId": "step", "updatedFields": ["status"],
                                   "statusChange": ["from": "pending", "to": "completed"]]], time: time.addingTimeInterval(0.2))]
    }

    private func channel(_ store: TaskStore) -> ClaudeLoopChannel? {
        guard let item = Mirror(reflecting: store).children.first(where: { $0.label == "claudeLoopChannel" }) else { return nil }
        return Mirror(reflecting: item.value).children.first?.value as? ClaudeLoopChannel
    }

    @MainActor
    private func runInterleaving(gap: Bool) throws -> (first: MonitoredTask, neighbor: MonitoredTask) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-phase-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("claude-events-v2.jsonl"), now = Date().addingTimeInterval(2)
        var data = Data()
        for row in rows("first", time: now) + rows("neighbor", time: now) {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); data.append(10)
        }
        try data.write(to: file)
        var store: TaskStore?
        var trigger = false
        var injected = false
        var arrived = false
        let reader = ClaudeTaskReader(eventFile: file, readLockTiming: { _ in
            guard trigger, !injected, let current = store, let receiver = self.channel(current) else { return }
            injected = true
            if gap {
                guard let folder = try? ClaudeLoopSocket.directory(profile: dir, create: false),
                      let fd = ClaudeLoopSocket.connect(path: folder + "/events.sock") else { return }
                defer { Darwin.close(fd) }
                guard ClaudeLoopSocket.read(fd, count: 32) != nil else { return }
                _ = ClaudeLoopSocket.write(fd, data: Data([0, 0, 0, 0]))
            } else {
                let input: [String: Any] = ["session_id": "first", "hook_event_name": "PreToolUse",
                                            "tool_name": "TaskUpdate", "tool_use_id": "synthetic-call",
                                            "tool_input": ["taskId": "step", "status": "completed"]]
                guard ClaudeHook.process(input, directory: dir, retentionPolicy: { nil }) == 0 else { return }
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if gap ? receiver.hasPendingGapForTesting() : receiver.hasPendingPhaseForTesting("first") {
                    arrived = true; break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
        })
        store = TaskStore(codexReader: CodexTaskReader(codexHome: dir.appendingPathComponent("missing-codex")),
                          claudeReader: reader, journal: DiagnosticJournal(directory: dir.appendingPathComponent("diagnostics")),
                          claudeLoopProfile: dir)
        let socketDirectory = try ClaudeLoopSocket.directory(profile: dir, create: false)
        defer {
            store = nil
            if let names = try? FileManager.default.contentsOfDirectory(atPath: socketDirectory),
               socketDirectory.hasPrefix("/private/tmp/aitm-loop-"), Set(names).isSubset(of: ["owner.lock"]) {
                _ = (socketDirectory + "/owner.lock").withCString { unlink($0) }
                _ = socketDirectory.withCString { rmdir($0) }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertTrue(try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:first" })).planConfirmed)
        XCTAssertTrue(try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:neighbor" })).planConfirmed)
        trigger = true
        store?.refresh()
        XCTAssertTrue(injected, "The event must be injected after the file snapshot")
        XCTAssertTrue(arrived, "The real receiver must queue the synthetic frame before the second drain")
        let first = try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:first" }))
        let neighbor = try XCTUnwrap(store?.tasks.first(where: { $0.id == "claude:neighbor" }))
        return (first, neighbor)
    }

    @MainActor
    func testAttributedPhaseAfterSnapshotPreservesNeighbor() throws {
        let tasks = try runInterleaving(gap: false)
        XCTAssertFalse(tasks.first.planConfirmed, "The session with the new phase must be unconfirmed")
        XCTAssertNil(tasks.first.progress)
        XCTAssertTrue(tasks.neighbor.planConfirmed, "An attributed phase in first must not clear neighbor")
        XCTAssertEqual(tasks.neighbor.progress, 100)
    }

    @MainActor
    func testUnattributedChannelGapClearsAllClaudePlans() throws {
        let tasks = try runInterleaving(gap: true)
        XCTAssertFalse(tasks.first.planConfirmed)
        XCTAssertFalse(tasks.neighbor.planConfirmed)
        XCTAssertNil(tasks.first.progress)
        XCTAssertNil(tasks.neighbor.progress)
    }

    func testDuplicateFrameAlsoAffectsPreviousOwner() throws {
        var evidence = ClaudePhaseEvidence()
        evidence.start(key: Data(repeating: 7, count: 32))
        let fp = String(repeating: "a", count: 64)
        XCTAssertEqual(evidence.observe(session: "neighbor", toolID: "one", fingerprint: fp), Set(["neighbor"]))
        XCTAssertEqual(evidence.observe(session: "first", toolID: "two", fingerprint: fp), Set(["first", "neighbor"]))
        XCTAssertNil(evidence.toolID(fingerprint: fp, session: "neighbor"))
        XCTAssertFalse(evidence.poisoned)
    }

    func testEvictionAlsoAffectsEvictedOwnerAndInvalidFrameEscalates() throws {
        var evidence = ClaudePhaseEvidence()
        evidence.start(key: Data(repeating: 8, count: 32))
        for index in 0..<8192 {
            let session = index == 0 ? "neighbor" : "filler"
            let fp = String(format: "%064d", index)
            XCTAssertNotNil(evidence.observe(session: session, toolID: "call", fingerprint: fp))
        }
        let impact = evidence.observe(session: "first", toolID: "call", fingerprint: String(format: "%064d", 8192))
        XCTAssertEqual(impact, Set(["first", "neighbor"]))
        XCTAssertTrue(evidence.isSessionUncertain("neighbor"))
        XCTAssertNil(evidence.observe(session: "first", toolID: "bad!", fingerprint: String(repeating: "a", count: 64)))
        XCTAssertTrue(evidence.poisoned)
    }
}
