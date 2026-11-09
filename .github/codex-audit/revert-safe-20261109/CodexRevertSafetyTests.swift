import Foundation
import XCTest
@testable import AITaskMonitor

// Synthetic files only. These do not start Codex or access its real profile.
final class CodexRevertSafetyTests: XCTestCase {
    private let thread = "019127f4-35ae-7c73-9e72-a10123456789"
    private let other = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aitm-revert-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func writeIndex(_ ids: [String], root: URL) throws {
        var lines = Data()
        for id in ids {
            lines.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic title"]))
            lines.append(0x0a)
        }
        try lines.write(to: root.appendingPathComponent("session_index.jsonl"))
    }

    private func name(_ id: String, revision: String? = nil, time: String = "2026-11-09T10-00-00") -> String {
        "rollout-\(time)-\(id)\(revision.map { "_" + $0 } ?? "").jsonl"
    }

    private func writeEvent(_ type: String, at url: URL) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date().addingTimeInterval(2))
        let value: [String: Any] = ["timestamp": stamp, "type": "event_msg",
                                    "payload": ["type": type, "turn_id": "synthetic"]]
        var bytes = try JSONSerialization.data(withJSONObject: value)
        bytes.append(0x0a)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
    }

    private func appendPlan(at url: URL) throws {
        let arguments = #"{"plan":[{"step":"Synthetic step","status":"in_progress"}]}"#
        let record: [String: Any] = ["type": "response_item", "payload":
            ["type": "function_call", "name": "update_plan", "arguments": arguments]]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0a)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func testCanonicalOrdinaryUUIDStillReadsActivity() throws {
        try withRoot { root in
            try writeIndex([thread], root: root)
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(thread)))
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertEqual(snapshot.tasks.map(\.id), [thread])
            XCTAssertFalse(snapshot.isPartial)
            XCTAssertTrue(try XCTUnwrap(snapshot.tasks.first).isActive)
            XCTAssertTrue(snapshot.terminalIDs.isEmpty)
        }
    }

    func testUniqueRevertedFileBelongsToThreadNotRolloutID() throws {
        try withRoot { root in
            try writeIndex([thread, revision], root: root)
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(thread, revision: revision)))
            let snapshot = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertEqual(snapshot.tasks.map(\.id), [thread])
            XCTAssertFalse(snapshot.tasks.contains { $0.id == revision })
            XCTAssertFalse(snapshot.terminalIDs.contains(revision))
        }
    }

    func testOldTerminalAndNewRevisionRetainUnconfirmedAndDoNotAffectNeighbor() throws {
        try withRoot { root in
            try writeIndex([thread, other], root: root)
            let old = root.appendingPathComponent("sessions/" + name(thread))
            let neighbor = root.appendingPathComponent("sessions/" + name(other))
            let newest = root.appendingPathComponent("sessions/" + name(thread, revision: revision, time: "2026-11-09T10-00-01"))
            try writeEvent("task_started", at: old)
            try appendPlan(at: old)
            try writeEvent("task_started", at: neighbor)
            let reader = CodexTaskReader(codexHome: root)
            let before = try reader.readSnapshot()
            XCTAssertEqual(Set(before.tasks.map(\.id)), Set([thread, other]))
            XCTAssertEqual(before.tasks.first { $0.id == thread }?.steps.map(\.title), ["Synthetic step"])

            try writeEvent("task_complete", at: old)
            try writeEvent("task_started", at: newest)
            let during = try reader.readSnapshot(previouslyObserved: [thread, other])
            XCTAssertTrue(during.isPartial)
            XCTAssertFalse(during.terminalIDs.contains(thread))
            XCTAssertFalse(during.tasks.contains { $0.id == thread && $0.isActive && !$0.isUnconfirmed })
            XCTAssertTrue(during.tasks.contains { $0.id == other && $0.isActive && !$0.isUnconfirmed })
            let merged = TaskSnapshotMerger.merge(previous: before.tasks, current: during.tasks, terminalIDs: during.terminalIDs)
            let retained = try XCTUnwrap(merged.first { $0.id == thread })
            XCTAssertTrue(retained.isUnconfirmed)
            XCTAssertFalse(retained.isActive)
            XCTAssertFalse(retained.planConfirmed)
            XCTAssertNil(retained.progress)
            XCTAssertEqual(retained.steps.map(\.title), ["Synthetic step"])
            XCTAssertEqual(retained.title, "Synthetic title")
            XCTAssertTrue(merged.contains { $0.id == other && $0.isActive && !$0.isUnconfirmed })

            // This is only a deterministic recovery fixture, not a claim that
            // Codex normally deletes its older immutable rollout.
            try FileManager.default.removeItem(at: old)
            let after = try reader.readSnapshot(previouslyObserved: [thread, other])
            XCTAssertFalse(after.isPartial)
            XCTAssertTrue(after.tasks.contains { $0.id == thread && $0.isActive && !$0.isUnconfirmed })
            XCTAssertTrue(after.tasks.contains { $0.id == other && $0.isActive && !$0.isUnconfirmed })
        }
    }

    func testThreeRolloutsRemainAmbiguousRegardlessOfEnumerationOrder() throws {
        try withRoot { root in
            try writeIndex([thread], root: root)
            let a = root.appendingPathComponent("sessions/" + name(thread))
            let b = root.appendingPathComponent("sessions/" + name(thread, revision: revision, time: "2026-11-09T10-00-01"))
            let c = root.appendingPathComponent("sessions/" + name(thread, revision: other, time: "2026-11-09T10-00-02"))
            try writeEvent("task_complete", at: a)
            try writeEvent("task_started", at: b)
            try writeEvent("task_started", at: c)
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.terminalIDs.contains(thread))
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
        }
    }

    func testCompressedNewRevisionCannotMakeOldTerminalLookUnique() throws {
        try withRoot { root in
            try writeIndex([thread, other], root: root)
            try writeEvent("task_complete", at: root.appendingPathComponent("sessions/" + name(thread)))
            try Data("synthetic placeholder, not a zstd archive".utf8).write(to: root.appendingPathComponent("sessions/" + name(thread, revision: revision) + ".zst"))
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(other)))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.terminalIDs.contains(thread))
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
            XCTAssertTrue(result.tasks.contains { $0.id == other && $0.isActive })
        }
    }

    func testCompressedOnlyDoesNotProduceAConfirmedTask() throws {
        try withRoot { root in
            try writeIndex([thread], root: root)
            try Data().write(to: root.appendingPathComponent("sessions/" + name(thread) + ".zst"))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
            XCTAssertTrue(result.terminalIDs.isEmpty)
        }
    }

    func testNonUUIDSuffixAndCompoundIDAreNotClaimed() throws {
        try withRoot { root in
            let compound = thread + "_" + revision
            try writeIndex(["short", compound], root: root)
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/rollout-long-short.jsonl"))
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(thread, revision: revision)))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
            XCTAssertTrue(result.terminalIDs.isEmpty)
        }
    }

    func testUnknownFilenameContainingKnownUUIDFailsClosed() throws {
        try withRoot { root in
            try writeIndex([thread], root: root)
            try writeEvent("task_complete", at: root.appendingPathComponent("sessions/" + name(thread)))
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/rollout-unrecognised-\(thread)_\(revision).jsonl"))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertFalse(result.terminalIDs.contains(thread))
            XCTAssertFalse(result.tasks.contains { $0.id == thread })
        }
    }

    func testUnrelatedUnknownFileDoesNotHideAnOrdinaryUUID() throws {
        try withRoot { root in
            try writeIndex([thread], root: root)
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(thread)))
            try Data().write(to: root.appendingPathComponent("sessions/rollout-other-unknown.jsonl"))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.tasks.contains { $0.id == thread && $0.isActive })
        }
    }

    @MainActor
    func testFirstAmbiguousThreadDisplaysPartialWarningAlongsideConfirmedNeighbor() throws {
        try withRoot { root in
            let codex = root.appendingPathComponent("codex", isDirectory: true)
            let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeIndex([thread, other], root: codex)
            let old = sessions.appendingPathComponent(name(thread))
            try writeEvent("task_complete", at: old)
            try writeEvent("task_started", at: sessions.appendingPathComponent(name(thread, revision: revision)))
            try writeEvent("task_started", at: sessions.appendingPathComponent(name(other)))
            let store = TaskStore(codexReader: CodexTaskReader(codexHome: codex),
                                  claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                                  journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")))
            store.refresh()
            XCTAssertTrue(store.codexPartiallyUnavailable)
            XCTAssertFalse(store.unavailableSources.contains(.codex))
            XCTAssertTrue(store.unavailableMessage.contains("Codex"))
            XCTAssertTrue(store.tasks.contains { $0.id == other && $0.isActive && !$0.isUnconfirmed })
            XCTAssertFalse(store.tasks.contains { $0.id == thread })
            try FileManager.default.removeItem(at: old)
            store.refresh()
            XCTAssertFalse(store.codexPartiallyUnavailable)
            XCTAssertTrue(store.tasks.contains { $0.id == other && $0.isActive })
            XCTAssertTrue(store.tasks.contains { $0.id == thread && $0.isActive })
        }
    }

    @MainActor
    func testFirstCompressedOnlyDisplaysPartialWarningWhenNoCardWasObserved() throws {
        try withRoot { root in
            let codex = root.appendingPathComponent("codex", isDirectory: true)
            let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try writeIndex([thread], root: codex)
            try Data().write(to: sessions.appendingPathComponent(name(thread) + ".zst"))
            let store = TaskStore(codexReader: CodexTaskReader(codexHome: codex),
                                  claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("unused")),
                                  journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")))
            store.refresh()
            XCTAssertTrue(store.codexPartiallyUnavailable)
            XCTAssertFalse(store.unavailableSources.contains(.codex))
            XCTAssertTrue(store.tasks.isEmpty)
            XCTAssertTrue(store.unavailableMessage.contains("Codex"))
        }
    }

    func testDifferentUUIDLetterCaseIsUnconfirmedInsteadOfSilentAbsence() throws {
        try withRoot { root in
            try writeIndex([thread.uppercased()], root: root)
            try writeEvent("task_complete", at: root.appendingPathComponent("sessions/" + name(thread)))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
            XCTAssertTrue(result.terminalIDs.isEmpty)
        }
    }

    func testTwoCaseVariantsOfOneUUIDAreBothUnconfirmed() throws {
        try withRoot { root in
            try writeIndex([thread, thread.uppercased()], root: root)
            try writeEvent("task_started", at: root.appendingPathComponent("sessions/" + name(thread)))
            let result = try CodexTaskReader(codexHome: root).readSnapshot()
            XCTAssertTrue(result.isPartial)
            XCTAssertTrue(result.tasks.isEmpty)
            XCTAssertTrue(result.terminalIDs.isEmpty)
        }
    }
}
