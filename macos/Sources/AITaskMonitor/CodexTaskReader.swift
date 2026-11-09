import Foundation

struct CodexTaskSnapshot {
    var tasks: [MonitoredTask] = []
    var terminalIDs: Set<String> = []
    var interruptedIDs: Set<String> = []
    var toolEvents: [String: [CodexToolEvent]] = [:]
    var isPartial = false
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

        let discovered = try sessionFiles(for: Set(sessions.keys), now: now, observedSince: observedSince,
                                          previouslyObserved: previouslyObserved)
        let files = discovered.files
        var result = CodexTaskSnapshot()
        result.isPartial = discovered.isPartial
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

    // A supported timestamped basename is exactly the form emitted by the
    // pinned upstream writer. Parsing the whole basename prevents a short ID
    // from claiming a longer identifier merely because their suffixes match.
    private static func canonicalOwner(in stem: String) -> String? {
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

    private func sessionFiles(for ids: Set<String>, now: Date, observedSince: Date?,
                              previouslyObserved: Set<String>) throws -> (files: [String: URL], isPartial: Bool) {
        guard !ids.isEmpty else { return ([:], false) }
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw CocoaError(.fileReadNoSuchFile) }
        let uuidIDs = ids.filter { $0.utf8.count == 36 && UUID(uuidString: $0) != nil }
        var files: [String: URL] = [:]
        var candidates: [String: [URL]] = [:]
        var variants: [String: [String]] = [:]
        for id in uuidIDs { variants[id.lowercased(), default: []].append(id) }
        var ambiguous = Set(variants.values.filter { $0.count > 1 }.flatMap { $0 })
        for case let url as URL in enumerator {
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
        return (files, !ambiguous.isEmpty || uuidIDs.count != ids.count)
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
