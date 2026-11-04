import Foundation

struct CodexLifecycleState {
    var running = false
    var terminal = false
    var terminalDate: Date?
    var interrupted = false
    var turnID = ""
    var startKey = ""
    var startedAt: Date?
    var lastActiveEvent: Date?
    var latestEvent: Date?
    var sawStart = false

    mutating func consume(_ record: [String: Any]) {
        guard record.string("type") == "event_msg", let payload = record.object("payload") else { return }
        let type = payload.string("type")
        let eventTurnID = payload.string("turn_id")
        let date = FileHelpers.isoDate(record["timestamp"])
        if let date, latestEvent.map({ date > $0 }) ?? true { latestEvent = date }
        switch type {
        case "task_started", "turn_started":
            running = true
            terminal = false
            terminalDate = nil
            interrupted = false
            turnID = eventTurnID
            let timestamp = record.string("timestamp")
            startKey = !eventTurnID.isEmpty ? "turn:\(eventTurnID)" : (timestamp.isEmpty ? "" : "time:\(timestamp)")
            startedAt = date
            lastActiveEvent = nil
            sawStart = true
        case "task_complete", "turn_complete", "turn_aborted":
            if !turnID.isEmpty && !eventTurnID.isEmpty && turnID != eventTurnID { return }
            running = false
            terminal = true
            terminalDate = date
            interrupted = type == "turn_aborted"
        default:
            if !turnID.isEmpty && !eventTurnID.isEmpty && turnID != eventTurnID { return }
        }
        if running, let date, lastActiveEvent.map({ date > $0 }) ?? true { lastActiveEvent = date }
    }

    func isRunning(observedSince: Date?) -> Bool {
        guard running else { return false }
        guard let observedSince else { return true }
        return lastActiveEvent.map { $0 >= observedSince } ?? false
    }

    static func parse(_ tail: String, seed: CodexLifecycleState? = nil) -> CodexLifecycleState {
        var state = seed ?? CodexLifecycleState()
        state.sawStart = false
        state.latestEvent = nil
        for line in tail.split(whereSeparator: \.isNewline) where line.contains("\"event_msg\"") {
            if let record = FileHelpers.jsonObject(line) { state.consume(record) }
        }
        return state
    }

    // Scan backward with bounded memory; retain only lifecycle markers, never task content.
    static func previous(in url: URL) throws -> CodexLifecycleState? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var position = try handle.seekToEnd()
        var suffix = Data()
        var discardPartial = false
        var terminals: [[String: Any]] = []
        var result: CodexLifecycleState?
        var tooManyTerminals = false
        let maximumLine = 1_048_576

        func accept(_ line: Data) -> Bool {
            guard !line.isEmpty, line.count <= maximumLine else { return false }
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains("\"event_msg\""),
                  ["task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted"].contains(where: { text.contains($0) }),
                  let record = FileHelpers.jsonObject(Substring(text)), record.string("type") == "event_msg",
                  let payload = record.object("payload") else { return false }
            let type = payload.string("type")
            if ["task_started", "turn_started"].contains(type) {
                var state = CodexLifecycleState()
                state.consume(record)
                for terminal in terminals.reversed() { state.consume(terminal) }
                result = state
                return true
            }
            if ["task_complete", "turn_complete", "turn_aborted"].contains(type) {
                guard terminals.count < 1_024 else { tooManyTerminals = true; return true }
                terminals.append([
                    "type": "event_msg", "timestamp": record.string("timestamp"),
                    "payload": ["type": type, "turn_id": payload.string("turn_id")]
                ])
            }
            return false
        }

        while position > 0 {
            let count = Int(min(position, UInt64(262_144)))
            position -= UInt64(count)
            try handle.seek(toOffset: position)
            guard let block = try handle.read(upToCount: count), block.count == count else {
                throw CocoaError(.fileReadUnknown)
            }
            var combined = block
            if !discardPartial { combined.append(suffix) }
            let bytes = [UInt8](combined)
            var end = bytes.count
            var foundNewline = false
            for index in bytes.indices.reversed() where bytes[index] == 0x0a {
                foundNewline = true
                if discardPartial { discardPartial = false }
                else if accept(Data(bytes[(index + 1)..<end])) { return tooManyTerminals ? nil : result }
                end = index
            }
            if position == 0 {
                if !discardPartial, accept(Data(bytes[0..<end])) { return tooManyTerminals ? nil : result }
                break
            }
            if discardPartial && !foundNewline { suffix.removeAll(keepingCapacity: false); continue }
            if end > maximumLine { suffix.removeAll(keepingCapacity: false); discardPartial = true }
            else { suffix = Data(bytes[0..<end]) }
        }
        guard !terminals.isEmpty else { return nil }
        var state = CodexLifecycleState()
        for terminal in terminals.reversed() { state.consume(terminal) }
        return state
    }
}

final class CodexLifecycleCache {
    struct Entry {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let anchor: Data
        let state: CodexLifecycleState
        let scannedPrior: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func previous(for url: URL, attributes: [FileAttributeKey: Any], maximumAppend: UInt64) throws -> Entry? {
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        lock.lock()
        let entry = entries[url.path]
        lock.unlock()
        guard let entry, entry.device == device, entry.inode == inode, size >= entry.size,
              size - entry.size <= maximumAppend, modified >= entry.modified,
              try anchor(of: url, at: entry.size) == entry.anchor else { return nil }
        return entry
    }

    func store(for url: URL, attributes: [FileAttributeKey: Any], state: CodexLifecycleState, scannedPrior: Bool) throws {
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date,
              let savedAnchor = try anchor(of: url, at: size) else { return }
        let entry = Entry(device: device, inode: inode, size: size, modified: modified,
                          anchor: savedAnchor, state: state, scannedPrior: scannedPrior)
        lock.lock()
        if entries.count >= 512 && entries[url.path] == nil { entries.removeAll(keepingCapacity: true) }
        entries[url.path] = entry
        lock.unlock()
    }

    private func anchor(of url: URL, at offset: UInt64) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() >= offset else { return nil }
        let count = Int(min(offset, UInt64(128)))
        try handle.seek(toOffset: offset - UInt64(count))
        return try handle.read(upToCount: count) ?? Data()
    }
}
