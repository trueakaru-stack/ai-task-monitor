import Foundation
import Darwin
import CryptoKit

struct CodexTaskSnapshot {
    var tasks: [MonitoredTask] = []
    var terminalIDs: Set<String> = []
    var interruptedIDs: Set<String> = []
    var toolEvents: [String: [CodexToolEvent]] = [:]
    var subagentParents: [String: String] = [:]
    var subagentCandidates: Set<String> = []
    var subagentTitles: [String: String] = [:]
    var isPartial = false
}

struct CodexTaskReader {
    private struct TerminalFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(_ attributes: [FileAttributeKey: Any]) {
            guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.device = device
            self.inode = inode
            self.size = size
            self.modified = modified
        }
    }

    let codexHome: URL
    private let fileManager = FileManager.default
    private let lifecycleCache = CodexLifecycleCache()
    private let indexCache = CodexSessionIndexCache()
    private let execDiscovery = CodexExecDiscoveryCache()
    private let planCache = CodexPlanHistoryCache()
    private let ambiguousRollouts = CodexAmbiguousRolloutWorker()
    private let subagentMetadata = CodexSubagentMetadataWorker()
    private let afterDiscoveryForTests: (() -> Void)?
    private let beforeTerminalRecheckForTests: (() -> Void)?

    init(codexHome: URL? = nil, afterDiscoveryForTests: (() -> Void)? = nil,
         beforeTerminalRecheckForTests: (() -> Void)? = nil) {
        self.afterDiscoveryForTests = afterDiscoveryForTests
        self.beforeTerminalRecheckForTests = beforeTerminalRecheckForTests
        if let codexHome {
            self.codexHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            self.codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    func readTasks(now: Date = Date(), observedSince: Date? = nil) -> [MonitoredTask] {
        (try? readSnapshot(now: now, observedSince: observedSince).tasks) ?? []
    }

    // Synthetic tests use this to observe the actual asynchronous worker
    // deterministically. The application never waits for it.
    func waitForAmbiguousObservationForTests() {
        ambiguousRollouts.waitUntilIdleForTests()
        subagentMetadata.waitUntilIdleForTests()
    }

    func readSnapshot(now: Date = Date(), observedSince: Date? = nil, previouslyObserved: Set<String> = []) throws -> CodexTaskSnapshot {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        if !fileManager.fileExists(atPath: codexHome.path) { return CodexTaskSnapshot() }
        let sessions: [String: [String: Any]]
        var indexFailure: Error?
        do {
            sessions = try indexCache.read(from: index)
            execDiscovery.noteIndexAvailable()
        } catch {
            if !Self.pathIsMissing(index) || execDiscovery.hasSeenIndex() { indexFailure = error }
            sessions = [:]
        }

        let indexedIDs = Set(sessions.keys)
        let extra: (ids: Set<String>, fastFiles: [String: URL], verifiedFiles: [String: URL], isPartial: Bool)
        do {
            extra = try unindexedOwners(excluding: indexedIDs, now: now, observedSince: observedSince,
                                        previouslyObserved: previouslyObserved)
        } catch {
            guard !indexedIDs.isEmpty else { throw error }
            extra = ([], [:], [:], true)
        }
        let discovered = try sessionFiles(for: indexedIDs, now: now, observedSince: observedSince,
                                          previouslyObserved: previouslyObserved)
        let extraFiles: (files: [String: URL], ambiguousCandidates: [String: [URL]], ambiguousIDs: Set<String>, isPartial: Bool, didHitLimit: Bool)
        do {
            extraFiles = try sessionFiles(for: extra.ids, now: now, observedSince: observedSince,
                                          previouslyObserved: previouslyObserved, maximumVisited: 256)
        } catch {
            guard !indexedIDs.isEmpty else { throw error }
            extraFiles = ([:], [:], [], true, false)
        }
        let files = discovered.files
        afterDiscoveryForTests?()
        var result = CodexTaskSnapshot()
        var visibleMetadataStamps: [String: CodexSubagentMetadataWorker.Stamp] = [:]
        var indexedEndings: [String: (file: URL, identity: TerminalFileIdentity, interrupted: Bool, toolEvents: [CodexToolEvent]?)] = [:]
        result.isPartial = indexFailure != nil || discovered.isPartial || extra.isPartial || extraFiles.isPartial
        let uncertain = ambiguousRollouts.poll(
            candidates: discovered.ambiguousCandidates, ambiguousIDs: discovered.ambiguousIDs,
            uniqueFiles: files, previouslyObserved: previouslyObserved,
            sessionsDirectory: codexHome.appendingPathComponent("sessions", isDirectory: true),
            observedSince: observedSince
        )
        var recognizedUnindexedSource = false
        for session in sessions.values {
            let id = session.string("id")
            let title = session.string("thread_name")
            guard !id.isEmpty, title != "Guardian review", let file = files[id] else { continue }
            let fresh = uncertain.freshStarts[id]
            let recovered = fresh == nil ? uncertain.recovered[id] : nil
            if uncertain.protects(id) && fresh == nil {
                result.isPartial = true
                continue
            }
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard let modified = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            if let recovered {
                guard recovered.path == file.standardizedFileURL.path,
                      (attributes[.systemNumber] as? NSNumber)?.uint64Value == recovered.device,
                      (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == recovered.inode else {
                    result.isPartial = true
                    continue
                }
            }
            if let fresh {
                guard fresh.path == file.standardizedFileURL.path,
                      (attributes[.systemNumber] as? NSNumber)?.uint64Value == fresh.device,
                      (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == fresh.inode,
                      (attributes[.size] as? NSNumber)?.uint64Value == fresh.size else {
                    result.isPartial = true
                    continue
                }
            }
            if let observedSince, modified < observedSince && !previouslyObserved.contains(id) { continue }
            let tailLimit = 4_194_304
            let tail: String
            if let fresh {
                guard let checked = try Self.freshTail(of: file, proof: fresh, maximumBytes: tailLimit) else {
                    result.isPartial = true
                    continue
                }
                tail = checked
            } else {
                tail = try FileHelpers.tail(of: file, maximumBytes: tailLimit)
            }
            let cached = try? lifecycleCache.previous(for: file, attributes: attributes, maximumAppend: UInt64(tailLimit))
            if recovered != nil && cached == nil {
                result.isPartial = true
                continue
            }
            var historyKnown = cached?.scannedPrior == true || cached?.state.sawStart == true || cached?.state.running == true
            var state = CodexLifecycleState.parse(tail, seed: cached?.state)
            let currentSince = previouslyObserved.contains(id) ? nil : observedSince
            let freshEvent = currentSince.map { since in state.latestEvent.map { $0 >= since } ?? false } ?? true
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            if !historyKnown && !state.sawStart && size > UInt64(tailLimit) && freshEvent {
                if let prior = try CodexLifecycleState.previous(in: file) {
                    state = CodexLifecycleState.parse(tail, seed: prior)
                }
                historyKnown = true
            }
            if state.sawStart { historyKnown = true }
            try? lifecycleCache.store(for: file, attributes: attributes, state: state, scannedPrior: historyKnown)
            if let fresh, (state.terminal || !state.running || state.turnID != fresh.turnID) {
                result.isPartial = true
                continue
            }
            if state.terminal {
                // A terminal belongs to this card only when the complete
                // tail contains a matching start and a non-error ending.
                guard !state.terminalUncertain, tail.utf8.last == 0x0a,
                      let interrupted = Self.recoveredTerminal(in: tail, id: id, turn: state.turnID) else {
                    result.isPartial = true
                    continue
                }
                var recognized = false
                if let observedSince {
                    if let ended = state.terminalDate, ended >= observedSince { recognized = true }
                } else {
                    recognized = true
                }
                if recognized {
                    guard let identity = TerminalFileIdentity(attributes) else {
                        result.isPartial = true
                        continue
                    }
                    var events: [CodexToolEvent]?
                    if previouslyObserved.contains(id), let observedSince {
                        events = CodexToolEventParser.parse(tail: tail, since: observedSince, now: now)
                    }
                    indexedEndings[id] = (file, identity, interrupted, events)
                }
                continue
            }
            guard state.isRunning(observedSince: currentSince) else { continue }
            if let recovered, state.turnID != recovered.turnID {
                guard Self.hasRecoveredStart(in: tail, id: id, turn: state.turnID),
                      let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                      ambiguousRollouts.updateRecovered(id, previous: recovered, current: CodexRolloutHint(
                        path: file.standardizedFileURL.path, device: device, inode: inode, size: size,
                        modified: modified, turnID: state.turnID
                      )) else {
                    result.isPartial = true
                    continue
                }
            }
            if let observedSince {
                result.toolEvents[id] = CodexToolEventParser.parse(tail: tail, since: observedSince, now: now)
            }

            let plan = try planCache.read(from: file)
            if let fresh, !ambiguousRollouts.acceptFresh(id, hint: fresh) {
                result.isPartial = true
                continue
            }
            let steps = plan.steps
            let activity = parseActivity(from: tail, sessionID: id)
            // Matching a new start to the previously observed file establishes
            // its provenance, not whether the turn is still running now.
            if state.terminalUncertain || tail.utf8.last != 0x0a { result.isPartial = true }
            let recoveredUnconfirmed = fresh != nil || recovered != nil || state.terminalUncertain || tail.utf8.last != 0x0a
            let progress = recoveredUnconfirmed ? nil : MonitoredTask.progress(for: steps)
            let unconfirmed = recoveredUnconfirmed || now.timeIntervalSince(modified) >= 7_200
            var displayTitle = title
            if displayTitle.isEmpty, let record = try? readUnindexedSession(file, id: id),
               let derived = subagentTitle(record.subagent, sessions: sessions) {
                displayTitle = derived
            }
            if !state.turnID.isEmpty,
               let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
               let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value {
                ambiguousRollouts.noteKnown(id, hint: CodexRolloutHint(
                    path: file.standardizedFileURL.path, device: device, inode: inode, size: size,
                    modified: modified, turnID: state.turnID
                ))
            }
            result.tasks.append(MonitoredTask(
                id: id,
                provider: .codex,
                title: displayTitle.isEmpty ? tr("Задача Codex", "Codex task") : displayTitle,
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : (activity.isEmpty ? tr("Выполняется", "Working") : activity),
                isActive: !unconfirmed,
                progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps,
                updatedAt: modified,
                isUnconfirmed: unconfirmed,
                startedAt: state.startedAt ?? .distantPast,
                startKey: state.startKey,
                planConfirmed: !recoveredUnconfirmed && plan.confirmed,
                lastKnownActivity: activity.isEmpty ? nil : activity
            ))
            visibleMetadataStamps[id] = CodexSubagentMetadataWorker.Stamp(attributes)
        }
        if !indexedEndings.isEmpty {
            beforeTerminalRecheckForTests?()
            do {
                // One bounded rescan narrows, but cannot eliminate, a race
                // with another rollout appearing after this verification.
                let checked = try sessionFiles(for: Set(indexedEndings.keys), now: now, observedSince: observedSince,
                                               previouslyObserved: previouslyObserved, maximumVisited: 256)
                if checked.didHitLimit { result.isPartial = true }
                for (id, ending) in indexedEndings {
                    guard !checked.didHitLimit, !checked.ambiguousIDs.contains(id),
                          checked.files[id]?.standardizedFileURL == ending.file.standardizedFileURL,
                          let currentAttributes = try? fileManager.attributesOfItem(atPath: ending.file.path),
                          TerminalFileIdentity(currentAttributes) == ending.identity else {
                        result.isPartial = true
                        continue
                    }
                    result.terminalIDs.insert(id)
                    if ending.interrupted { result.interruptedIDs.insert(id) }
                    if let events = ending.toolEvents { result.toolEvents[id] = events }
                }
            } catch {
                result.isPartial = true
            }
        }
        // During a revert, older rollouts can coexist with the new one. New
        // complete records are evidence of a write, not proof of the selected
        // history or of a task's current state. Never emit terminal IDs or
        // progress from this fallback.
        for (id, hint) in uncertain.hints where !previouslyObserved.contains(id) {
            guard let session = sessions[id], session.string("thread_name") != "Guardian review" else { continue }
            let title = session.string("thread_name")
            result.tasks.append(MonitoredTask(
                id: id, provider: .codex,
                title: title.isEmpty ? tr("Задача Codex", "Codex task") : title,
                activity: tr("Статус не подтверждён", "Status unconfirmed"),
                isActive: false, progress: nil, progressKind: .none, steps: [],
                updatedAt: hint.modified, isUnconfirmed: true, planConfirmed: false
            ))
        }
        for id in extra.ids {
            let available = extraFiles.didHitLimit ? extra.fastFiles : extraFiles.files
            guard let file = available[id] else { continue }
            do {
                guard let record = try readUnindexedSession(file, id: id) else { continue }
                recognizedUnindexedSource = true
                var lateWithWriterFile = false
                if let observedSince, record.modified < observedSince && !previouslyObserved.contains(id) {
                    switch writerLockStatus(for: id) {
                    case .present: lateWithWriterFile = true
                    case .absent: continue
                    case .unknown: result.isPartial = true; continue
                    }
                }
                let state = CodexLifecycleState.parse(record.tail)
                // A bounded tail without its start cannot establish which turn a
                // later event belongs to. Keep the existing card uncertain.
                if record.truncated && !state.sawStart {
                    result.isPartial = true
                    continue
                }
                if state.terminal {
                    // A partial filename scan may have missed a competing
                    // rollout. Do not close a previously observed task then.
                    if extraFiles.didHitLimit {
                        // A completed turn is not the only possible rollout for
                        // this ID. Wait for the writer file to disappear and
                        // a full sweep to confirm the same previously seen file.
                        guard case .absent = writerLockStatus(for: id),
                              previouslyObserved.contains(id),
                              extra.verifiedFiles[id]?.standardizedFileURL == file.standardizedFileURL,
                              execDiscovery.matchesObserved(id: id, file: file, device: record.device,
                                                            inode: record.inode, startKey: state.startKey) else {
                            result.isPartial = true
                            continue
                        }
                    }
                    guard state.sawStart, !state.terminalUncertain, record.tail.utf8.last == 0x0a,
                          let interrupted = Self.recoveredTerminal(in: record.tail, id: id, turn: state.turnID) else {
                        result.isPartial = true
                        continue
                    }
                    let recognized = observedSince.map { since in
                        state.terminalDate.map { $0 >= since } ?? false
                    } ?? true
                    if recognized {
                        result.terminalIDs.insert(id)
                        if interrupted { result.interruptedIDs.insert(id) }
                        if previouslyObserved.contains(id), let observedSince {
                            result.toolEvents[id] = CodexToolEventParser.parse(tail: record.tail, since: observedSince, now: now)
                        }
                    }
                    continue
                }
                let currentSince = (previouslyObserved.contains(id) || lateWithWriterFile) ? nil : observedSince
                guard state.isRunning(observedSince: currentSince) else { continue }
                if let observedSince {
                    result.toolEvents[id] = CodexToolEventParser.parse(tail: record.tail, since: observedSince, now: now)
                }
                let plan = CodexPlanParser.parse(record.tail)
                let steps = plan.steps
                let detail = parseActivity(from: record.tail, sessionID: id)
                let status = tr("Статус не подтверждён", "Status unconfirmed")
                execDiscovery.remember(id: id, file: file, device: record.device, inode: record.inode,
                                       startKey: state.startKey)
                result.tasks.append(MonitoredTask(
                    id: id,
                    provider: .codex,
                    title: subagentTitle(record.subagent, sessions: sessions) ?? tr("Задача Codex", "Codex task"),
                    activity: detail.isEmpty ? status : status + ": " + detail,
                    isActive: false,
                    progress: nil,
                    progressKind: .none,
                    steps: steps,
                    updatedAt: record.modified,
                    isUnconfirmed: true,
                    startedAt: state.startedAt ?? .distantPast,
                    startKey: state.startKey,
                    planConfirmed: plan.confirmed,
                    lastKnownActivity: detail.isEmpty ? nil : detail
                ))
                if let attributes = try? fileManager.attributesOfItem(atPath: file.path) {
                    visibleMetadataStamps[id] = CodexSubagentMetadataWorker.Stamp(attributes)
                }
            } catch {
                // A changing, inaccessible or linked file is not evidence that
                // a previously observed task finished.
                result.isPartial = true
            }
        }
        if let indexFailure, !recognizedUnindexedSource { throw indexFailure }
        var metadataCandidates = files
        if !extraFiles.didHitLimit {
            metadataCandidates.merge(extraFiles.files) { first, _ in first }
        } else {
            // A completed bounded history sweep may retain a unique path for
            // a previously observed unindexed session. It is usable only
            // while the current fast path and file identity still match.
            for (id, file) in extra.verifiedFiles {
                guard extra.fastFiles[id]?.standardizedFileURL == file.standardizedFileURL,
                      let stamp = visibleMetadataStamps[id],
                      execDiscovery.matchesVerified(id: id, file: file, device: stamp.device, inode: stamp.inode) else { continue }
                metadataCandidates[id] = file
            }
        }
        let visibleIDs = Set(result.tasks.map(\.id).filter { UUID(uuidString: $0) != nil })
        result.subagentCandidates = visibleIDs
        let metadata = subagentMetadata.poll(candidates: metadataCandidates, visibleIDs: visibleIDs) { id, file in
            let before = try self.fileManager.attributesOfItem(atPath: file.path)
            guard let stamp = CodexSubagentMetadataWorker.Stamp(before) else { throw CocoaError(.fileReadUnknown) }
            let metadata = try self.readSubagentParent(file, id: id)
            let after = try self.fileManager.attributesOfItem(atPath: file.path)
            guard let current = CodexSubagentMetadataWorker.Stamp(after),
                  current.device == stamp.device, current.inode == stamp.inode,
                  current.size >= stamp.size, current.modified >= stamp.modified,
                  metadata.device == current.device, metadata.inode == current.inode,
                  metadata.size <= current.size else { throw CocoaError(.fileReadUnknown) }
            return CodexSubagentMetadataWorker.Observation(file: file, stamp: current,
                                                           parentID: metadata.parentID, headerDigest: metadata.headerDigest)
        }
        var verifiedMetadata: Set<String> = []
        var checkedAncestors = 0
        for id in metadata.keys.sorted() {
            guard let observation = metadata[id] else { continue }
            let current: CodexSubagentMetadataWorker.Stamp?
            if visibleIDs.contains(id) {
                current = visibleMetadataStamps[id]
            } else {
                guard checkedAncestors < 32 else { result.isPartial = true; continue }
                checkedAncestors += 1
                current = (try? fileManager.attributesOfItem(atPath: observation.file.path))
                    .flatMap { CodexSubagentMetadataWorker.Stamp($0) }
            }
            guard let current else { continue }
            let checked = current == observation.stamp
            // While an append is being rechecked, preserve a recently verified
            // header on the same file. A concurrent rewrite can only be
            // detected when the background header read finishes.
            let appending = current.device == observation.stamp.device && current.inode == observation.stamp.inode &&
                current.size > observation.stamp.size && current.modified >= observation.stamp.modified &&
                ProcessInfo.processInfo.systemUptime - observation.observedAt <= 10
            guard checked || appending else { continue }
            verifiedMetadata.insert(id)
            if let parent = observation.parentID { result.subagentParents[id] = parent }
        }
        // Pending metadata alone does not make the separately visible tasks
        // unavailable. Once a relationship is used, disclose incomplete
        // metadata coverage for the other visible tasks.
        if !result.subagentParents.isEmpty && !visibleIDs.subtracting(verifiedMetadata).isEmpty {
            result.isPartial = true
        }
        for parent in Set(result.subagentParents.values) {
            guard let title = sessions[parent]?.string("thread_name"),
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title != "Guardian review" else { continue }
            result.subagentTitles[parent] = title
        }
        result.tasks.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    func isRunning(tail: String, observedSince: Date? = nil) -> Bool {
        CodexLifecycleState.parse(tail).isRunning(observedSince: observedSince)
    }

    /// Compare the raw filesystem timestamp, not two independently rounded
    /// Date representations, and read the same file descriptor that was checked.
    private static func freshTail(of url: URL, proof: CodexRolloutHint, maximumBytes: Int) throws -> String? {
        guard let seconds = proof.modifiedSeconds, let nanoseconds = proof.modifiedNanoseconds else { return nil }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        func matches() -> Bool {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size >= 0 else { return false }
            return UInt64(bitPattern: Int64(info.st_dev)) == proof.device &&
                UInt64(info.st_ino) == proof.inode && UInt64(info.st_size) == proof.size &&
                Int64(info.st_mtimespec.tv_sec) == seconds && Int64(info.st_mtimespec.tv_nsec) == nanoseconds
        }
        guard matches() else { return nil }
        let count = Int(min(proof.size, UInt64(maximumBytes)))
        try handle.seek(toOffset: proof.size - UInt64(count))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count, matches() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// A recovered card can close only on a terminal for the same visible
    /// turn. Missing IDs and error completions are not successful finishes.
    private static func recoveredTerminal(in tail: String, id: String, turn: String) -> Bool? {
        guard !turn.isEmpty else { return nil }
        var current = ""
        var terminal: Bool?
        var sawTerminal = false
        var inconsistent = false
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else {
                if !current.isEmpty { current = ""; terminal = nil }
                continue
            }
            guard record.string("type") == "event_msg" else { continue }
            if let thread = payload["thread_id"], (thread as? String) != id {
                current = ""; terminal = nil
                continue
            }
            let kind = payload.string("type")
            let eventTurn = payload.string("turn_id")
            if ["task_started", "turn_started"].contains(kind) {
                if eventTurn == turn && sawTerminal {
                    inconsistent = true
                } else if eventTurn != turn {
                    sawTerminal = false
                    inconsistent = false
                }
                current = FileHelpers.isoDate(record["timestamp"]) == nil ? "" : eventTurn
                terminal = nil
            } else if ["task_complete", "turn_complete", "turn_aborted"].contains(kind),
                      current == turn, eventTurn == turn,
                      FileHelpers.isoDate(record["timestamp"]) != nil {
                let hasError = payload["error"] != nil && !(payload["error"] is NSNull)
                let outcome: Bool? = hasError ? nil : (kind == "turn_aborted")
                if sawTerminal && (outcome == nil || terminal != outcome) { inconsistent = true }
                if outcome == nil { inconsistent = true }
                sawTerminal = true
                terminal = outcome
            }
        }
        return inconsistent ? nil : terminal
    }

    private static func hasRecoveredStart(in tail: String, id: String, turn: String) -> Bool {
        guard !turn.isEmpty else { return false }
        var current = ""
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else {
                if !current.isEmpty { current = "" }
                continue
            }
            guard record.string("type") == "event_msg" else { continue }
            if let thread = payload["thread_id"], (thread as? String) != id { current = ""; continue }
            let kind = payload.string("type")
            if ["task_started", "turn_started"].contains(kind) {
                current = FileHelpers.isoDate(record["timestamp"]) == nil ? "" : payload.string("turn_id")
            } else if ["task_complete", "turn_complete", "turn_aborted"].contains(kind),
                      payload.string("turn_id").isEmpty || payload.string("turn_id") == current {
                current = ""
            }
        }
        return current == turn
    }

    func parsePlan(from tail: String) -> [TaskStep] {
        CodexPlanParser.parse(tail).steps
    }

    func parseActivity(from tail: String, sessionID: String? = nil) -> String {
        func decodedJSONContains(_ line: Substring, _ value: String) -> Bool {
            guard line.contains("\\u"), let record = FileHelpers.jsonObject(line) else { return false }
            var pending: [Any] = [record]
            var visited = 0
            while let item = pending.popLast() {
                visited += 1
                // If the decoded structure is unexpectedly large, fail closed.
                if visited > 100_000 || pending.count > 100_000 { return true }
                if let text = item as? String {
                    if text.contains(value) { return true }
                } else if let object = item as? [String: Any] {
                    if object.keys.contains(where: { $0.contains(value) }) { return true }
                    pending.append(contentsOf: object.values)
                } else if let array = item as? [Any] {
                    pending.append(contentsOf: array)
                }
            }
            return false
        }

        var latestSummary = ""
        var latestCommentary = ""
        var latestSummaryIndex = -1
        var latestCommentaryIndex = -1
        var latestOtherItemIndex = -1
        var latestFigma: (description: String, index: Int)?
        var seenFigmaIDs: Set<String> = []
        var completedFigmaDescriptions: [String: String] = [:]
        var figmaTrackingReliable = true
        var turnID = ""
        var hasVisibleTurnStart = false
        var turnStartIndex: Int?
        var activeCalls: [String: (title: String, order: Int)] = [:]
        var seenCallIDs: Set<String> = []
        var callOrder = 0
        var callTrackingReliable = true
        let lines = tail.split(whereSeparator: \.isNewline)
        let activeWindowStart = max(0, lines.count - 512)
        for (lineIndex, line) in lines.enumerated() {
            guard line.utf8.count <= 1_048_576,
                  let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else {
                if hasVisibleTurnStart {
                    activeCalls.removeAll()
                    callTrackingReliable = false
                }
                continue
            }
            let recordType = record.string("type")
            let kind = payload.string("type")
            let eventTurnID = payload.string("turn_id")
            let eventThreadID = payload.string("thread_id")
            if let sessionID, !eventThreadID.isEmpty, eventThreadID != sessionID { continue }
            if recordType == "event_msg", ["task_started", "turn_started"].contains(kind) {
                turnID = eventTurnID
                latestSummary = ""
                latestCommentary = ""
                latestSummaryIndex = -1
                latestCommentaryIndex = -1
                latestOtherItemIndex = -1
                latestFigma = nil
                seenFigmaIDs.removeAll()
                completedFigmaDescriptions.removeAll()
                figmaTrackingReliable = true
                hasVisibleTurnStart = !eventTurnID.isEmpty
                turnStartIndex = hasVisibleTurnStart ? lineIndex : nil
                activeCalls.removeAll()
                seenCallIDs.removeAll()
                callOrder = 0
                callTrackingReliable = true
                continue
            }
            if !turnID.isEmpty && !eventTurnID.isEmpty && turnID != eventTurnID { continue }
            if recordType == "event_msg", ["task_complete", "turn_complete", "turn_aborted"].contains(kind) {
                hasVisibleTurnStart = false
                turnStartIndex = nil
                activeCalls.removeAll()
                seenCallIDs.removeAll()
                latestFigma = nil
                seenFigmaIDs.removeAll()
                completedFigmaDescriptions.removeAll()
                continue
            }
            if hasVisibleTurnStart && callTrackingReliable && figmaTrackingReliable,
               recordType == "event_msg", kind == "item_completed",
               let sessionID, !sessionID.isEmpty {
                let item = payload.object("item")
                let itemType = item?.string("type") ?? ""
                var duplicateFigma = false
                let matches = eventThreadID == sessionID && eventTurnID == turnID
                let couldMatch = (eventThreadID.isEmpty || eventThreadID == sessionID) &&
                                 (eventTurnID.isEmpty || eventTurnID == turnID)
                if matches, let item, itemType == "McpToolCall", item.string("server") == "codex_apps",
                   item.string("tool") == "figma.use_figma" {
                    let id = item.string("id")
                    let bytes = id.utf8
                    let validID = !bytes.isEmpty && bytes.count <= 256 && bytes.allSatisfy {
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                    }
                    var description = ""
                    if let rawDescription = item.object("arguments")?["description"] as? String,
                       rawDescription.utf16.count <= 4_096 {
                        description = FileHelpers.normalized(rawDescription, limit: 4_096)
                    }
                    let result = item.object("result")
                    let errorFlag = result?["isError"]
                    let successfulResult = (item["result"] == nil || result != nil) &&
                                           (errorFlag == nil || (errorFlag as? Bool) == false)
                    let completed = item.string("status") == "completed" &&
                                    (item["error"] == nil || item["error"] is NSNull) && successfulResult && !description.isEmpty
                    if validID {
                        let firstRecord = seenFigmaIDs.insert(id).inserted
                        if seenFigmaIDs.count > 4_096 {
                            figmaTrackingReliable = false
                            latestFigma = nil
                        } else if firstRecord && completed {
                            completedFigmaDescriptions[id] = description
                            latestFigma = (description, lineIndex)
                        } else if !firstRecord && completed && completedFigmaDescriptions[id] == description {
                            duplicateFigma = true
                        }
                    }
                }
                if couldMatch && !duplicateFigma &&
                   (!matches || (itemType != "Reasoning" && itemType != "AgentMessage")) {
                    latestOtherItemIndex = lineIndex
                }
            }
            if hasVisibleTurnStart && callTrackingReliable && recordType == "response_item" {
                let callID = payload.string("call_id")
                let candidateBytes = callID.utf8
                let candidateIDAllowed = !candidateBytes.isEmpty && candidateBytes.count <= 256 && candidateBytes.allSatisfy {
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                }
                if lineIndex < activeWindowStart {
                    if kind == "function_call_output" && (callID.isEmpty || callID.utf8.count > 256) {
                        activeCalls.removeAll()
                        callTrackingReliable = false
                    }
                } else if kind == "function_call_output" {
                    if callID.isEmpty || callID.utf8.count > 256 {
                        activeCalls.removeAll()
                        callTrackingReliable = false
                    } else {
                        activeCalls.removeValue(forKey: callID)
                        seenCallIDs.insert(callID)
                    }
                } else if kind == "function_call", payload.string("namespace") == "mcp__cua_repl",
                          payload.string("name") == "js", candidateIDAllowed,
                          !seenCallIDs.contains(callID) {
                    seenCallIDs.insert(callID)
                    let arguments = payload.string("arguments")
                    if arguments.utf8.count <= 1_048_576,
                       let fields = FileHelpers.jsonObject(Substring(arguments)),
                       let rawTitle = fields["title"] as? String,
                       rawTitle.utf16.count <= 4_096 {
                        let title = FileHelpers.normalized(rawTitle, limit: 4_096)
                        if !title.isEmpty {
                            callOrder += 1
                            activeCalls[callID] = (title, callOrder)
                        }
                    }
                }
                if seenCallIDs.count > 4_096 {
                    activeCalls.removeAll()
                    callTrackingReliable = false
                }
            }
            var summary = ""
            if recordType == "event_msg", kind == "agent_reasoning" {
                summary = payload.string("text")
            } else if recordType == "response_item", kind == "reasoning" {
                for part in payload.array("summary") where part.string("type") == "summary_text" {
                    let text = part.string("text")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = text }
                }
            } else if recordType == "event_msg", kind == "agent_message", payload.string("phase") == "commentary" {
                let message = payload.string("message")
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestCommentary = message
                    latestCommentaryIndex = lineIndex
                }
            } else if recordType == "response_item", kind == "message", payload.string("phase") == "commentary",
                      payload.string("role") == "assistant" {
                for part in payload.array("content") where part.string("type") == "output_text" {
                    let text = part.string("text")
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        latestCommentary = text
                        latestCommentaryIndex = lineIndex
                    }
                }
            } else if kind == "item_completed", let item = payload.object("item") {
                if let sessionID, !sessionID.isEmpty,
                   (eventThreadID != sessionID || eventTurnID != turnID || turnID.isEmpty) { continue }
                if item.string("type") == "Reasoning" {
                    for part in (item["summary_text"] as? [String] ?? []) where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { summary = part }
                } else if item.string("type") == "AgentMessage", item.string("phase") == "commentary" {
                    for part in item.array("content") where part.string("type") == "Text" {
                        let text = part.string("text")
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            latestCommentary = text
                            latestCommentaryIndex = lineIndex
                        }
                    }
                }
            }
            if !summary.isEmpty {
                let firstLine = summary.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                var extracted = firstLine
                if firstLine.hasPrefix("**") {
                    let remainder = firstLine.dropFirst(2)
                    if let end = remainder.range(of: "**") { extracted = String(remainder[..<end.lowerBound]) }
                }
                if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    latestSummary = extracted
                    latestSummaryIndex = lineIndex
                }
            }
        }
        if hasVisibleTurnStart && callTrackingReliable, let turnStartIndex {
            let earlierStart = min(turnStartIndex + 1, activeWindowStart)
            let earlierLines = lines[earlierStart..<activeWindowStart]
            for (callID, active) in activeCalls.sorted(by: { $0.value.order > $1.value.order }) {
                let seenEarlier = earlierLines.contains { line in
                    line.contains(callID) || decodedJSONContains(line, callID)
                }
                if !seenEarlier { return active.title }
            }
        }
        if hasVisibleTurnStart && callTrackingReliable && figmaTrackingReliable, let latestFigma,
           latestFigma.index > max(latestSummaryIndex, latestCommentaryIndex),
           latestFigma.index >= latestOtherItemIndex {
            return tr("Последнее действие в Figma: ", "Last Figma action: ") + latestFigma.description
        }
        let latestText = latestCommentaryIndex > latestSummaryIndex ? latestCommentary : latestSummary
        return FileHelpers.normalized(latestText, limit: 600)
    }

    // A supported timestamped basename is exactly the form emitted by the
    // pinned upstream writer. Parsing the whole basename prevents a short ID
    // from claiming a longer identifier merely because their suffixes match.
    fileprivate static func canonicalOwner(in stem: String) -> String? {
        let bytes = Array(stem.utf8)
        let prefix = Array("rollout-".utf8)
        guard bytes.starts(with: prefix), bytes.count >= prefix.count + 20 else { return nil }
        let stamp = Array(bytes[prefix.count..<(prefix.count + 19)])
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 45, 16: 45]
        for index in 0..<19 {
            if let separator = separators[index] {
                guard stamp[index] == separator else { return nil }
            } else {
                guard (48...57).contains(stamp[index]) else { return nil }
            }
        }
        guard bytes[prefix.count + 19] == 45 else { return nil }
        func value(_ range: Range<Int>) -> Int {
            stamp[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = value(0..<4), month = value(5..<7), day = value(8..<10)
        let hour = value(11..<13), minute = value(14..<16), second = value(17..<19)
        guard year >= 1, (1...12).contains(month), hour <= 23, minute <= 59, second <= 59 else { return nil }
        let leap = year % 400 == 0 || (year % 4 == 0 && year % 100 != 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day >= 1 && day <= days[month - 1] else { return nil }
        let encoded = String(decoding: bytes[(prefix.count + 20)...], as: UTF8.self)
        let parts = encoded.split(separator: "_", omittingEmptySubsequences: false)
        guard (parts.count == 1 || parts.count == 2), parts.allSatisfy({ part in
            part.utf8.count == 36 && UUID(uuidString: String(part)) != nil
        }) else { return nil }
        return String(parts[0])
    }

    private static func pathIsMissing(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) != 0 && errno == ENOENT
    }

    /// Each refresh examines at most 256 recent-day entries and 256 entries
    /// from a progressing history scan. Partial scans do not claim completeness.
    private func unindexedOwners(excluding indexedIDs: Set<String>, now: Date, observedSince: Date?,
                                 previouslyObserved: Set<String>) throws -> (ids: Set<String>, fastFiles: [String: URL], verifiedFiles: [String: URL], isPartial: Bool) {
        let directory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        if Self.pathIsMissing(directory) { return ([], [:], [:], false) }
        let excluded = Set(indexedIDs.map { $0.lowercased() })
        var modifiedByOwner: [String: Date] = [:]
        var fastVariants: [String: [String: URL]] = [:]
        var unknownStems: [String] = []
        var partial = false
        var fastComplete = true

        func consider(_ url: URL, fast: Bool) {
            let name = url.lastPathComponent
            let suffix: String
            if name.hasSuffix(".jsonl.zst") { suffix = ".jsonl.zst" }
            else if name.hasSuffix(".jsonl") { suffix = ".jsonl" }
            else { return }
            let stem = String(name.dropLast(suffix.count))
            guard let owner = Self.canonicalOwner(in: stem) else {
                unknownStems.append(stem.lowercased())
                return
            }
            guard !excluded.contains(owner.lowercased()) else { return }
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else {
                partial = true
                return
            }
            if let observedSince, !previouslyObserved.contains(owner), modified < observedSince {
                switch writerLockStatus(for: owner) {
                case .present: break
                case .absent: return
                case .unknown: partial = true; return
                }
            }
            if modifiedByOwner[owner].map({ modified > $0 }) ?? true { modifiedByOwner[owner] = modified }
            if fast { fastVariants[owner, default: [:]][url.standardizedFileURL.path] = url }
        }

        // Previously verified paths let an ongoing task survive across dates
        // without rereading its owner's entire history on every refresh.
        for (_, file) in execDiscovery.files(for: previouslyObserved) { consider(file, fast: true) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var recentVisited = 0
        for offset in [0, -1, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let subpath = String(format: "%04d/%02d/%02d", year, month, date)
            let recent = directory.appendingPathComponent(subpath, isDirectory: true)
            if Self.pathIsMissing(recent) { continue }
            var recentError: Error?
            guard let enumerator = fileManager.enumerator(at: recent, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles], errorHandler: { _, error in recentError = error; return false }) else {
                partial = true
                fastComplete = false
                continue
            }
            for case let url as URL in enumerator {
                recentVisited += 1
                if recentVisited > 256 { partial = true; fastComplete = false; break }
                consider(url, fast: true)
            }
            if recentError != nil { partial = true; fastComplete = false }
            if !fastComplete { break }
        }

        let page = try execDiscovery.nextHistoryPage(directory: directory, limit: 256, previouslyObserved: previouslyObserved)
        if !page.complete { partial = true }
        for url in page.urls { consider(url, fast: true) }
        let ordered = modifiedByOwner.sorted { first, second in
            let firstObserved = previouslyObserved.contains(first.key)
            let secondObserved = previouslyObserved.contains(second.key)
            if firstObserved != secondObserved { return firstObserved }
            if first.value != second.value { return first.value > second.value }
            return first.key < second.key
        }
        if ordered.count > 16 { partial = true }
        let selected = Set(ordered.prefix(16).map(\.key))
        var fastFiles: [String: URL] = [:]
        // A partial page can yield a verified session record, but only as an
        // unconfirmed card. Terminal events still require a complete scan.
        do {
            for id in selected {
                let lowerID = id.lowercased()
                if unknownStems.contains(where: { $0 == lowerID || $0.hasSuffix("-" + lowerID) || $0.contains("-" + lowerID + "_") }) {
                    partial = true
                    continue
                }
                let variants = Array(fastVariants[id, default: [:]].values)
                let plainPaths = Set(variants.filter { !$0.lastPathComponent.hasSuffix(".zst") }.map { $0.standardizedFileURL.path })
                let distinct = variants.filter { file in
                    guard file.lastPathComponent.hasSuffix(".jsonl.zst") else { return true }
                    return !plainPaths.contains(String(file.standardizedFileURL.path.dropLast(4)))
                }
                guard distinct.count == 1, let file = distinct.first,
                      !file.lastPathComponent.hasSuffix(".jsonl.zst") else {
                    if !distinct.isEmpty { partial = true }
                    continue
                }
                fastFiles[id] = file
            }
        }
        return (selected, fastFiles, page.verifiedFiles, partial)
    }

    private enum WriterLockStatus {
        case present, absent, unknown
    }

    /// Check only lock-file metadata, without opening or taking its lock.
    private func writerLockStatus(for id: String) -> WriterLockStatus {
        let directory = codexHome.appendingPathComponent("thread-writer-locks", isDirectory: true).path
        let parent = directory.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parent >= 0 else { return errno == ENOENT ? .absent : .unknown }
        defer { Darwin.close(parent) }
        var info = stat()
        let result = (id + ".lock").withCString { fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { return errno == ENOENT ? .absent : .unknown }
        return (info.st_mode & S_IFMT) == S_IFREG ? .present : .unknown
    }

    private struct SubagentReference {
        let parentID: String
        let nickname: String?
    }

    private struct UnindexedSessionRecord {
        var tail: String
        var modified: Date
        var truncated: Bool
        var device: UInt64
        var inode: UInt64
        var subagent: SubagentReference?
    }

    private func subagentReference(_ payload: [String: Any], id: String) -> SubagentReference? {
        guard id.utf8.count == 36, UUID(uuidString: id) != nil,
              let source = payload.object("source"), let subagent = source.object("subagent"),
              let spawn = subagent.object("thread_spawn") else { return nil }
        let parentID = payload.string("parent_thread_id")
        guard parentID.utf8.count == 36, UUID(uuidString: parentID) != nil,
              parentID == spawn.string("parent_thread_id"), parentID.lowercased() != id.lowercased() else { return nil }
        let path = payload.string("agent_path")
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 1_024, path == spawn.string("agent_path"),
              parts.count >= 3, parts[0].isEmpty, parts[1] == "root",
              parts.dropFirst(2).allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
                  }
              }) else { return nil }
        let outerName = payload.string("agent_nickname")
        let innerName = spawn.string("agent_nickname")
        let trimmed = outerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nickname: String?
        if Array(outerName.utf8) == Array(innerName.utf8), !trimmed.isEmpty, trimmed.utf16.count <= 256,
           !outerName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            nickname = trimmed
        } else {
            nickname = nil
        }
        return SubagentReference(parentID: parentID, nickname: nickname)
    }

    private func subagentTitle(_ reference: SubagentReference?, sessions: [String: [String: Any]]) -> String? {
        guard let reference, let nickname = reference.nickname, let parent = sessions[reference.parentID] else { return nil }
        let title = parent.string("thread_name")
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != "Guardian review" else { return nil }
        return title + " " + tr("(агент \(nickname))", "(agent \(nickname))")
    }

    /// Open only regular files beneath the sessions directory without following
    /// links in any enumerated component.
    private func openSessionFile(_ url: URL) throws -> Int32 {
        let directory = codexHome.appendingPathComponent("sessions", isDirectory: true).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(directory + "/") else { throw CocoaError(.fileReadUnknown) }
        let relative = path.dropFirst(directory.count + 1)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 16,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var parent = directory.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parent >= 0 else { throw CocoaError(.fileReadUnknown) }
        for component in components.dropLast() {
            let next = String(component).withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            Darwin.close(parent)
            guard next >= 0 else { throw CocoaError(.fileReadUnknown) }
            parent = next
        }
        let descriptor = String(components.last!).withCString { openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        Darwin.close(parent)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw CocoaError(.fileReadUnknown)
        }
        return descriptor
    }

    private func readSubagentParent(_ url: URL, id: String) throws -> (parentID: String?, device: UInt64, inode: UInt64, size: UInt64, headerDigest: Data) {
        let descriptor = try openSessionFile(url)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_size >= 0 else { throw CocoaError(.fileReadUnknown) }
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        guard let newline = prefix.firstIndex(of: 0x0a),
              CodexUniqueJSONKeys.accepts(Data(prefix[..<newline])),
              let header = try? JSONSerialization.jsonObject(with: Data(prefix[..<newline])) as? [String: Any],
              header.string("type") == "session_meta", let payload = header.object("payload"),
              payload.string("id") == id else { throw CocoaError(.fileReadCorruptFile) }
        let originalHeader = Data(prefix[...newline])
        try handle.seek(toOffset: 0)
        guard try handle.read(upToCount: originalHeader.count) == originalHeader else { throw CocoaError(.fileReadUnknown) }
        var after = stat()
        guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_size >= before.st_size else { throw CocoaError(.fileReadUnknown) }
        return (subagentReference(payload, id: id)?.parentID,
                UInt64(bitPattern: Int64(after.st_dev)), UInt64(after.st_ino), UInt64(after.st_size),
                Data(SHA256.hash(data: originalHeader)))
    }

    /// A live session keeps writing the same descriptor while this bounded
    /// snapshot is read.
    private func readUnindexedSession(_ url: URL, id: String) throws -> UnindexedSessionRecord? {
        let descriptor = try openSessionFile(url)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        guard let newline = prefix.firstIndex(of: 0x0a),
              let header = try? JSONSerialization.jsonObject(with: Data(prefix[..<newline])) as? [String: Any],
              header.string("type") == "session_meta", let payload = header.object("payload") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard payload.string("id") == id else { return nil }
        let subagent = subagentReference(payload, id: id)
        guard ["exec", "vscode"].contains(payload.string("source")) || subagent != nil else { return nil }
        let end = try handle.seekToEnd()
        let count = min(end, UInt64(262_144))
        try handle.seek(toOffset: end - count)
        let bytes = try handle.read(upToCount: Int(count)) ?? Data()
        var info = stat()
        guard bytes.count == Int(count), fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                            Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return UnindexedSessionRecord(tail: String(decoding: bytes, as: UTF8.self), modified: modified,
                                      truncated: end > count, device: UInt64(bitPattern: Int64(info.st_dev)),
                                      inode: UInt64(info.st_ino), subagent: subagent)
    }

    private func sessionFiles(for ids: Set<String>, now: Date, observedSince: Date?,
                              previouslyObserved: Set<String>, maximumVisited: Int? = nil) throws -> (files: [String: URL], ambiguousCandidates: [String: [URL]], ambiguousIDs: Set<String>, isPartial: Bool, didHitLimit: Bool) {
        guard !ids.isEmpty else { return ([:], [:], [], false, false) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadNoSuchFile) }
        let uuidIDs = ids.filter { $0.utf8.count == 36 && UUID(uuidString: $0) != nil }
        var files: [String: URL] = [:]
        var ambiguousCandidates: [String: [URL]] = [:]
        var candidates: [String: [URL]] = [:]
        var variants: [String: [String]] = [:]
        for id in uuidIDs { variants[id.lowercased(), default: []].append(id) }
        var ambiguous = Set(variants.values.filter { $0.count > 1 }.flatMap { $0 })
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            // Do not claim an unindexed task when a bounded scan cannot rule
            // out a second rollout or an ambiguous filename later in the tree.
            if let maximumVisited, visited > maximumVisited { return ([:], [:], [], true, true) }
            let file = url.lastPathComponent
            let compressed = file.hasSuffix(".jsonl.zst")
            let suffix = compressed ? ".jsonl.zst" : ".jsonl"
            guard file.hasSuffix(suffix) else { continue }
            let stem = String(file.dropLast(suffix.count))
            guard let owner = Self.canonicalOwner(in: stem) else {
                // An unrecognised name that might contain a known UUID must
                // not leave an older file eligible for a confirmed result.
                let lowerStem = stem.lowercased()
                for id in uuidIDs {
                    let lowerID = id.lowercased()
                    if lowerStem == lowerID || lowerStem.hasSuffix("-" + lowerID) || lowerStem.contains("-" + lowerID + "_") {
                        files.removeValue(forKey: id)
                        ambiguous.insert(id)
                    }
                }
                continue
            }
            guard let matching = variants[owner.lowercased()] else { continue }
            guard matching.count == 1 && matching[0] == owner else {
                for id in matching {
                    files.removeValue(forKey: id)
                    ambiguous.insert(id)
                }
                continue
            }
            candidates[owner, default: []].append(url)
        }
        if let enumerationError { throw enumerationError }
        for (owner, variantsForOwner) in candidates {
            if ambiguous.contains(owner) { continue }
            let plainPaths = Set(variantsForOwner.filter { !$0.lastPathComponent.hasSuffix(".zst") }
                .map { $0.standardizedFileURL.path })
            // Upstream prefers a plain file to its exact .zst sibling. Compare
            // full paths so equal basenames in different folders remain distinct.
            let distinct = variantsForOwner.filter { url in
                guard url.lastPathComponent.hasSuffix(".jsonl.zst") else { return true }
                let path = url.standardizedFileURL.path
                return !plainPaths.contains(String(path.dropLast(4)))
            }
            func predatesObservation(_ url: URL) -> Bool {
                guard let observedSince, !previouslyObserved.contains(owner),
                      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                      let modified = attributes[.modificationDate] as? Date,
                      modified < observedSince else { return false }
                if url.lastPathComponent.hasSuffix(".jsonl.zst") {
                    return now.timeIntervalSince(modified) >= 7 * 24 * 60 * 60
                }
                return true
            }
            guard distinct.count == 1, let chosen = distinct.first else {
                // Baseline even cold histories, so one later event can be
                // observed without treating old records as new activity.
                if maximumVisited == nil { ambiguousCandidates[owner] = distinct }
                // Entirely old histories that have never been observed do not
                // imply an active ambiguity. Check every variant first.
                if !distinct.isEmpty && distinct.allSatisfy(predatesObservation) { continue }
                ambiguous.insert(owner)
                continue
            }
            if chosen.lastPathComponent.hasSuffix(".jsonl.zst") {
                // A single old compressed history predating observation is not
                // a live task. Fresh, observed or unreadable histories remain
                // visibly uncertain until a plain rollout is available.
                guard predatesObservation(chosen) else {
                    ambiguous.insert(owner)
                    continue
                }
                continue
            }
            files[owner] = chosen
        }
        return (files, ambiguousCandidates, ambiguous, !ambiguous.isEmpty || uuidIDs.count != ids.count, false)
    }

}

/// Small in-memory cache for paths that were already validated as unindexed
/// rollouts. It never writes the Codex index or stores session contents.
final class CodexExecDiscoveryCache {
    private final class EnumerationErrors {
        var value: Error?
    }

    private struct Observation: Equatable {
        var file: URL
        var device: UInt64
        var inode: UInt64
        var startKey: String
    }

    private let lock = NSLock()
    private var seenIndex = false
    private var observations: [String: Observation] = [:]
    private var order: [String] = []
    private var historyPath = ""
    private var historyDevice: UInt64?
    private var historyInode: UInt64?
    private var historyEnumerator: FileManager.DirectoryEnumerator?
    private var historyErrors: EnumerationErrors?
    private var sweepTargets: Set<String> = []
    private var sweepObservations: [String: Observation] = [:]
    private var sweepPaths: [String: Set<String>] = [:]
    private var sweepAmbiguous: Set<String> = []
    private var verified: [String: Observation] = [:]

    func noteIndexAvailable() {
        lock.lock()
        seenIndex = true
        lock.unlock()
    }

    func hasSeenIndex() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seenIndex
    }

    func files(for ids: Set<String>) -> [String: URL] {
        lock.lock()
        defer { lock.unlock() }
        return observations.filter { ids.contains($0.key) }.mapValues(\.file)
    }

    func remember(id: String, file: URL, device: UInt64, inode: UInt64, startKey: String) {
        lock.lock()
        defer { lock.unlock() }
        let current = Observation(file: file, device: device, inode: inode, startKey: startKey)
        if let old = observations[id], old != current {
            verified.removeValue(forKey: id)
            sweepObservations.removeValue(forKey: id)
        }
        if observations[id] == nil {
            if order.count >= 64, let oldest = order.first {
                order.removeFirst()
                observations.removeValue(forKey: oldest)
                verified.removeValue(forKey: oldest)
                sweepObservations.removeValue(forKey: oldest)
            }
            order.append(id)
        }
        observations[id] = current
    }

    func matchesObserved(id: String, file: URL, device: UInt64, inode: UInt64, startKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let observed = observations[id], !startKey.isEmpty else { return false }
        return observed.file.standardizedFileURL == file.standardizedFileURL &&
            observed.device == device && observed.inode == inode && observed.startKey == startKey
    }

    func matchesVerified(id: String, file: URL, device: UInt64, inode: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let proof = verified[id], let current = observations[id], current == proof,
              !proof.startKey.isEmpty else { return false }
        return proof.file.standardizedFileURL == file.standardizedFileURL &&
            proof.device == device && proof.inode == inode
    }

    /// Keep the iterator across refreshes. A complete sweep can confirm that
    /// an already observed task has only one recognized rollout path.
    func nextHistoryPage(directory: URL, limit: Int, previouslyObserved: Set<String>)
        throws -> (urls: [URL], complete: Bool, verifiedFiles: [String: URL]) {
        guard limit > 0 else { throw CocoaError(.fileReadUnknown) }
        lock.lock()
        defer { lock.unlock() }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: directory.path) }
        catch {
            verified.removeAll()
            historyEnumerator = nil
            historyErrors = nil
            throw error
        }
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            verified.removeAll()
            historyEnumerator = nil
            historyErrors = nil
            throw CocoaError(.fileReadUnknown)
        }
        if historyPath != directory.path || historyDevice != device || historyInode != inode {
            historyEnumerator = nil
            historyErrors = nil
            verified.removeAll()
            historyPath = directory.path
            historyDevice = device
            historyInode = inode
        }
        if historyEnumerator == nil {
            let errors = EnumerationErrors()
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles], errorHandler: { _, error in errors.value = error; return false }) else {
                verified.removeAll()
                throw CocoaError(.fileReadNoSuchFile)
            }
            historyEnumerator = enumerator
            historyErrors = errors
            sweepTargets = Set(previouslyObserved.filter { observations[$0] != nil })
            sweepObservations = observations.filter { sweepTargets.contains($0.key) }
            sweepPaths.removeAll(keepingCapacity: true)
            sweepAmbiguous.removeAll(keepingCapacity: true)
        }
        verified = verified.filter { previouslyObserved.contains($0.key) }

        func observe(_ url: URL) {
            let name = url.lastPathComponent
            let suffix: String
            if name.hasSuffix(".jsonl.zst") { suffix = ".jsonl.zst" }
            else if name.hasSuffix(".jsonl") { suffix = ".jsonl" }
            else { return }
            let stem = String(name.dropLast(suffix.count))
            if let owner = CodexTaskReader.canonicalOwner(in: stem) {
                let matching = sweepTargets.filter { $0.lowercased() == owner.lowercased() }
                guard matching.count == 1, let id = matching.first, id == owner else {
                    sweepAmbiguous.formUnion(matching)
                    for id in matching { verified.removeValue(forKey: id) }
                    return
                }
                var found = sweepPaths[id, default: []]
                found.insert(url.standardizedFileURL.path)
                if found.count > 3 {
                    sweepAmbiguous.insert(id)
                    sweepPaths.removeValue(forKey: id)
                    verified.removeValue(forKey: id)
                } else {
                    sweepPaths[id] = found
                    let plain = Set(found.filter { !$0.hasSuffix(".zst") })
                    let distinct = found.filter { path in
                        !path.hasSuffix(".jsonl.zst") || !plain.contains(String(path.dropLast(4)))
                    }
                    if distinct.count > 1 { verified.removeValue(forKey: id) }
                }
            } else {
                let lower = stem.lowercased()
                for id in sweepTargets {
                    let target = id.lowercased()
                    if lower == target || lower.hasSuffix("-" + target) || lower.contains("-" + target + "_") {
                        sweepAmbiguous.insert(id)
                        verified.removeValue(forKey: id)
                    }
                }
            }
        }

        func uniqueFiles() -> [String: URL] {
            var result: [String: URL] = [:]
            for id in sweepTargets where !sweepAmbiguous.contains(id) {
                let variants = sweepPaths[id, default: []]
                let plain = Set(variants.filter { !$0.hasSuffix(".zst") })
                let distinct = variants.filter { path in
                    guard path.hasSuffix(".jsonl.zst") else { return true }
                    return !plain.contains(String(path.dropLast(4)))
                }
                if distinct.count == 1, let path = distinct.first, !path.hasSuffix(".jsonl.zst") {
                    result[id] = URL(fileURLWithPath: path)
                }
            }
            return result
        }

        var urls: [URL] = []
        for _ in 0..<limit {
            guard let item = historyEnumerator?.nextObject() else {
                let error = historyErrors?.value
                historyEnumerator = nil
                historyErrors = nil
                if let error { verified.removeAll(); throw error }
                let found = uniqueFiles()
                verified.removeAll()
                for (id, file) in found {
                    guard let initial = sweepObservations[id], observations[id] == initial,
                          !initial.startKey.isEmpty,
                          initial.file.standardizedFileURL == file.standardizedFileURL else { continue }
                    verified[id] = initial
                }
                return (urls, true, verified.mapValues(\.file))
            }
            if let url = item as? URL {
                urls.append(url)
                observe(url)
            }
        }
        if let error = historyErrors?.value {
            historyEnumerator = nil
            historyErrors = nil
            verified.removeAll()
            throw error
        }
        return (urls, false, verified.mapValues(\.file))
    }
}

/// Reads each complete index line without limiting discovery to a fixed tail.
/// The cached snapshot is reused while the file identity, length and timestamp
/// remain unchanged. Malformed lines are ignored; oversized lines make the
/// source unavailable rather than silently hiding an unknown session.
final class CodexSessionIndexCache {
    private struct Signature: Equatable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private let lock = NSLock()
    private var signature: Signature?
    private var cached: [String: [String: Any]] = [:]

    func read(from url: URL) throws -> [String: [String: Any]] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let current: Signature?
        if let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
           let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
           let size = (attributes[.size] as? NSNumber)?.uint64Value,
           let modified = attributes[.modificationDate] as? Date {
            current = Signature(path: url.path, device: device, inode: inode, size: size, modified: modified)
        } else {
            current = nil
        }
        lock.lock()
        if let current, current == signature {
            let result = cached
            lock.unlock()
            return result
        }
        lock.unlock()

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sessions: [String: [String: Any]] = [:]
        var line = Data()
        var oversized = false
        let maximumLine = 1_048_576
        func consumeLine() throws {
            if oversized { throw CocoaError(.fileReadTooLarge) }
            if !oversized, let item = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                let id = item.string("id")
                if !id.isEmpty {
                    // Local Codex IDs must never occupy a provider-prefixed
                    // namespace used by Claude, cloud or external sources.
                    // Validate before inserting into Swift's String-keyed cache.
                    guard Self.supportsSessionID(id) else { throw CocoaError(.fileReadUnknown) }
                    sessions[id] = item
                }
            }
            line.removeAll(keepingCapacity: true)
            oversized = false
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            for byte in chunk {
                if byte == 10 { try consumeLine() }
                else if !oversized {
                    if line.count < maximumLine { line.append(byte) }
                    else { line.removeAll(keepingCapacity: true); oversized = true }
                }
            }
        }
        if !line.isEmpty || oversized { try consumeLine() }
        lock.lock()
        signature = current
        cached = sessions
        lock.unlock()
        return sessions
    }

    private static func supportsSessionID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
                                   (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
