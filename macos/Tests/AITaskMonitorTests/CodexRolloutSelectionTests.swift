import Foundation
import Darwin
import XCTest
@testable import AITaskMonitor

/// Synthetic files only, inside the isolated hosted-runner fixture.
final class CodexRolloutSelectionTests: XCTestCase {
    private let thread = "019127f4-35ae-7c73-9e72-a10123456789"
    private let neighbor = "019127f4-35ae-7c73-9e72-a10123456780"
    private let revision = "019127f4-35ae-7c73-9e72-a10987654321"
    private let monitoringStartedAt = Date().addingTimeInterval(-60)

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", env["AITM_MACOS_TEST_SANDBOX"] == "1",
              let rootPath = env["AITM_SYNTHETIC_TEST_ROOT"],
              let denied = env["AITM_CI_DENIED_FILE"] else {
            throw XCTSkip("Synthetic rollout tests require the isolated hosted-runner fixture")
        }
        guard env["HOME"] == nil, env["CODEX_HOME"] == nil else { throw CocoaError(.fileWriteNoPermission) }
        let probe = denied.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if probe >= 0 {
            Darwin.close(probe)
            throw CocoaError(.fileWriteNoPermission)
        }
        guard errno == EACCES || errno == EPERM else { throw CocoaError(.fileWriteNoPermission) }
        let base = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
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
        let previousLanguage = AppLanguage.previewOverride
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = previousLanguage }
        let root = resolved.appendingPathComponent("aitm-codex-rollout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: false)
        try body(root)
    }

    private func file(_ root: URL, id: String, revision: String? = nil) -> URL {
        root.appendingPathComponent("sessions/rollout-2026-11-23T10-00-00-\(id)\(revision.map { "_" + $0 } ?? "").jsonl")
    }

    private func row(_ type: String, id: String? = nil, turn: String = "synthetic-turn") throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload: [String: Any] = ["type": type, "turn_id": turn]
        if let id { payload["thread_id"] = id }
        if type == "agent_reasoning" { payload["text"] = "Synthetic activity" }
        if type == "agent_message" { payload["message"] = "Synthetic activity" }
        if type == "item_completed" || type == "item_started" {
            payload["item"] = ["id": "synthetic-item", "type": "Reasoning"]
        }
        var data = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: Date()),
                                                               "type": "event_msg", "payload": payload],
                                                  options: [.sortedKeys])
        data.append(0x0a)
        return data
    }

    private func create(_ url: URL, id: String, event: String = "task_started") throws {
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id]],
                                              options: [.sortedKeys])
        data.append(0x0a)
        data.append(try row(event))
        try data.write(to: url)
    }

    private func failedRow(id: String, turn: String) throws -> Data {
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: row("task_complete", id: id, turn: turn)) as? [String: Any])
        var payload = try XCTUnwrap(record["payload"] as? [String: Any])
        payload["error"] = ["message": "Synthetic error"]
        record["payload"] = payload
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(0x0a)
        return data
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func setup(_ root: URL) throws -> (old: URL, current: URL, other: URL) {
        var index = Data()
        for id in [thread, neighbor] {
            index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic \(id)"]))
            index.append(0x0a)
        }
        try index.write(to: root.appendingPathComponent("session_index.jsonl"))
        let old = file(root, id: thread)
        let current = file(root, id: thread, revision: revision)
        let other = file(root, id: neighbor)
        try create(old, id: thread, event: "task_complete")
        try create(current, id: thread)
        try create(other, id: neighbor)
        return (old, current, other)
    }

    private func snapshot(_ reader: CodexTaskReader, observed: Set<String> = [], hidden: Set<String> = [],
                          since: Date? = nil) throws -> CodexTaskSnapshot {
        let start = since ?? monitoringStartedAt
        _ = try reader.readSnapshot(observedSince: start, previouslyObserved: observed, hiddenIDs: hidden)
        reader.waitForAmbiguousObservationForTests()
        let result = try reader.readSnapshot(observedSince: start, previouslyObserved: observed, hiddenIDs: hidden)
        reader.waitForAmbiguousObservationForTests()
        return result
    }

    func testOnlyNewObservedEventCreatesUnconfirmedCardAndKeepsNeighbor() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            let baseline = try snapshot(reader)
            XCTAssertTrue(baseline.isPartial)
            XCTAssertFalse(baseline.tasks.contains { $0.id == thread })
            XCTAssertTrue(baseline.tasks.contains { $0.id == neighbor && $0.isActive })

            try append(row("agent_reasoning", id: thread), to: files.current)
            let after = try snapshot(reader)
            let hint = try XCTUnwrap(after.tasks.first { $0.id == thread })
            XCTAssertTrue(after.isPartial)
            XCTAssertTrue(hint.isUnconfirmed)
            XCTAssertFalse(hint.isActive)
            XCTAssertNil(hint.progress)
            XCTAssertEqual(hint.progressKind, .none)
            XCTAssertFalse(hint.planConfirmed)
            XCTAssertTrue(hint.steps.isEmpty)
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertNil(after.toolEvents[thread])
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })

            let quiet = try snapshot(reader, observed: [thread])
            let stillUnknown = TaskSnapshotMerger.merge(previous: [hint], current: quiet.tasks, terminalIDs: quiet.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(stillUnknown.first { $0.id == thread }).isUnconfirmed)
            XCTAssertFalse(quiet.terminalIDs.contains(thread))

            try append(row("task_complete", id: thread), to: files.current)
            let terminal = try snapshot(reader, observed: [thread])
            XCTAssertFalse(terminal.terminalIDs.contains(thread))
            XCTAssertNotNil(terminal.uncertainEndings[thread])
            XCTAssertFalse(terminal.tasks.contains { $0.id == thread })
            XCTAssertTrue(terminal.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testSingleNewEventAfterColdHistoriesCreatesHint() throws {
        try withRoot { root in
            let files = try setup(root)
            let beforeMonitor = monitoringStartedAt.addingTimeInterval(-60)
            try FileManager.default.setAttributes([.modificationDate: beforeMonitor], ofItemAtPath: files.old.path)
            try FileManager.default.setAttributes([.modificationDate: beforeMonitor], ofItemAtPath: files.current.path)
            let reader = CodexTaskReader(codexHome: root)
            let baseline = try snapshot(reader)
            XCTAssertFalse(baseline.tasks.contains { $0.id == thread })
            try append(row("agent_reasoning", id: thread), to: files.current)
            let after = try snapshot(reader)
            XCTAssertTrue(try XCTUnwrap(after.tasks.first { $0.id == thread }).isUnconfirmed)
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testEventBeforeFirstBaselineNeedsAnotherObservedEvent() throws {
        try withRoot { root in
            let files = try setup(root)
            // This timestamp is after monitoringStartedAt, but the append
            // happened before the observer's first actual baseline.
            try append(row("agent_reasoning", id: thread), to: files.current)
            let reader = CodexTaskReader(codexHome: root)
            let baseline = try snapshot(reader)
            XCTAssertFalse(baseline.tasks.contains { $0.id == thread })
            try append(row("agent_reasoning", id: thread), to: files.current)
            XCTAssertTrue(try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread }).isUnconfirmed)
        }
    }

    func testItemEventsWithoutObservedStartAndLongSequence() throws {
        try withRoot { root in
            let files = try setup(root)
            try create(files.current, id: thread, event: "unrelated_event")
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            var batch = Data()
            for _ in 0..<163 { batch.append(try row("item_completed", id: thread)) }
            try append(batch, to: files.current)
            let after = try snapshot(reader)
            let task = try XCTUnwrap(after.tasks.first { $0.id == thread })
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertFalse(task.isActive)
            XCTAssertNil(task.progress)
            XCTAssertFalse(after.terminalIDs.contains(thread))
        }
    }

    func testTerminalBlocksLateSameTurnUntilAnotherStart() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            var batch = try row("task_complete", id: thread)
            batch.append(try row("agent_message", id: thread))
            try append(batch, to: files.current)
            let ending = try snapshot(reader)
            let notice = try XCTUnwrap(ending.uncertainEndings[thread])
            XCTAssertFalse(ending.tasks.contains { $0.id == thread })
            XCTAssertFalse(ending.terminalIDs.contains(thread))
            reader.acknowledgeUncertainEndings([thread: notice.token])
            try append(row("item_completed", id: thread), to: files.current)
            let late = try snapshot(reader, hidden: [thread])
            XCTAssertFalse(late.tasks.contains { $0.id == thread })
            XCTAssertFalse(late.terminalIDs.contains(thread))
            try append(row("task_started", id: thread, turn: "new-turn"), to: files.current)
            let newTurn = try snapshot(reader, hidden: [thread])
            XCTAssertFalse(newTurn.tasks.contains { $0.id == thread })
        }
        try withRoot { root in
            let files = try setup(root)
            try create(files.current, id: thread, event: "task_complete")
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("item_completed", id: thread), to: files.current)
            let late = try snapshot(reader)
            XCTAssertFalse(late.tasks.contains { $0.id == thread })
            XCTAssertFalse(late.terminalIDs.contains(thread))
        }
    }

    func testCompleteTerminalBeforePartialTailIsNotIgnored() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            XCTAssertTrue(try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread }).isUnconfirmed)

            let following = try row("agent_message", id: thread)
            let split = following.count / 2
            var batch = try row("task_complete", id: thread)
            batch.append(contentsOf: following.prefix(split))
            try append(batch, to: files.current)
            let ending = try snapshot(reader, observed: [thread])
            let notice = try XCTUnwrap(ending.uncertainEndings[thread])
            XCTAssertFalse(ending.tasks.contains { $0.id == thread })
            XCTAssertFalse(ending.terminalIDs.contains(thread))
            XCTAssertTrue(ending.tasks.contains { $0.id == neighbor && $0.isActive })

            reader.acknowledgeUncertainEndings([thread: notice.token])
            try append(Data(following.dropFirst(split)), to: files.current)
            let completed = try snapshot(reader, hidden: [thread])
            XCTAssertNil(completed.uncertainEndings[thread])
            XCTAssertFalse(completed.tasks.contains { $0.id == thread })
            XCTAssertFalse(completed.terminalIDs.contains(thread))
            XCTAssertTrue(completed.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testEndingBeforeCompetingHistoryBaselineHidesObservedCard() throws {
        try withRoot { root in
            let files = try setup(root)
            try FileManager.default.removeItem(at: files.old)
            let reader = CodexTaskReader(codexHome: root)
            let initial = try snapshot(reader)
            XCTAssertTrue(initial.tasks.contains { $0.id == thread && $0.isActive })

            // The ending and the second history appear between refreshes.
            try append(row("task_complete", id: thread), to: files.current)
            try create(files.old, id: thread, event: "unrelated_event")
            let ambiguous = try snapshot(reader, observed: [thread])
            let notice = try XCTUnwrap(ambiguous.uncertainEndings[thread])
            XCTAssertFalse(ambiguous.tasks.contains { $0.id == thread })
            XCTAssertFalse(ambiguous.terminalIDs.contains(thread))
            XCTAssertTrue(ambiguous.tasks.contains { $0.id == neighbor && $0.isActive })

            reader.acknowledgeUncertainEndings([thread: notice.token])
            let unchanged = try snapshot(reader, hidden: [thread])
            XCTAssertFalse(unchanged.tasks.contains { $0.id == thread })
            XCTAssertFalse(unchanged.terminalIDs.contains(thread))
            XCTAssertTrue(unchanged.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testOlderTurnTerminalDoesNotSuppressNewTurn() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            var batch = try row("task_started", id: thread, turn: "new-turn")
            batch.append(try row("task_complete", id: thread, turn: "synthetic-turn"))
            batch.append(try row("item_completed", id: thread, turn: "new-turn"))
            try append(batch, to: files.current)
            let after = try snapshot(reader)
            XCTAssertTrue(try XCTUnwrap(after.tasks.first { $0.id == thread }).isUnconfirmed)
            XCTAssertFalse(after.terminalIDs.contains(thread))
        }
    }

    func testStaleBackgroundResultIsDiscardedWhenCandidatesChange() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            _ = try reader.readSnapshot(observedSince: monitoringStartedAt)
            reader.waitForAmbiguousObservationForTests()
            try FileManager.default.removeItem(at: files.current)
            let after = try reader.readSnapshot(observedSince: monitoringStartedAt)
            reader.waitForAmbiguousObservationForTests()
            XCTAssertFalse(after.tasks.contains { $0.id == thread && $0.isUnconfirmed })
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testEventAfterBackgroundReadCanOnlyLeaveUnconfirmedHint() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            _ = try reader.readSnapshot(observedSince: monitoringStartedAt)
            reader.waitForAmbiguousObservationForTests()
            // A writer may finish after the scan but before its hint is used.
            try append(row("task_complete", id: thread), to: files.current)
            let after = try reader.readSnapshot(observedSince: monitoringStartedAt)
            reader.waitForAmbiguousObservationForTests()
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertFalse(after.tasks.contains { $0.id == thread && $0.isActive })
            XCTAssertTrue(after.tasks.filter { $0.id == thread }.allSatisfy { $0.isUnconfirmed && $0.progress == nil })
        }
    }

    func testWorkerPollReturnsWhileObservationIsBlocked() throws {
        try withRoot { root in
            let files = try setup(root)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let worker = CodexAmbiguousRolloutWorker(observeForTests: { _, _ in
                started.signal()
                _ = release.wait(timeout: .now() + 10)
                return [:]
            })
            defer {
                release.signal()
                worker.waitUntilIdleForTests()
            }
            let candidates = [thread: [files.old, files.current]]
            _ = worker.poll(candidates: candidates, ambiguousIDs: [thread], previouslyObserved: [],
                            sessionsDirectory: root.appendingPathComponent("sessions"), observedSince: monitoringStartedAt)
            XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
            let beginning = ProcessInfo.processInfo.systemUptime
            _ = worker.poll(candidates: candidates, ambiguousIDs: [thread], previouslyObserved: [],
                            sessionsDirectory: root.appendingPathComponent("sessions"), observedSince: monitoringStartedAt)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - beginning, 1.0)
        }
    }

    func testWorkerDiscardsResultFromEarlierMonitoringSession() throws {
        try withRoot { root in
            let files = try setup(root)
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let callsLock = NSLock()
            var calls = 0
            let worker = CodexAmbiguousRolloutWorker(observeForTests: { _, _ in
                callsLock.lock()
                calls += 1
                let first = calls == 1
                callsLock.unlock()
                if first {
                    started.signal()
                    _ = release.wait(timeout: .now() + 10)
                    return [self.thread: CodexRolloutHint(path: files.current.path, device: 0, inode: 0,
                                                         size: 0, modified: Date(), turnID: "synthetic-turn")]
                }
                return [:]
            })
            defer {
                release.signal()
                worker.waitUntilIdleForTests()
            }
            let candidates = [thread: [files.old, files.current]]
            let sessions = root.appendingPathComponent("sessions")
            _ = worker.poll(candidates: candidates, ambiguousIDs: [thread], previouslyObserved: [],
                            sessionsDirectory: sessions, observedSince: monitoringStartedAt)
            XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
            let newerStart = monitoringStartedAt.addingTimeInterval(1)
            _ = worker.poll(candidates: candidates, ambiguousIDs: [thread], previouslyObserved: [],
                            sessionsDirectory: sessions, observedSince: newerStart)
            release.signal()
            worker.waitUntilIdleForTests()
            let after = worker.poll(candidates: candidates, ambiguousIDs: [thread], previouslyObserved: [],
                                    sessionsDirectory: sessions, observedSince: newerStart)
            XCTAssertTrue(after.hints.isEmpty)
        }
    }

    func testProtectionOfManyCardsDoesNotBlockOtherIDs() throws {
        try withRoot { root in
            let worker = CodexAmbiguousRolloutWorker()
            let ids = Set((1...513).map { String(format: "019127f4-35ae-7c73-9e72-%012d", $0) })
            let sessions = root.appendingPathComponent("sessions")
            let observed = ids.union([neighbor])
            let first = worker.poll(candidates: [:], ambiguousIDs: ids, previouslyObserved: observed,
                                    sessionsDirectory: sessions, observedSince: monitoringStartedAt)
            XCTAssertEqual(first.protectedIDs.count, 513)
            XCTAssertFalse(first.protects(neighbor))
            let later = worker.poll(candidates: [:], ambiguousIDs: [], previouslyObserved: [neighbor],
                                    sessionsDirectory: sessions, observedSince: monitoringStartedAt)
            XCTAssertTrue(later.protectedIDs.isEmpty)
            XCTAssertFalse(later.protects(neighbor))
        }
    }

    func testBothGrowingRemainUncertainAndRetainPreviousCard() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            let initial = try snapshot(reader)
            let previous = try XCTUnwrap(initial.tasks.first { $0.id == thread })
            try append(row("agent_reasoning"), to: files.old)
            try append(row("agent_message"), to: files.current)
            let conflict = try snapshot(reader, observed: [thread])
            XCTAssertTrue(conflict.isPartial)
            XCTAssertFalse(conflict.terminalIDs.contains(thread))
            XCTAssertFalse(conflict.tasks.contains { $0.id == thread })
            XCTAssertTrue(conflict.tasks.contains { $0.id == neighbor && $0.isActive })
            let retained = TaskSnapshotMerger.merge(previous: [previous], current: conflict.tasks, terminalIDs: conflict.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(retained.first { $0.id == thread }).isUnconfirmed)
            try append(row("agent_reasoning"), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
        }
    }

    func testFreshBaselineAfterConflictRequiresNewEvent() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.old)
            try append(row("agent_reasoning"), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            // Two quiet scans reset observation, without presenting either old event.
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            try append(row("agent_reasoning"), to: files.current)
            let newHint = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            XCTAssertTrue(newHint.isUnconfirmed)
            XCTAssertNil(newHint.progress)
        }
    }

    func testObservationVisitsMoreThanSixteenAmbiguousThreads() throws {
        try withRoot { root in
            var index = Data()
            var watchedID = ""
            var watchedFile: URL?
            for value in 1...17 {
                let id = String(format: "019127f4-35ae-7c73-9e72-%012d", value)
                index.append(try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Synthetic"]))
                index.append(0x0a)
                let original = file(root, id: id)
                let revised = file(root, id: id, revision: revision)
                try create(original, id: id, event: "task_complete")
                try create(revised, id: id)
                if value == 16 {
                    watchedID = id
                    watchedFile = revised
                }
            }
            try index.write(to: root.appendingPathComponent("session_index.jsonl"))
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader) // The second background scan excludes ID 16.
            try append(row("agent_reasoning"), to: XCTUnwrap(watchedFile))
            let after = try snapshot(reader)
            let task = try XCTUnwrap(after.tasks.first { $0.id == watchedID })
            XCTAssertTrue(task.isUnconfirmed)
            XCTAssertNil(task.progress)
            XCTAssertFalse(after.terminalIDs.contains(watchedID))
        }
    }

    func testPartialRecordWaitsForCompleteNewline() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            let event = try row("agent_reasoning")
            let cut = event.count / 2
            try append(Data(event.prefix(cut)), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            try append(Data(event.dropFirst(cut)), to: files.current)
            XCTAssertTrue(try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread }).isUnconfirmed)
        }
    }

    func testOldPartialRecordIsNotCountedAsNew() throws {
        try withRoot { root in
            let files = try setup(root)
            let event = try row("agent_reasoning")
            let cut = event.count / 2
            try append(Data(event.prefix(cut)), to: files.current)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(Data(event.dropFirst(cut)), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            try append(row("task_started", turn: "new-turn"), to: files.current)
            XCTAssertTrue(try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread }).isUnconfirmed)
        }
    }

    func testCompetingPartialRecordBlocksHintAndTerminalAloneDoesNotCreateOne() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            try append(Data("{\"type\":".utf8), to: files.old)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
            try append(Data("\"event_msg\"}\n".utf8), to: files.old)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
        }
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            var completedBatch = try row("agent_reasoning")
            completedBatch.append(try row("task_complete"))
            try append(completedBatch, to: files.current)
            let after = try snapshot(reader)
            XCTAssertFalse(after.tasks.contains { $0.id == thread })
            XCTAssertFalse(after.terminalIDs.contains(thread))
        }
    }

    func testPreviouslyObservedPlanSurvivesAmbiguityAndConflictingWrites() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            let previous = MonitoredTask(id: thread, provider: .codex, title: "Previously seen",
                                         activity: "Previously seen activity", isActive: true,
                                         progress: 50, progressKind: .exact,
                                         steps: [TaskStep(title: "Known step", status: .active)],
                                         updatedAt: Date())
            _ = try snapshot(reader, observed: [thread])
            try append(row("agent_reasoning"), to: files.current)
            try append(row("agent_reasoning"), to: files.old)
            let conflict = try snapshot(reader, observed: [thread])
            let merged = TaskSnapshotMerger.merge(previous: [previous], current: conflict.tasks,
                                                  terminalIDs: conflict.terminalIDs)
            let retained = try XCTUnwrap(merged.first { $0.id == thread })
            XCTAssertTrue(retained.isUnconfirmed)
            XCTAssertNil(retained.progress)
            XCTAssertFalse(retained.planConfirmed)
            XCTAssertEqual(retained.steps.map(\.title), ["Known step"])
            XCTAssertTrue(merged.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testChangedAnchorCannotCreateHint() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            let handle = try FileHandle(forWritingTo: files.current)
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - 2)
            try handle.write(contentsOf: Data("x\n".utf8))
            try handle.close()
            try append(row("agent_reasoning"), to: files.current)
            let after = try snapshot(reader)
            XCTAssertFalse(after.tasks.contains { $0.id == thread })
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testReplacementAndTruncationCannotCreateHint() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            let replacement = root.appendingPathComponent("replacement")
            try create(replacement, id: thread)
            try append(row("agent_reasoning"), to: replacement)
            XCTAssertEqual(replacement.path.withCString { source in files.current.path.withCString { rename(source, $0) } }, 0)
            let changed = try snapshot(reader)
            XCTAssertFalse(changed.tasks.contains { $0.id == thread })
            XCTAssertFalse(changed.terminalIDs.contains(thread))
            try append(row("agent_reasoning"), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
        }
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            let handle = try FileHandle(forWritingTo: files.current)
            try handle.truncate(atOffset: 0)
            try handle.close()
            let truncated = try snapshot(reader)
            XCTAssertFalse(truncated.tasks.contains { $0.id == thread })
            XCTAssertFalse(truncated.terminalIDs.contains(thread))
            try create(files.current, id: thread)
            try append(row("agent_reasoning"), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
        }
    }

    func testUncertainCardIsNotPromotedWhenItsRolloutDisappears() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            let previous = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            let moved = root.appendingPathComponent("temporarily-moved")
            try FileManager.default.moveItem(at: files.current, to: moved)
            let after = try snapshot(reader, observed: [thread])
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertFalse(after.tasks.contains { $0.id == thread })
            XCTAssertTrue(after.isPartial)
            let retained = TaskSnapshotMerger.merge(previous: [previous], current: after.tasks, terminalIDs: after.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(retained.first { $0.id == thread }).isUnconfirmed)
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
            try FileManager.default.moveItem(at: moved, to: files.current)
            let restored = try snapshot(reader, observed: [thread])
            XCTAssertFalse(restored.terminalIDs.contains(thread))
            let stillRetained = TaskSnapshotMerger.merge(previous: retained, current: restored.tasks, terminalIDs: restored.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(stillRetained.first { $0.id == thread }).isUnconfirmed)
        }
        try withRoot { root in
            let files = try setup(root)
            try create(files.old, id: thread, event: "task_started")
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            let previous = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            try FileManager.default.removeItem(at: files.current)
            let after = try snapshot(reader, observed: [thread])
            XCTAssertFalse(after.tasks.contains { $0.id == thread && $0.isActive })
            XCTAssertFalse(after.terminalIDs.contains(thread))
            let retained = TaskSnapshotMerger.merge(previous: [previous], current: after.tasks, terminalIDs: after.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(retained.first { $0.id == thread }).isUnconfirmed)
        }
    }

    func testNewTurnOnSameUniqueRolloutRecoversWithoutClosingOldTurn() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            let previous = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            XCTAssertTrue(previous.isUnconfirmed)
            try FileManager.default.removeItem(at: files.old)
            let baseline = try snapshot(reader, observed: [thread])
            XCTAssertFalse(baseline.terminalIDs.contains(thread))
            XCTAssertFalse(baseline.tasks.contains { $0.id == thread && $0.isActive })

            try append(row("task_started", id: thread), to: files.current)
            let repeated = try snapshot(reader, observed: [thread])
            XCTAssertFalse(repeated.terminalIDs.contains(thread))
            XCTAssertFalse(repeated.tasks.contains { $0.id == thread && $0.isActive })
            try append(row("task_complete", id: thread), to: files.current)
            let oldTerminal = try snapshot(reader, observed: [thread])
            XCTAssertFalse(oldTerminal.terminalIDs.contains(thread))
            let notice = try XCTUnwrap(oldTerminal.uncertainEndings[thread])
            reader.acknowledgeUncertainEndings([thread: notice.token])
            try append(row("task_started", id: thread, turn: "new-turn"), to: files.current)
            let active = try snapshot(reader, hidden: [thread])
            let current = try XCTUnwrap(active.tasks.first { $0.id == thread })
            XCTAssertTrue(current.isActive)
            XCTAssertFalse(current.isUnconfirmed)
            XCTAssertEqual(current.startKey, "turn:new-turn")
            // A delayed legacy terminal without a turn ID cannot close T2.
            try append(row("task_complete", id: thread, turn: ""), to: files.current)
            let unscoped = try snapshot(reader, observed: [thread])
            XCTAssertFalse(unscoped.terminalIDs.contains(thread))
            let laterNotice = try XCTUnwrap(unscoped.uncertainEndings[thread])
            XCTAssertFalse(unscoped.tasks.contains { $0.id == thread })
            reader.acknowledgeUncertainEndings([thread: laterNotice.token])
            try append(row("task_complete", id: thread, turn: "new-turn"), to: files.current)
            let finished = try snapshot(reader, hidden: [thread])
            XCTAssertFalse(finished.terminalIDs.contains(thread))
            XCTAssertFalse(finished.tasks.contains { $0.id == thread })
            XCTAssertTrue(finished.tasks.contains { $0.id == neighbor && $0.isActive })
        }
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            _ = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            try FileManager.default.removeItem(at: files.old)
            _ = try snapshot(reader, observed: [thread])
            let replacement = root.appendingPathComponent("replacement")
            try create(replacement, id: thread)
            try append(row("task_started", id: thread, turn: "new-turn"), to: replacement)
            XCTAssertEqual(replacement.path.withCString { source in files.current.path.withCString { rename(source, $0) } }, 0)
            let after = try snapshot(reader, observed: [thread])
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertFalse(after.tasks.contains { $0.id == thread && $0.isActive })
        }
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            _ = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            try FileManager.default.removeItem(at: files.old)
            _ = try snapshot(reader, observed: [thread])
            try append(row("task_started", id: thread, turn: "new-turn"), to: files.current)
            XCTAssertTrue(try XCTUnwrap(snapshot(reader, observed: [thread]).tasks.first { $0.id == thread }).isActive)
            try append(failedRow(id: thread, turn: "new-turn"), to: files.current)
            let failure = try snapshot(reader, observed: [thread])
            XCTAssertFalse(failure.terminalIDs.contains(thread))
        }
    }

    func testUniqueRecoveryProofCarriesExactFilesystemTime() throws {
        try withRoot { root in
            let files = try setup(root)
            let sessions = root.appendingPathComponent("sessions")
            let tracker = CodexAmbiguousRolloutTracker()
            let candidates = [thread: [files.old, files.current]]
            XCTAssertTrue(tracker.observe(candidates, sessionsDirectory: sessions).isEmpty)
            try append(row("agent_reasoning", id: thread), to: files.current)
            let previous = try XCTUnwrap(tracker.observe(candidates, sessionsDirectory: sessions)[thread])
            try FileManager.default.removeItem(at: files.old)
            XCTAssertTrue(tracker.observeUnique([thread: previous], protectedIDs: [thread], sessionsDirectory: sessions).isEmpty)
            try append(row("task_started", id: thread, turn: "new-turn"), to: files.current)
            let proof = try XCTUnwrap(tracker.observeUnique([thread: previous], protectedIDs: [thread],
                                                          sessionsDirectory: sessions)[thread])
            var information = stat()
            XCTAssertEqual(lstat(files.current.path, &information), 0)
            XCTAssertEqual(proof.modifiedSeconds, Int64(information.st_mtimespec.tv_sec))
            XCTAssertEqual(proof.modifiedNanoseconds, Int64(information.st_mtimespec.tv_nsec))
            XCTAssertEqual(proof.size, UInt64(information.st_size))
        }
    }

    func testFreshStartCompletingBeforeDeliveryDoesNotCloseOldCard() throws {
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning", id: thread), to: files.current)
            let previous = try XCTUnwrap(snapshot(reader).tasks.first { $0.id == thread })
            try FileManager.default.removeItem(at: files.old)
            _ = try snapshot(reader, observed: [thread])
            try append(row("task_started", id: thread, turn: "new-turn"), to: files.current)
            _ = try reader.readSnapshot(observedSince: monitoringStartedAt, previouslyObserved: [thread])
            reader.waitForAmbiguousObservationForTests()
            try append(row("task_complete", id: thread, turn: "new-turn"), to: files.current)
            let after = try reader.readSnapshot(observedSince: monitoringStartedAt, previouslyObserved: [thread])
            reader.waitForAmbiguousObservationForTests()
            XCTAssertFalse(after.terminalIDs.contains(thread))
            XCTAssertFalse(after.tasks.contains { $0.id == thread && $0.isActive })
            let retained = TaskSnapshotMerger.merge(previous: [previous], current: after.tasks, terminalIDs: after.terminalIDs)
            XCTAssertTrue(try XCTUnwrap(retained.first { $0.id == thread }).isUnconfirmed)
        }
    }

    func testOrdinarySingleRolloutKeepsExistingLifecycle() throws {
        try withRoot { root in
            let files = try setup(root)
            try FileManager.default.removeItem(at: files.old)
            let reader = CodexTaskReader(codexHome: root)
            let active = try snapshot(reader)
            XCTAssertTrue(active.tasks.contains { $0.id == thread && $0.isActive && !$0.isUnconfirmed })
            try append(row("task_complete", id: thread), to: files.current)
            let finished = try snapshot(reader, observed: [thread])
            XCTAssertTrue(finished.terminalIDs.contains(thread))
        }
    }

    func testInvalidMetadataAndOversizedAppendProduceNoHint() throws {
        try withRoot { root in
            let files = try setup(root)
            try create(files.current, id: neighbor)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            XCTAssertFalse(try snapshot(reader).tasks.contains { $0.id == thread })
        }
        try withRoot { root in
            let files = try setup(root)
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(Data(repeating: 0x20, count: 65_537), to: files.current)
            try append(row("agent_reasoning"), to: files.current)
            let after = try snapshot(reader)
            XCTAssertTrue(after.isPartial)
            XCTAssertFalse(after.tasks.contains { $0.id == thread })
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testTooManyCandidatesDoNotProduceHint() throws {
        try withRoot { root in
            let files = try setup(root)
            for value in 1...7 {
                let extraID = String(format: "019127f4-35ae-7c73-9e72-%012d", value)
                try create(file(root, id: thread, revision: extraID), id: thread)
            }
            let reader = CodexTaskReader(codexHome: root)
            _ = try snapshot(reader)
            try append(row("agent_reasoning"), to: files.current)
            let after = try snapshot(reader)
            XCTAssertTrue(after.isPartial)
            XCTAssertFalse(after.tasks.contains { $0.id == thread })
            XCTAssertTrue(after.tasks.contains { $0.id == neighbor && $0.isActive })
        }
    }

    func testHistoryGapAfterTrackingCapacityNeedsFreshStart() throws {
        try withRoot { root in
            let files = try setup(root)
            let tracker = CodexAmbiguousRolloutTracker()
            var tooMany: [String: [URL]] = [:]
            for value in 1...257 {
                let id = String(format: "019127f4-35ae-7c73-9e72-%012d", value)
                tooMany[id] = [files.old, files.current]
            }
            let sessions = root.appendingPathComponent("sessions")
            XCTAssertTrue(tracker.observe(tooMany, sessionsDirectory: sessions).isEmpty)
            let normal = [thread: [files.old, files.current]]
            XCTAssertTrue(tracker.observe(normal, sessionsDirectory: sessions).isEmpty)
            try append(row("agent_reasoning", id: thread), to: files.current)
            XCTAssertTrue(tracker.observe(normal, sessionsDirectory: sessions).isEmpty)
            try append(row("task_started", id: thread, turn: "after-capacity"), to: files.current)
            XCTAssertNotNil(tracker.observe(normal, sessionsDirectory: sessions)[thread])
        }
    }

    @MainActor
    private func drive(_ store: TaskStore, reader: CodexTaskReader, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            store.refresh()
            reader.waitForAmbiguousObservationForTests()
            store.waitForCodexHiddenStateForTests()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if condition() { return true }
        } while Date() < deadline
        return false
    }

    @MainActor
    func testHiddenEndingPersistsAcrossRestartWithoutHidingNeighbor() throws {
        try withRoot { root in
            let files = try setup(root)
            let checkpoint = CodexHiddenStateStore(directory: root.appendingPathComponent("checkpoint"))
            let key = CodexHiddenKey(codexHomeID: CodexHiddenKey.homeIdentifier(for: root), threadID: thread)
            let saved: CodexHiddenRecord
            do {
                let reader = CodexTaskReader(codexHome: root)
                let active = TaskStore(codexReader: reader,
                    claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("missing-claude")),
                    previewTasks: [], codexHiddenStore: checkpoint, loadClaudeRetentionPolicy: { nil })
                defer {
                    active.waitForCodexHiddenStateForTests()
                    reader.waitForAmbiguousObservationForTests()
                }
                active.refresh()
                try append(row("task_started", id: neighbor, turn: "neighbor-new"), to: files.other)
                XCTAssertTrue(drive(active, reader: reader) { active.tasks.contains { $0.id == self.neighbor && $0.isActive } })

                try append(row("agent_reasoning", id: thread), to: files.current)
                XCTAssertTrue(drive(active, reader: reader) { active.tasks.contains { $0.id == self.thread && $0.isUnconfirmed } })
                try append(row("task_complete", id: thread), to: files.current)
                XCTAssertTrue(drive(active, reader: reader) {
                    !active.tasks.contains { $0.id == self.thread } &&
                        active.tasks.contains { $0.id == self.neighbor && $0.isActive } &&
                        (try? checkpoint.load()[key]) != nil
                })
                saved = try XCTUnwrap(checkpoint.load()[key])
                XCTAssertNotNil(saved.turnID)
            }

            // A surviving old history can look active after a normal restart.
            // The checkpoint must suppress it without hiding its neighbor.
            try FileManager.default.removeItem(at: files.current)
            let restartedReader = CodexTaskReader(codexHome: root)
            let restarted = TaskStore(codexReader: restartedReader,
                claudeReader: ClaudeTaskReader(eventFile: root.appendingPathComponent("missing-claude")),
                previewTasks: [], codexHiddenStore: checkpoint, loadClaudeRetentionPolicy: { nil })
            defer {
                restarted.waitForCodexHiddenStateForTests()
                restartedReader.waitForAmbiguousObservationForTests()
            }
            restarted.refresh()
            try append(row("agent_reasoning", id: thread), to: files.old)
            try append(row("task_started", id: neighbor, turn: "neighbor-restarted"), to: files.other)
            XCTAssertTrue(drive(restarted, reader: restartedReader) {
                restarted.tasks.contains { $0.id == self.neighbor && $0.isActive }
            })
            for _ in 0..<3 {
                restarted.refresh()
                restartedReader.waitForAmbiguousObservationForTests()
                XCTAssertFalse(restarted.tasks.contains { $0.id == self.thread })
                XCTAssertTrue(restarted.tasks.contains { $0.id == self.neighbor && $0.isActive })
            }
            XCTAssertEqual(try checkpoint.load()[key], saved)
        }
    }
}
