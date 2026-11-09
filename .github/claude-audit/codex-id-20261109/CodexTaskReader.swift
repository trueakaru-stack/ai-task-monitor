import Foundation

struct CodexTaskSnapshot {
    var tasks: [MonitoredTask] = []
    var terminalIDs: Set<String> = []
    var interruptedIDs: Set<String> = []
    var toolEvents: [String: [CodexToolEvent]] = [:]
}

struct CodexTaskReader {
    let codexHome: URL
    private let fileManager = FileManager.default
    private let lifecycleCache = CodexLifecycleCache()
    private let indexCache = CodexSessionIndexCache()
    private let planCache = CodexPlanHistoryCache()

    init(codexHome: URL? = nil) {
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

    func readSnapshot(now: Date = Date(), observedSince: Date? = nil, previouslyObserved: Set<String> = []) throws -> CodexTaskSnapshot {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        if !fileManager.fileExists(atPath: codexHome.path) { return CodexTaskSnapshot() }
        let sessions = try indexCache.read(from: index)

        let files = try sessionFiles(for: Set(sessions.keys))
        var result = CodexTaskSnapshot()
        for session in sessions.values {
            let id = session.string("id")
            let title = session.string("thread_name")
            guard !id.isEmpty, title != "Guardian review", let file = files[id] else { continue }
            let attributes = try fileManager.attributesOfItem(atPath: file.path)
            guard let modified = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            if let observedSince, modified < observedSince && !previouslyObserved.contains(id) { continue }
            let tailLimit = 4_194_304
            let tail = try FileHelpers.tail(of: file, maximumBytes: tailLimit)
            let cached = try? lifecycleCache.previous(for: file, attributes: attributes, maximumAppend: UInt64(tailLimit))
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
            if state.terminal {
                var recognized = false
                if let observedSince {
                    if let ended = state.terminalDate, ended >= observedSince { recognized = true }
                } else {
                    recognized = true
                }
                if recognized {
                    result.terminalIDs.insert(id)
                    if state.interrupted { result.interruptedIDs.insert(id) }
                    if previouslyObserved.contains(id), let observedSince {
                        result.toolEvents[id] = CodexToolEventParser.parse(tail: tail, since: observedSince, now: now)
                    }
                }
                continue
            }
            guard state.isRunning(observedSince: currentSince) else { continue }
            if let observedSince {
                result.toolEvents[id] = CodexToolEventParser.parse(tail: tail, since: observedSince, now: now)
            }

            let plan = try planCache.read(from: file)
            let steps = plan.steps
            let activity = parseActivity(from: tail)
            let progress = MonitoredTask.progress(for: steps)
            let unconfirmed = now.timeIntervalSince(modified) >= 7_200
            result.tasks.append(MonitoredTask(
                id: id,
                provider: .codex,
                title: title.isEmpty ? tr("Задача Codex", "Codex task") : title,
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : (activity.isEmpty ? tr("Выполняется", "Working") : activity),
                isActive: !unconfirmed,
                progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps,
                updatedAt: modified,
                isUnconfirmed: unconfirmed,
                startedAt: state.startedAt ?? .distantPast,
                startKey: state.startKey,
                planConfirmed: plan.confirmed
            ))
        }
        result.tasks.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    func isRunning(tail: String, observedSince: Date? = nil) -> Bool {
        CodexLifecycleState.parse(tail).isRunning(observedSince: observedSince)
    }

    func parsePlan(from tail: String) -> [TaskStep] {
        CodexPlanParser.parse(tail).steps
    }

    func parseActivity(from tail: String) -> String {
        var latestSummary = ""
        var latestCommentary = ""
        var turnID = ""
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else { continue }
            let recordType = record.string("type")
            let kind = payload.string("type")
            let eventTurnID = payload.string("turn_id")
            if recordType == "event_msg", ["task_started", "turn_started"].contains(kind) {
                turnID = eventTurnID
                latestSummary = ""
                latestCommentary = ""
                continue
            }
            if !turnID.isEmpty && !eventTurnID.isEmpty && turnID != eventTurnID { continue }
            var summary = ""
            if recordType == "event_msg", kind == "agent_reasoning" {
                summary = payload.string("text")
            } else if recordType == "response_item", kind == "reasoning" {
                for part in payload.array("summary") where part.string("type") == "summary_text" {
                    if !part.string("text").isEmpty { summary = part.string("text") }
                }
            } else if payload.string("type") == "message", payload.string("phase") == "commentary" {
                for part in payload.array("content") where part.string("type") == "output_text" {
                    latestCommentary = part.string("text")
                }
            } else if kind == "item_completed", let item = payload.object("item") {
                if item.string("type") == "Reasoning" {
                    for part in (item["summary_text"] as? [String] ?? []) where !part.isEmpty { summary = part }
                } else if item.string("type") == "AgentMessage", item.string("phase") == "commentary" {
                    for part in item.array("content") where part.string("type") == "Text" {
                        latestCommentary = part.string("text")
                    }
                }
            }
            if !summary.isEmpty {
                let firstLine = summary.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? ""
                if firstLine.hasPrefix("**") {
                    let remainder = firstLine.dropFirst(2)
                    if let end = remainder.range(of: "**") { latestSummary = String(remainder[..<end.lowerBound]) }
                    else { latestSummary = firstLine }
                } else { latestSummary = firstLine }
            }
        }
        return FileHelpers.normalized(latestSummary.isEmpty ? latestCommentary : latestSummary, limit: 600)
    }

    private func sessionFiles(for ids: Set<String>) throws -> [String: URL] {
        guard !ids.isEmpty else { return [:] }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadNoSuchFile) }
        let nonUUIDs = ids.filter { UUID(uuidString: $0) == nil }
        var files: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            var matches: [String] = []
            // After thread/revert, the filename ends in threadID_rolloutID.
            // The second UUID identifies the immutable rollout, not its owner.
            let pair = String(stem.suffix(73))
            let pairParts = pair.split(separator: "_", omittingEmptySubsequences: false)
            let isReverted = pairParts.count == 2 && pairParts.allSatisfy {
                $0.utf8.count == 36 && UUID(uuidString: String($0)) != nil
            } && (stem == pair || stem.hasSuffix("-" + pair))
            if isReverted {
                let owner = String(pairParts[0])
                if ids.contains(owner) { matches.append(owner) }
            } else {
                let candidate = String(stem.suffix(36))
                if UUID(uuidString: candidate) != nil && ids.contains(candidate) { matches.append(candidate) }
            }
            matches.append(contentsOf: nonUUIDs.filter { stem == $0 || stem.hasSuffix("-" + $0) })
            // A suffix is not a reliable owner when more than one requested
            // ID fits, or when several files fit the same ID. Keep the source
            // uncertain rather than displaying another task's data.
            if matches.count > 1 { throw CocoaError(.fileReadUnknown) }
            if let id = matches.first {
                if files[id] != nil { throw CocoaError(.fileReadUnknown) }
                files[id] = url
            }
        }
        if let enumerationError { throw enumerationError }
        return files
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
