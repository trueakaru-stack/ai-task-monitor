import Foundation
import Darwin

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
    private let execDiscovery = CodexExecDiscoveryCache()
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
        let sessions: [String: [String: Any]]
        var indexUnavailable = false
        do {
            sessions = try indexCache.read(from: index)
            execDiscovery.noteIndexAvailable()
        } catch {
            indexUnavailable = !Self.pathIsMissing(index) || execDiscovery.hasSeenIndex()
            sessions = [:]
        }

        let indexedIDs = Set(sessions.keys)
        let extra = try unindexedOwners(excluding: indexedIDs, now: now, observedSince: observedSince,
                                        previouslyObserved: previouslyObserved)
        let discovered = try sessionFiles(for: indexedIDs, now: now, observedSince: observedSince,
                                          previouslyObserved: previouslyObserved)
        let extraFiles = try sessionFiles(for: extra.ids, now: now, observedSince: observedSince,
                                          previouslyObserved: previouslyObserved, maximumVisited: 256)
        let files = discovered.files
        var result = CodexTaskSnapshot()
        result.isPartial = indexUnavailable || discovered.isPartial || extra.isPartial || extraFiles.isPartial
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
        for id in extra.ids {
            let available = extraFiles.didHitLimit ? extra.fastFiles : extraFiles.files
            guard let file = available[id] else { continue }
            do {
                guard let record = try readUnindexedExec(file, id: id) else { continue }
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
                        guard previouslyObserved.contains(id),
                              extra.verifiedFiles[id]?.standardizedFileURL == file.standardizedFileURL,
                              execDiscovery.matchesObserved(id: id, file: file, device: record.device,
                                                            inode: record.inode, startKey: state.startKey) else {
                            result.isPartial = true
                            continue
                        }
                    }
                    guard state.sawStart else { result.isPartial = true; continue }
                    let recognized = observedSince.map { since in
                        state.terminalDate.map { $0 >= since } ?? false
                    } ?? true
                    if recognized {
                        result.terminalIDs.insert(id)
                        if state.interrupted { result.interruptedIDs.insert(id) }
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
                let detail = parseActivity(from: record.tail)
                let status = tr("Статус не подтверждён", "Status unconfirmed")
                execDiscovery.remember(id: id, file: file, device: record.device, inode: record.inode,
                                       startKey: state.startKey)
                result.tasks.append(MonitoredTask(
                    id: id,
                    provider: .codex,
                    title: tr("Задача Codex", "Codex task"),
                    activity: detail.isEmpty ? status : status + ": " + detail,
                    isActive: false,
                    progress: nil,
                    progressKind: .none,
                    steps: steps,
                    updatedAt: record.modified,
                    isUnconfirmed: true,
                    startedAt: state.startedAt ?? .distantPast,
                    startKey: state.startKey,
                    planConfirmed: plan.confirmed
                ))
            } catch {
                // A changing, inaccessible or linked file is not evidence that
                // a previously observed task finished.
                result.isPartial = true
            }
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
        // A partial page can yield a verified exec record, but only as an
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

    private struct UnindexedExecRecord {
        var tail: String
        var modified: Date
        var truncated: Bool
        var device: UInt64
        var inode: UInt64
    }

    /// Open only regular files beneath the sessions directory, without
    /// following links in any enumerated component. A live CLI keeps writing
    /// the same descriptor while this bounded snapshot is read.
    private func readUnindexedExec(_ url: URL, id: String) throws -> UnindexedExecRecord? {
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
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        guard let newline = prefix.firstIndex(of: 0x0a),
              let header = try? JSONSerialization.jsonObject(with: Data(prefix[..<newline])) as? [String: Any],
              header.string("type") == "session_meta", let payload = header.object("payload") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard payload.string("id") == id, payload.string("source") == "exec" else { return nil }
        let end = try handle.seekToEnd()
        let count = min(end, UInt64(262_144))
        try handle.seek(toOffset: end - count)
        let bytes = try handle.read(upToCount: Int(count)) ?? Data()
        guard bytes.count == Int(count), fstat(descriptor, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                            Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return UnindexedExecRecord(tail: String(decoding: bytes, as: UTF8.self), modified: modified,
                                   truncated: end > count, device: UInt64(bitPattern: Int64(info.st_dev)),
                                   inode: UInt64(info.st_ino))
    }

    private func sessionFiles(for ids: Set<String>, now: Date, observedSince: Date?,
                              previouslyObserved: Set<String>, maximumVisited: Int? = nil) throws -> (files: [String: URL], isPartial: Bool, didHitLimit: Bool) {
        guard !ids.isEmpty else { return ([:], false, false) }
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
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            // Do not claim an unindexed task when a bounded scan cannot rule
            // out a second rollout or an ambiguous filename later in the tree.
            if let maximumVisited, visited > maximumVisited { return ([:], true, true) }
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
        return (files, !ambiguous.isEmpty || uuidIDs.count != ids.count, false)
    }

}

/// Small in-memory cache for paths that were already validated as exec
/// rollouts. It never writes the Codex index or stores session contents.
final class CodexExecDiscoveryCache {
    private final class EnumerationErrors {
        var value: Error?
    }

    private struct Observation {
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
    private var sweepPaths: [String: Set<String>] = [:]
    private var sweepAmbiguous: Set<String> = []

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
        if observations[id] == nil {
            if order.count >= 64, let oldest = order.first {
                order.removeFirst()
                observations.removeValue(forKey: oldest)
            }
            order.append(id)
        }
        observations[id] = Observation(file: file, device: device, inode: inode, startKey: startKey)
    }

    func matchesObserved(id: String, file: URL, device: UInt64, inode: UInt64, startKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let observed = observations[id], !startKey.isEmpty else { return false }
        return observed.file.standardizedFileURL == file.standardizedFileURL &&
            observed.device == device && observed.inode == inode && observed.startKey == startKey
    }

    /// Keep the iterator across refreshes. A complete sweep can confirm that
    /// an already observed task has only one recognized rollout path.
    func nextHistoryPage(directory: URL, limit: Int, previouslyObserved: Set<String>)
        throws -> (urls: [URL], complete: Bool, verifiedFiles: [String: URL]) {
        guard limit > 0 else { throw CocoaError(.fileReadUnknown) }
        lock.lock()
        defer { lock.unlock() }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        if historyPath != directory.path || historyDevice != device || historyInode != inode {
            historyEnumerator = nil
            historyErrors = nil
            historyPath = directory.path
            historyDevice = device
            historyInode = inode
        }
        if historyEnumerator == nil {
            let errors = EnumerationErrors()
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles], errorHandler: { _, error in errors.value = error; return false }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            historyEnumerator = enumerator
            historyErrors = errors
            sweepTargets = Set(previouslyObserved.filter { observations[$0] != nil })
            sweepPaths.removeAll(keepingCapacity: true)
            sweepAmbiguous.removeAll(keepingCapacity: true)
        }

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
                    return
                }
                var found = sweepPaths[id, default: []]
                found.insert(url.standardizedFileURL.path)
                if found.count > 3 {
                    sweepAmbiguous.insert(id)
                    sweepPaths.removeValue(forKey: id)
                } else {
                    sweepPaths[id] = found
                }
            } else {
                let lower = stem.lowercased()
                for id in sweepTargets {
                    let target = id.lowercased()
                    if lower == target || lower.hasSuffix("-" + target) || lower.contains("-" + target + "_") {
                        sweepAmbiguous.insert(id)
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
                if let error { throw error }
                return (urls, true, uniqueFiles())
            }
            if let url = item as? URL {
                urls.append(url)
                observe(url)
            }
        }
        if let error = historyErrors?.value {
            historyEnumerator = nil
            historyErrors = nil
            throw error
        }
        return (urls, false, [:])
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
