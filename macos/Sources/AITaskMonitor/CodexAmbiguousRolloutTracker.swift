import Foundation
import Darwin

struct CodexRolloutHint: Equatable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    let turnID: String
    var modifiedSeconds: Int64? = nil
    var modifiedNanoseconds: Int64? = nil
}

struct CodexUncertainEnding {
    let token: UInt64
    let provenance: CodexRolloutHint?
}

/// Observes bounded appends to competing rollouts without selecting a history.
/// It does not open the Codex database, acquire writer locks, or write files.
/// An observed event is only a hint: callers must not infer a current turn,
/// progress, or completion from this tracker.
final class CodexAmbiguousRolloutTracker {
    private static let maximumThreads = 16
    private static let maximumRememberedThreads = 256
    private static let maximumCandidates = 8
    private static let maximumAppend = 65_536
    private static let maximumHeader = 65_536
    private static let anchorSize = 128

    private struct Identity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let seconds: Int64
        let nanoseconds: Int64

        init?(_ info: stat) {
            guard info.st_size >= 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            device = UInt64(bitPattern: Int64(info.st_dev))
            inode = UInt64(info.st_ino)
            size = UInt64(info.st_size)
            seconds = Int64(info.st_mtimespec.tv_sec)
            nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }

        var modified: Date {
            Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
        }
    }

    private struct Cursor {
        var identity: Identity
        var offset: UInt64
        var anchor: Data
        var discardLeadingPartial: Bool
        var observedWrite = false
        var currentTurn = ""
        var closedTurns: Set<String> = []
        var seenTurns: Set<String> = []
        var unscopedTerminal = false
    }

    private struct Group {
        var cursors: [String: Cursor]
        var blocked = false
        var quietIdentities: [String: Identity]? = nil
    }

    private struct UniqueObservation {
        var cursor: Cursor
        let previous: CodexRolloutHint
    }

    private struct Sample {
        var cursor: Cursor
        let pending: Bool
        let newUsefulEvent: Bool
        let usefulTurn: String
        let newStartTurn: String?
        let terminalTurns: Set<String>
    }

    private enum ReadFailure: Error {
        case unavailable
        case changedDuringRead
    }

    private let lock = NSLock()
    private var groups: [String: Group] = [:]
    private var groupOrder: [String] = []
    private var lastVisitedID: String?
    private var historyGap = false
    private var uniqueObservations: [String: UniqueObservation] = [:]
    private var uniqueBlocked: Set<String> = []
    private var uniqueLastVisitedID: String?
    private var observedTerminations: [String: Set<String>] = [:]

    /// Observation rotates in bounded batches. New files, replacements, lost
    /// reads, or competing appends block only the affected ID.
    func observe(_ candidates: [String: [URL]], sessionsDirectory: URL,
                 previouslyObserved: Set<String> = []) -> [String: CodexRolloutHint] {
        lock.lock()
        defer { lock.unlock() }
        if candidates.count > Self.maximumRememberedThreads {
            groups.removeAll()
            groupOrder.removeAll()
            lastVisitedID = nil
            // A later smaller set needs fresh starts: terminal history may have
            // been missed while the observation budget was exceeded.
            historyGap = true
            return [:]
        }
        let available = candidates.keys.sorted()
        let eligible: [String]
        if available.count <= Self.maximumThreads {
            eligible = available
            lastVisitedID = nil
        } else {
            let start = lastVisitedID.flatMap { last in available.firstIndex(where: { $0 > last }) } ?? 0
            eligible = (0..<Self.maximumThreads).map { available[(start + $0) % available.count] }
            lastVisitedID = eligible.last
        }
        groups = groups.filter { candidates[$0.key] != nil }
        groupOrder.removeAll { groups[$0] == nil }
        var hints: [String: CodexRolloutHint] = [:]

        for id in eligible {
            guard let urls = candidates[id], (2...Self.maximumCandidates).contains(urls.count),
                  urls.allSatisfy({ $0.isFileURL && $0.lastPathComponent.hasSuffix(".jsonl") }) else {
                groups.removeValue(forKey: id)
                groupOrder.removeAll { $0 == id }
                continue
            }
            let files = Dictionary(urls.map { ($0.standardizedFileURL.path, $0) },
                                   uniquingKeysWith: { first, _ in first })
            guard files.count == urls.count else {
                groups.removeValue(forKey: id)
                groupOrder.removeAll { $0 == id }
                continue
            }
            groupOrder.removeAll { $0 == id }
            if groups[id] != nil { groupOrder.append(id) }
            let paths = files.keys.sorted()
            if groups[id] == nil {
                var initial: [String: Cursor] = [:]
                var baselineTerminations: Set<String> = []
                do {
                    for path in paths {
                        let sample = try sampleFile(files[path]!, id: id, sessionsDirectory: sessionsDirectory, previous: nil)
                        baselineTerminations.formUnion(sample.terminalTurns)
                        var cursor = sample.cursor
                        if historyGap {
                            cursor.unscopedTerminal = true
                            cursor.currentTurn = ""
                        }
                        initial[path] = cursor
                    }
                    // The first observation is a baseline, never a new event.
                    guard try paths.allSatisfy({ try currentIdentity(files[$0]!, sessionsDirectory: sessionsDirectory) == initial[$0]?.identity }) else {
                        continue
                    }
                    if groups.count >= Self.maximumRememberedThreads, let oldest = groupOrder.first {
                        groups.removeValue(forKey: oldest)
                        groupOrder.removeFirst()
                    }
                    groups[id] = Group(cursors: initial)
                    groupOrder.append(id)
                    // If a visible card becomes ambiguous, its ending may
                    // have arrived just before this first baseline. Old
                    // records cannot prove completion, but a matching ending
                    // is enough to require hiding the uncertain card.
                    if previouslyObserved.contains(id) { recordTerminations(id: id, turns: baselineTerminations) }
                } catch {
                    // Retry baseline on the next scan. No path has been selected.
                }
                continue
            }

            guard var group = groups[id] else { continue }
            if group.blocked {
                // Even while no history can be selected, newly observed
                // terminal records may require hiding an existing card.
                var retained = group.cursors
                var terminalTurns: Set<String> = []
                for path in paths {
                    guard let old = group.cursors[path],
                          let sample = try? sampleFile(files[path]!, id: id,
                                                       sessionsDirectory: sessionsDirectory, previous: old) else { continue }
                    retained[path] = sample.cursor
                    terminalTurns.formUnion(sample.terminalTurns)
                }
                group.cursors = retained
                recordTerminations(id: id, turns: terminalTurns)
                // Two identical scans establish only a new observation
                // baseline. They do not confirm the selected history or the
                // fate of a card already shown to the user.
                do {
                    var baseline: [String: Cursor] = [:]
                    for path in paths {
                        baseline[path] = try sampleFile(files[path]!, id: id, sessionsDirectory: sessionsDirectory, previous: nil).cursor
                    }
                    guard try paths.allSatisfy({ try currentIdentity(files[$0]!, sessionsDirectory: sessionsDirectory) == baseline[$0]?.identity }) else {
                        throw ReadFailure.changedDuringRead
                    }
                    let identities = baseline.mapValues(\.identity)
                    if group.quietIdentities == identities {
                        for path in paths {
                            guard var fresh = baseline[path] else { continue }
                            if let old = group.cursors[path],
                               old.identity.device == fresh.identity.device,
                               old.identity.inode == fresh.identity.inode {
                                let closed = old.closedTurns.union(fresh.closedTurns)
                                let seen = old.seenTurns.union(fresh.seenTurns)
                                guard closed.count <= 128, seen.count <= 128 else { throw ReadFailure.unavailable }
                                fresh.closedTurns = closed
                                fresh.seenTurns = seen
                                if old.unscopedTerminal {
                                    fresh.unscopedTerminal = true
                                    fresh.currentTurn = ""
                                } else if fresh.closedTurns.contains(fresh.currentTurn) {
                                    fresh.currentTurn = ""
                                }
                            } else {
                                fresh.unscopedTerminal = true
                                fresh.currentTurn = ""
                            }
                            baseline[path] = fresh
                        }
                        group = Group(cursors: baseline)
                    } else {
                        group.quietIdentities = identities
                    }
                } catch {
                    group.quietIdentities = nil
                }
                groups[id] = group
                continue
            }
            guard Set(group.cursors.keys) == Set(paths) else {
                group.blocked = true
                groups[id] = group
                continue
            }
            var next = group.cursors
            var pending = false
            var usefulPaths: [String: String] = [:]
            var terminalTurns: Set<String> = []
            do {
                for path in paths {
                    let sample = try sampleFile(files[path]!, id: id, sessionsDirectory: sessionsDirectory, previous: group.cursors[path])
                    next[path] = sample.cursor
                    pending = pending || sample.pending
                    if sample.newUsefulEvent { usefulPaths[path] = sample.usefulTurn }
                    terminalTurns.formUnion(sample.terminalTurns)
                }
                guard try paths.allSatisfy({ try currentIdentity(files[$0]!, sessionsDirectory: sessionsDirectory) == next[$0]?.identity }) else {
                    throw ReadFailure.changedDuringRead
                }
                group.cursors = next
                let written = next.filter { $0.value.observedWrite }
                if written.count > 1 {
                    group.blocked = true
                } else if !pending, let only = written.first, written.count == 1,
                          let turn = usefulPaths[only.key], !turn.isEmpty {
                    let identity = only.value.identity
                    hints[id] = CodexRolloutHint(path: only.key, device: identity.device, inode: identity.inode,
                                                 size: identity.size, modified: identity.modified, turnID: turn,
                                                 modifiedSeconds: identity.seconds, modifiedNanoseconds: identity.nanoseconds)
                }
            } catch ReadFailure.changedDuringRead {
                // A live append can race with a scan. Keep the prior baseline.
            } catch {
                // Replacement, truncation, invalid data and inaccessible files
                // cannot establish which of the histories is current.
                group.blocked = true
            }
            recordTerminations(id: id, turns: terminalTurns)
            groups[id] = group
        }
        return hints
    }

    /// A protected card can recover only on the same file and a newly
    /// observed, different turn. Existing content is used as a baseline only.
    func observeUnique(_ candidates: [String: CodexRolloutHint], protectedIDs: Set<String>,
                       sessionsDirectory: URL) -> [String: CodexRolloutHint] {
        lock.lock()
        defer { lock.unlock() }
        uniqueBlocked.formIntersection(protectedIDs)
        for id in uniqueObservations.keys where candidates[id] == nil && protectedIDs.contains(id) {
            uniqueBlocked.insert(id)
        }
        guard candidates.count <= Self.maximumRememberedThreads else {
            uniqueBlocked.formUnion(uniqueObservations.keys)
            uniqueObservations.removeAll()
            uniqueLastVisitedID = nil
            return [:]
        }
        uniqueObservations = uniqueObservations.filter { candidates[$0.key] != nil }
        let ids = candidates.keys.sorted()
        let eligible: [String]
        if ids.count <= Self.maximumThreads {
            eligible = ids
            uniqueLastVisitedID = nil
        } else {
            let start = uniqueLastVisitedID.flatMap { last in ids.firstIndex(where: { $0 > last }) } ?? 0
            eligible = (0..<Self.maximumThreads).map { ids[(start + $0) % ids.count] }
            uniqueLastVisitedID = eligible.last
        }
        var starts: [String: CodexRolloutHint] = [:]
        for id in eligible {
            guard !uniqueBlocked.contains(id), let previous = candidates[id], !previous.turnID.isEmpty else { continue }
            let url = URL(fileURLWithPath: previous.path)
            if uniqueObservations[id] == nil {
                do {
                    var sample = try sampleFile(url, id: id, sessionsDirectory: sessionsDirectory, previous: nil).cursor
                    guard sample.identity.device == previous.device, sample.identity.inode == previous.inode else { continue }
                    var seen = sample.seenTurns
                    seen.insert(previous.turnID)
                    if let group = groups[id] {
                        for cursor in group.cursors.values { seen.formUnion(cursor.seenTurns) }
                    }
                    guard seen.count <= 128 else { continue }
                    sample.seenTurns = seen
                    uniqueObservations[id] = UniqueObservation(cursor: sample, previous: previous)
                } catch {
                    // Retry the baseline without accepting an old record.
                }
                continue
            }
            guard var observation = uniqueObservations[id], observation.previous == previous else {
                uniqueObservations.removeValue(forKey: id)
                continue
            }
            do {
                let sample = try sampleFile(url, id: id, sessionsDirectory: sessionsDirectory, previous: observation.cursor)
                guard sample.cursor.identity.device == previous.device,
                      sample.cursor.identity.inode == previous.inode else {
                    uniqueObservations.removeValue(forKey: id)
                    uniqueBlocked.insert(id)
                    continue
                }
                observation.cursor = sample.cursor
                uniqueObservations[id] = observation
                recordTerminations(id: id, turns: sample.terminalTurns)
                if !sample.pending, let turn = sample.newStartTurn, turn != previous.turnID,
                   sample.cursor.currentTurn == turn, !sample.cursor.closedTurns.contains(turn) {
                    let identity = sample.cursor.identity
                    starts[id] = CodexRolloutHint(path: previous.path, device: identity.device, inode: identity.inode,
                                                  size: identity.size, modified: identity.modified, turnID: turn,
                                                  modifiedSeconds: identity.seconds, modifiedNanoseconds: identity.nanoseconds)
                }
            } catch ReadFailure.changedDuringRead {
                // A writer raced this scan; try again with the old cursor.
            } catch {
                uniqueObservations.removeValue(forKey: id)
                uniqueBlocked.insert(id)
            }
        }
        return starts
    }

    private func sampleFile(_ url: URL, id: String, sessionsDirectory: URL, previous: Cursor?) throws -> Sample {
        let descriptor = try openFile(url, sessionsDirectory: sessionsDirectory)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        let before = try identity(descriptor)
        let prefix = try handle.read(upToCount: Self.maximumHeader) ?? Data()
        guard let newline = prefix.firstIndex(of: 0x0a),
              let header = try? JSONSerialization.jsonObject(with: Data(prefix[..<newline])) as? [String: Any],
              header.string("type") == "session_meta",
              let payload = header.object("payload"), payload.string("id") == id else {
            throw ReadFailure.unavailable
        }

        var cursor: Cursor
        var pending = false
        var newUsefulEvent = false
        var usefulTurn = ""
        var newStartTurn: String? = nil
        var terminalTurns: Set<String> = []
        if var previous {
            guard before.device == previous.identity.device, before.inode == previous.identity.inode,
                  before.size >= previous.offset,
                  before.size >= previous.identity.size,
                  (before.seconds, before.nanoseconds) >= (previous.identity.seconds, previous.identity.nanoseconds),
                  before.size - previous.offset <= UInt64(Self.maximumAppend) else {
                throw ReadFailure.unavailable
            }
            if before.size == previous.offset && before != previous.identity {
                throw ReadFailure.unavailable
            }
            guard try anchor(handle, at: previous.offset) == previous.anchor else {
                throw ReadFailure.unavailable
            }
            let count = Int(before.size - previous.offset)
            if count > 0 {
                previous.observedWrite = true
                try handle.seek(toOffset: previous.offset)
                let bytes = try handle.read(upToCount: count) ?? Data()
                guard bytes.count == count else { throw ReadFailure.changedDuringRead }
                pending = bytes.last != 0x0a
                if let lastNewline = bytes.lastIndex(of: 0x0a) {
                    // Process complete records even if the next one is still
                    // being written. Leave the cursor at that partial record.
                    var complete = bytes[...lastNewline]
                    if previous.discardLeadingPartial {
                        guard let end = complete.firstIndex(of: 0x0a) else { throw ReadFailure.unavailable }
                        complete = complete[complete.index(after: end)...]
                        previous.discardLeadingPartial = false
                    }
                    let events = try consumeEvents(in: complete, id: id, cursor: &previous)
                    newUsefulEvent = events.useful
                    usefulTurn = events.usefulTurn
                    newStartTurn = events.newStart
                    terminalTurns = events.terminalTurns
                    let consumed = bytes.distance(from: bytes.startIndex, to: bytes.index(after: lastNewline))
                    previous.offset += UInt64(consumed)
                    previous.anchor = try anchor(handle, at: previous.offset)
                }
            }
            previous.identity = before
            cursor = previous
        } else {
            let last: Data
            if before.size > 0 {
                try handle.seek(toOffset: before.size - 1)
                last = try handle.read(upToCount: 1) ?? Data()
                guard last.count == 1 else { throw ReadFailure.changedDuringRead }
            } else {
                last = Data()
            }
            let partial = last.last != 0x0a
            cursor = Cursor(identity: before, offset: before.size, anchor: try anchor(handle, at: before.size),
                            discardLeadingPartial: partial)
            let count = Int(min(before.size, UInt64(Self.maximumAppend)))
            try handle.seek(toOffset: before.size - UInt64(count))
            let tail = try handle.read(upToCount: count) ?? Data()
            guard tail.count == count else { throw ReadFailure.changedDuringRead }
            var complete = tail[...]
            if before.size > UInt64(count) {
                if let first = complete.firstIndex(of: 0x0a) {
                    complete = complete[complete.index(after: first)...]
                } else {
                    complete = complete[complete.endIndex...]
                }
            }
            if partial {
                if let lastNewline = complete.lastIndex(of: 0x0a) {
                    complete = complete[...lastNewline]
                } else {
                    complete = complete[complete.endIndex...]
                }
            }
            terminalTurns = try consumeEvents(in: complete, id: id, cursor: &cursor).terminalTurns
            // An incomplete record started before the baseline could itself be
            // a terminal marker. Wait for a new start before using later items.
            if partial { cursor.unscopedTerminal = true; cursor.currentTurn = "" }
        }

        guard try identity(descriptor) == before,
              try currentIdentity(url, sessionsDirectory: sessionsDirectory) == before else {
            throw ReadFailure.changedDuringRead
        }
        return Sample(cursor: cursor, pending: pending, newUsefulEvent: newUsefulEvent,
                      usefulTurn: usefulTurn, newStartTurn: newStartTurn, terminalTurns: terminalTurns)
    }

    private func consumeEvents(in data: Data.SubSequence, id: String, cursor: inout Cursor)
        throws -> (useful: Bool, usefulTurn: String, newStart: String?, terminalTurns: Set<String>) {
        var useful = false
        var usefulTurn = ""
        var newStart: String?
        var terminalTurns: Set<String> = []
        for line in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = record.object("payload"), !record.string("type").isEmpty else {
                throw ReadFailure.unavailable
            }
            guard record.string("type") == "event_msg" else { continue }
            if let thread = payload["thread_id"], (thread as? String) != id { throw ReadFailure.unavailable }
            let turn = payload.string("turn_id")
            let validTurn = !turn.isEmpty && turn.utf8.count <= 256 &&
                !turn.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            switch payload.string("type") {
            case "task_complete", "turn_complete", "turn_aborted":
                terminalTurns.insert(validTurn ? turn : "")
                let closed = validTurn ? turn : cursor.currentTurn
                if !closed.isEmpty {
                    guard cursor.closedTurns.contains(closed) || cursor.closedTurns.count < 128 else {
                        throw ReadFailure.unavailable
                    }
                    cursor.closedTurns.insert(closed)
                    guard cursor.seenTurns.contains(closed) || cursor.seenTurns.count < 128 else {
                        throw ReadFailure.unavailable
                    }
                    cursor.seenTurns.insert(closed)
                }
                if !validTurn { cursor.unscopedTerminal = true }
                if !validTurn || cursor.currentTurn == turn { cursor.currentTurn = "" }
                if !validTurn || usefulTurn == turn {
                    useful = false
                    usefulTurn = ""
                    newStart = nil
                }
            case "task_started", "turn_started":
                if validTurn && !cursor.closedTurns.contains(turn) && FileHelpers.isoDate(record["timestamp"]) != nil {
                    let isNew = !cursor.seenTurns.contains(turn)
                    guard !isNew || cursor.seenTurns.count < 128 else { throw ReadFailure.unavailable }
                    cursor.seenTurns.insert(turn)
                    cursor.currentTurn = turn
                    cursor.unscopedTerminal = false
                    useful = true
                    usefulTurn = turn
                    if isNew { newStart = turn }
                }
            case "agent_reasoning":
                if matchesOpenTurn(turn, valid: validTurn, cursor: cursor) &&
                    FileHelpers.isoDate(record["timestamp"]) != nil && !payload.string("text").isEmpty {
                    useful = true
                    usefulTurn = cursor.currentTurn
                }
            case "agent_message":
                if matchesOpenTurn(turn, valid: validTurn, cursor: cursor) &&
                    FileHelpers.isoDate(record["timestamp"]) != nil && !payload.string("message").isEmpty {
                    useful = true
                    usefulTurn = cursor.currentTurn
                }
            case "item_completed", "item_started":
                // Inspect only identifiers and item type. Do not retain or
                // publish item arguments, command text, results, or paths.
                if payload.string("thread_id") == id && validTurn &&
                    !cursor.unscopedTerminal && !cursor.closedTurns.contains(turn) &&
                    (cursor.currentTurn.isEmpty || cursor.currentTurn == turn) &&
                    FileHelpers.isoDate(record["timestamp"]) != nil,
                    let item = payload.object("item"), !item.string("type").isEmpty,
                    !item.string("id").isEmpty, item.string("id").utf8.count <= 256 {
                    useful = true
                    usefulTurn = turn
                }
            default:
                break
            }
        }
        return (useful, usefulTurn, newStart, terminalTurns)
    }

    private func recordTerminations(id: String, turns: Set<String>) {
        guard !turns.isEmpty else { return }
        observedTerminations[id, default: []].formUnion(turns)
        if observedTerminations[id, default: []].count > 128 { observedTerminations[id] = [""] }
    }

    func takeTerminations() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        let values = observedTerminations
        observedTerminations.removeAll()
        return values
    }

    private func matchesOpenTurn(_ turn: String, valid: Bool, cursor: Cursor) -> Bool {
        guard !cursor.unscopedTerminal, !cursor.currentTurn.isEmpty,
              !cursor.closedTurns.contains(cursor.currentTurn) else { return false }
        return turn.isEmpty || (valid && turn == cursor.currentTurn && !cursor.closedTurns.contains(turn))
    }

    private func anchor(_ handle: FileHandle, at offset: UInt64) throws -> Data {
        let count = Int(min(offset, UInt64(Self.anchorSize)))
        try handle.seek(toOffset: offset - UInt64(count))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ReadFailure.changedDuringRead }
        return data
    }

    private func currentIdentity(_ url: URL, sessionsDirectory: URL) throws -> Identity {
        let descriptor = try openFile(url, sessionsDirectory: sessionsDirectory)
        defer { Darwin.close(descriptor) }
        return try identity(descriptor)
    }

    private func identity(_ descriptor: Int32) throws -> Identity {
        var info = stat()
        guard fstat(descriptor, &info) == 0, let value = Identity(info) else {
            throw ReadFailure.unavailable
        }
        return value
    }

    private func openFile(_ url: URL, sessionsDirectory: URL) throws -> Int32 {
        let directory = sessionsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(directory + "/") else { throw ReadFailure.unavailable }
        let components = path.dropFirst(directory.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.count <= 16,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReadFailure.unavailable
        }
        var parent = directory.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard parent >= 0 else { throw ReadFailure.unavailable }
        for component in components.dropLast() {
            let next = String(component).withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            Darwin.close(parent)
            guard next >= 0 else { throw ReadFailure.unavailable }
            parent = next
        }
        let descriptor = String(components.last!).withCString {
            openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        Darwin.close(parent)
        guard descriptor >= 0 else { throw ReadFailure.unavailable }
        return descriptor
    }
}

/// The normal refresh never waits for file reads. Results are consumed only
/// while the same set of candidate paths is still present.
final class CodexAmbiguousRolloutWorker {
    struct Result {
        let hints: [String: CodexRolloutHint]
        let freshStarts: [String: CodexRolloutHint]
        let protectedIDs: Set<String>
        let recovered: [String: CodexRolloutHint]
        let uncertainEndings: [String: CodexUncertainEnding]

        func protects(_ id: String) -> Bool {
            protectedIDs.contains(id)
        }
    }

    private struct PendingHint {
        let hint: CodexRolloutHint
        let paths: Set<String>
    }

    private struct PendingEnding {
        var turns: Set<String>
        var token: UInt64
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai-task-monitor.codex-ambiguous-rollouts", qos: .utility)
    private let observeForTests: (([String: [URL]], URL) -> [String: CodexRolloutHint])?
    private var scope: Date?
    private var generation: UInt64 = 0
    private var running = false
    private var signatures: [String: Set<String>] = [:]
    private var pending: [String: PendingHint] = [:]
    private var pendingFresh: [String: CodexRolloutHint] = [:]
    private var offeredFresh: [String: CodexRolloutHint] = [:]
    private var knownHistories: [String: CodexRolloutHint] = [:]
    private var recoveredHistories: [String: CodexRolloutHint] = [:]
    private var uniquePaths: [String: String] = [:]
    private var protectedIDs: Set<String> = []
    private var pendingEndings: [String: PendingEnding] = [:]
    private var nextEndingToken: UInt64 = 0

    // Accessed only by queue.
    private var tracker = CodexAmbiguousRolloutTracker()
    private var trackerGeneration: UInt64?

    init(observeForTests: (([String: [URL]], URL) -> [String: CodexRolloutHint])? = nil) {
        self.observeForTests = observeForTests
    }

    func poll(candidates: [String: [URL]], ambiguousIDs: Set<String>, uniqueFiles: [String: URL] = [:], previouslyObserved: Set<String>,
              hiddenIDs: Set<String> = [], restoredHistories: [String: CodexRolloutHint] = [:],
              sessionsDirectory: URL, observedSince: Date?) -> Result {
        lock.lock()
        defer { lock.unlock() }
        if scope != observedSince {
            scope = observedSince
            generation &+= 1
            signatures.removeAll()
            pending.removeAll()
            pendingFresh.removeAll()
            offeredFresh.removeAll()
            knownHistories.removeAll()
            recoveredHistories.removeAll()
            protectedIDs.removeAll()
            pendingEndings.removeAll()
        }
        guard observedSince != nil else {
            return Result(hints: [:], freshStarts: [:], protectedIDs: [], recovered: [:], uncertainEndings: [:])
        }
        // Protection follows currently displayed cards instead of accumulating
        // forever or disabling unrelated cards on a global overflow.
        let relevantIDs = previouslyObserved.union(hiddenIDs)
        protectedIDs.formIntersection(relevantIDs)
        protectedIDs.formUnion(hiddenIDs)
        knownHistories = knownHistories.filter { relevantIDs.contains($0.key) }
        recoveredHistories = recoveredHistories.filter { relevantIDs.contains($0.key) }
        for (id, history) in restoredHistories where hiddenIDs.contains(id) && knownHistories[id] == nil {
            knownHistories[id] = history
        }
        signatures = candidates.mapValues { Set($0.map { $0.standardizedFileURL.path }) }
        uniquePaths = uniqueFiles.mapValues { $0.standardizedFileURL.path }
        for id in ambiguousIDs where previouslyObserved.contains(id) { protect(id) }
        var uncertainEndings: [String: CodexUncertainEnding] = [:]
        var unrelated: [String] = []
        for (id, ending) in pendingEndings {
            let candidate = knownHistories[id] ??
                ((signatures[id] == pending[id]?.paths) ? pending[id]?.hint : nil)
            let currentTurn = candidate?.turnID ?? ""
            if ending.turns.contains("") || currentTurn.isEmpty || ending.turns.contains(currentTurn) {
                uncertainEndings[id] = CodexUncertainEnding(token: ending.token, provenance: candidate)
                protect(id)
            } else {
                unrelated.append(id)
            }
        }
        for id in unrelated { pendingEndings.removeValue(forKey: id) }
        var hints: [String: CodexRolloutHint] = [:]
        for (id, hint) in pending where signatures[id] == hint.paths && !relevantIDs.contains(id) && uncertainEndings[id] == nil {
            hints[id] = hint.hint
            knownHistories[id] = hint.hint
            protect(id)
        }
        pending.removeAll()
        var freshStarts: [String: CodexRolloutHint] = [:]
        var waitingFresh: [String: CodexRolloutHint] = [:]
        for (id, hint) in pendingFresh where protectedIDs.contains(id) && uniquePaths[id] == hint.path {
            if uncertainEndings[id] != nil {
                waitingFresh[id] = hint
            } else {
                freshStarts[id] = hint
                offeredFresh[id] = hint
            }
        }
        pendingFresh = waitingFresh
        offeredFresh = offeredFresh.filter { protectedIDs.contains($0.key) && uniquePaths[$0.key] == $0.value.path }
        let uniqueCandidates = knownHistories.filter {
            protectedIDs.contains($0.key) && uniquePaths[$0.key] == $0.value.path
        }
        if !running && (!candidates.isEmpty || !uniqueCandidates.isEmpty) {
            running = true
            let requestGeneration = generation
            let requestSignatures = signatures
            let requestedProtected = protectedIDs
            queue.async { [self] in
                if trackerGeneration != requestGeneration {
                    tracker = CodexAmbiguousRolloutTracker()
                    trackerGeneration = requestGeneration
                }
                let fresh = tracker.observeUnique(uniqueCandidates, protectedIDs: requestedProtected,
                                                 sessionsDirectory: sessionsDirectory)
                let observed = observeForTests?(candidates, sessionsDirectory) ??
                    tracker.observe(candidates, sessionsDirectory: sessionsDirectory,
                                    previouslyObserved: previouslyObserved)
                let terminations = tracker.takeTerminations()
                lock.lock()
                if generation == requestGeneration {
                    for (id, hint) in observed {
                        if let paths = requestSignatures[id], signatures[id] == paths {
                            pending[id] = PendingHint(hint: hint, paths: paths)
                        }
                    }
                    for (id, hint) in fresh where requestedProtected.contains(id) &&
                        protectedIDs.contains(id) && uniquePaths[id] == hint.path {
                        pendingFresh[id] = hint
                    }
                    for (id, turns) in terminations {
                        nextEndingToken &+= 1
                        var merged = pendingEndings[id]?.turns ?? []
                        merged.formUnion(turns)
                        if merged.count > 128 { merged = [""] }
                        pendingEndings[id] = PendingEnding(turns: merged, token: nextEndingToken)
                    }
                }
                running = false
                lock.unlock()
            }
        }
        return Result(hints: hints, freshStarts: freshStarts, protectedIDs: protectedIDs,
                      recovered: recoveredHistories, uncertainEndings: uncertainEndings)
    }

    func acknowledgeEndings(_ tokens: [String: UInt64]) {
        lock.lock()
        defer { lock.unlock() }
        for (id, token) in tokens where pendingEndings[id]?.token == token {
            pendingEndings.removeValue(forKey: id)
        }
    }

    // A recovered history may itself contain an ending which cannot be
    // attributed to the recovered turn. Preserve it until the caller has
    // durably hidden the card; it is not a confirmed terminal result.
    func markUncertainEnding(_ id: String, provenance: CodexRolloutHint) -> CodexUncertainEnding {
        lock.lock()
        defer { lock.unlock() }
        nextEndingToken &+= 1
        pendingEndings[id] = PendingEnding(turns: [""], token: nextEndingToken)
        knownHistories[id] = provenance
        protect(id)
        return CodexUncertainEnding(token: nextEndingToken, provenance: provenance)
    }

    func noteKnown(_ id: String, hint: CodexRolloutHint) {
        lock.lock()
        defer { lock.unlock() }
        if !protectedIDs.contains(id) { knownHistories[id] = hint }
    }

    func acceptFresh(_ id: String, hint: CodexRolloutHint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard protectedIDs.contains(id), offeredFresh[id] == hint, uniquePaths[id] == hint.path else { return false }
        protectedIDs.remove(id)
        offeredFresh.removeValue(forKey: id)
        pendingFresh.removeValue(forKey: id)
        knownHistories[id] = hint
        recoveredHistories[id] = hint
        return true
    }

    // The caller must first persist removal of the matching hidden record.
    // A newly observed ending invalidates a pending recovery.
    func commitRecovered(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recoveredHistories[id] != nil, pendingEndings[id] == nil else { return false }
        protectedIDs.remove(id)
        return true
    }

    func updateRecovered(_ id: String, previous: CodexRolloutHint, current: CodexRolloutHint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard recoveredHistories[id] == previous, !protectedIDs.contains(id) else { return false }
        recoveredHistories[id] = current
        return true
    }

    private func protect(_ id: String) {
        protectedIDs.insert(id)
    }

    func waitUntilIdleForTests() {
        queue.sync {}
    }
}
