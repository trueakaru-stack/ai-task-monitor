import Foundation
import XCTest
@testable import AITaskMonitor

// Independent synthetic tests for macOS CI. Not compiled or run on Windows.
final class CodexBoundaryIndependentTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-codex-id-independent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func index(_ ids: [String], root: URL) throws {
        var lines = Data()
        for id in ids {
            lines.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic title"]))
            lines.append(0x0a)
        }
        try lines.write(to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func rollout(_ path: URL, type: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let event: [String: Any] = ["timestamp": formatter.string(from: Date()), "type": "event_msg",
                                    "payload": ["type": type, "turn_id": "synthetic"]]
        var data = try JSONSerialization.data(withJSONObject: event)
        data.append(0x0a)
        try data.write(to: path)
    }

    func testOneFileCannotSilentlyServeTwoIndexedIDs() throws {
        try withRoot { root in
            try index(["short", "long-short"], root: root)
            try rollout(root.appendingPathComponent("sessions/rollout-long-short.jsonl"), type: "task_started")
            do {
                let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(1))
                XCTAssertLessThanOrEqual(snapshot.tasks.count, 1, "One file must not silently become two distinct tasks")
                XCTAssertTrue(snapshot.terminalIDs.isEmpty)
            } catch { /* An explicit source error is also safe. */ }
        }
    }

    func testTwoFilesForOneUUIDMustNotSilentlyChooseOneState() throws {
        try withRoot { root in
            let id = "019127f4-35ae-7c73-9e72-a10123456789"
            try index([id], root: root)
            try rollout(root.appendingPathComponent("sessions/rollout-a-\(id).jsonl"), type: "task_started")
            try rollout(root.appendingPathComponent("sessions/rollout-b-\(id).jsonl"), type: "task_complete")
            do {
                let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(1))
                XCTAssertFalse(snapshot.terminalIDs.contains(id), "An ambiguous file must not terminate the card")
                XCTAssertFalse(snapshot.tasks.contains(where: { $0.id == id && $0.isActive && !$0.isUnconfirmed }),
                               "An ambiguous file must not assert activity")
            } catch { /* An explicit source error is also safe. */ }
        }
    }

    // Current official Codex source describes revert filenames containing
    // <thread-id>_<new-rollout-id>; this fixture models that documented shape.
    func testRevertedThreadDoesNotUsePreviousTerminalFile() throws {
        try withRoot { root in
            let thread = "019127f4-35ae-7c73-9e72-a10123456789"
            let newRollout = "019127f4-35ae-7c73-9e72-a10987654321"
            try index([thread], root: root)
            try rollout(root.appendingPathComponent("sessions/rollout-old-\(thread).jsonl"), type: "task_complete")
            try rollout(root.appendingPathComponent("sessions/rollout-new-\(thread)_\(newRollout).jsonl"), type: "task_started")
            do {
                let snapshot = try CodexTaskReader(codexHome: root).readSnapshot(now: Date().addingTimeInterval(1))
                XCTAssertFalse(snapshot.terminalIDs.contains(thread), "The older file must not terminate a running reverted thread")
                XCTAssertTrue(snapshot.tasks.contains(where: { $0.id == thread }), "A new rollout must not disappear")
            } catch { /* Explicit uncertainty is preferable to a false terminal state. */ }
        }
    }

    func testSameMetadataReplacementDoesNotHideForbiddenID() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("session_index.jsonl")
            let before = Data("{\"id\":\"safe-session\",\"thread_name\":\"same\"}\n".utf8)
            let after = Data("{\"id\":\"claude:probe\",\"thread_name\":\"same\"}\n".utf8)
            XCTAssertEqual(before.count, after.count)
            try before.write(to: url)
            let cache = CodexSessionIndexCache()
            XCTAssertNotNil(try cache.read(from: url)["safe-session"])
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: after)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let restored = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (restored[.modificationDate] as? Date) == modified,
                  (restored[.size] as? NSNumber) == (attrs[.size] as? NSNumber),
                  (restored[.systemFileNumber] as? NSNumber) == (attrs[.systemFileNumber] as? NSNumber),
                  (restored[.systemNumber] as? NSNumber) == (attrs[.systemNumber] as? NSNumber) else {
                throw XCTSkip("The synthetic filesystem could not restore the exact cache signature")
            }
            XCTAssertThrowsError(try cache.read(from: url), "A retained signature must not hide an unsupported ID")
        }
    }

    func testDuplicateIDFieldsDoNotHideForbiddenNamespace() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("session_index.jsonl")
            let line = "{\"id\":\"claude:probe\",\"id\":\"safe-session\",\"thread_name\":\"synthetic\"}\n"
            try Data(line.utf8).write(to: url)
            XCTAssertThrowsError(try CodexSessionIndexCache().read(from: url), "Ambiguous ID members must not be silently accepted")
        }
    }

    func testSharedRawTextStaysSeparateForFocusAndDiagnosticKeys() throws {
        try withRoot { root in
            let raw = "synthetic-id"
            func task(_ id: String, _ provider: TaskProvider) -> MonitoredTask {
                MonitoredTask(id: id, provider: provider, title: "Synthetic", activity: "Synthetic",
                              isActive: true, progress: nil, progressKind: .none, steps: [], updatedAt: Date())
            }
            let codex = task(raw, .codex), claude = task("claude:" + raw, .claude)
            let preserved = TaskSnapshotMerger.merge(previous: [codex, claude], current: [], terminalIDs: [raw])
            XCTAssertEqual(preserved.count, 1)
            XCTAssertEqual(preserved.first?.id, "claude:" + raw)
            var focus = TaskFocusTracker()
            let focused = focus.reconcile(current: [codex, claude], previous: [codex, claude], selectedID: claude.id)
            XCTAssertEqual(focused.selectedID, claude.id)
            let journal = DiagnosticJournal(directory: root.appendingPathComponent("diagnostic"))
            XCTAssertNotEqual(try journal.taskKey(source: .codex, taskID: raw), try journal.taskKey(source: .claude, taskID: raw))
        }
    }
}
