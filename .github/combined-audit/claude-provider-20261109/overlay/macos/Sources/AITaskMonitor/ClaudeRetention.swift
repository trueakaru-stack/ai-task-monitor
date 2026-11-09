import CryptoKit
import CoreFoundation
import Darwin
import Foundation

struct ClaudeRetentionPolicy: Equatable {
    let days: Int
    let maximumMB: Int

    static func load(from defaults: UserDefaults = .standard) -> ClaudeRetentionPolicy? {
        let daysValue = defaults.object(forKey: "claudeRetentionDays")
        let sizeValue = defaults.object(forKey: "claudeMaximumMB")
        guard (daysValue == nil || daysValue is Int), (sizeValue == nil || sizeValue is Int) else { return nil }
        let days = daysValue as? Int ?? 7
        let size = sizeValue as? Int ?? 10
        guard (1...30).contains(days), (1...100).contains(size) else { return nil }
        return ClaudeRetentionPolicy(days: days, maximumMB: size)
    }
}

final class ClaudeRetentionWorker {
    private let queue = DispatchQueue(label: "AI Task Monitor Claude retention", qos: .utility)
    private let gate = NSLock()
    private var generation = 0

    func invalidate() {
        gate.lock(); generation += 1; gate.unlock()
    }

    func schedule(policy: ClaudeRetentionPolicy, directory: URL, backups: URL, completion: @escaping (Bool) -> Void) {
        gate.lock(); generation += 1; let requested = generation; gate.unlock()
        queue.async {
            do {
                try ClaudeRetention.clean(directory: directory, backups: backups, now: Date(), policy: policy) { action in
                    self.gate.lock(); defer { self.gate.unlock() }
                    guard self.generation == requested else { throw CancellationError() }
                    try action()
                }
                self.gate.lock(); let current = self.generation == requested; self.gate.unlock()
                if current { completion(true) }
            } catch is CancellationError {
                return
            } catch {
                self.gate.lock(); let current = self.generation == requested; self.gate.unlock()
                if current { completion(false) }
            }
        }
    }
}

enum ClaudeRetention {
    enum Failure: Error { case unsafePath, invalidRecord, tooLarge, changed, io }
    private struct Entry {
        let source: Int
        let order: Int
        let time: Date
        var line: Data
        var bytes: Int { line.count + 1 }
    }
    private struct Source {
        let url: URL
        let digest: SHA256.Digest
        let count: Int
        var needsRewrite: Bool
    }
    typealias Commit = (@escaping () throws -> Void) throws -> Void

    static func clean(directory: URL, backups: URL, now: Date, policy: ClaudeRetentionPolicy,
                      commit: Commit = { try $0() }) throws {
        guard (1...30).contains(policy.days), (1...100).contains(policy.maximumMB) else { throw Failure.invalidRecord }
        if exists(directory) {
            try ordinary(directory, directory: true)
            let lockPath = directory.appendingPathComponent("claude-events.lock").path
            let descriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Failure.unsafePath }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw Failure.io }
            defer { flock(descriptor, LOCK_UN) }
            try cleanEvents(directory: directory, cutoff: now.addingTimeInterval(-Double(policy.days) * 86_400),
                            maximum: policy.maximumMB * 1_000_000, commit: commit)
        }
        try cleanBackups(backups, cutoff: now.addingTimeInterval(-30 * 86_400), commit: commit)
    }

    private static func cleanEvents(directory: URL, cutoff: Date, maximum: Int, commit: Commit) throws {
        var entries: [Entry] = []
        var sources: [Source] = []
        var total = 0
        var changed = false
        var lossMarkers: [Entry] = []
        var scopeIncomplete = false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        for name in ["claude-events.jsonl", "claude-events-v2.jsonl"] {
            let url = directory.appendingPathComponent(name)
            guard exists(url) else { continue }
            try ordinary(url, directory: false)
            let sourceIndex = sources.count
            var count = 0
            var marker: Entry?
            var needsRewrite = false
            let digest = try readLines(url) { line in
                guard let object = ClaudeJSONValidation.object(line), let stamp = object["timestamp"] as? String,
                      let date = formatter.date(from: stamp) ?? fallback.date(from: stamp) else { throw Failure.invalidRecord }
                count += 1
                if let markerInfo = sourceLossMarker(object) {
                    // Keep only fixed, non-content metadata. One marker per
                    // source survives age and size cleanup until a trustworthy
                    // recovery protocol is available.
                    var normalized: [String: Any] = ["timestamp": stamp, "provider": "claude", "session_id": "",
                        "event": markerInfo.event, "plan_version": 2, "plan_signal": "source_uncertain"]
                    if markerInfo.scopeIncomplete { normalized["scope_incomplete"] = true; scopeIncomplete = true }
                    let bytes = try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
                    if bytes != line || marker != nil { needsRewrite = true; changed = true }
                    marker = Entry(source: sourceIndex, order: count, time: date, line: bytes)
                    return
                }
                if let session = object["session_id"] as? String, session.isEmpty {
                    // Never make an unsupported empty-session record vanish
                    // before the reader has surfaced source uncertainty.
                    throw Failure.invalidRecord
                }
                guard date >= cutoff else { changed = true; return }
                let item = Entry(source: sourceIndex, order: count, time: date, line: line)
                push(item, into: &entries); total += item.bytes
                while total > maximum, let removed = pop(&entries) { total -= removed.bytes; changed = true }
            }
            if let marker { lossMarkers.append(marker) }
            sources.append(Source(url: url, digest: digest, count: count, needsRewrite: needsRewrite))
        }
        var reserved = lossMarkers.reduce(0) { $0 + $1.bytes }
        guard reserved <= maximum else { throw Failure.tooLarge }
        while total > maximum - reserved, let removed = pop(&entries) { total -= removed.bytes; changed = true }
        if !lossMarkers.isEmpty {
            for (index, source) in sources.enumerated() {
                let retained = entries.filter { $0.source == index }.count + lossMarkers.filter { $0.source == index }.count
                if retained < source.count { scopeIncomplete = true }
            }
        }
        if scopeIncomplete {
            for index in lossMarkers.indices {
                guard var object = ClaudeJSONValidation.object(lossMarkers[index].line) else { throw Failure.invalidRecord }
                object["scope_incomplete"] = true
                let newLine = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                if newLine != lossMarkers[index].line {
                    lossMarkers[index].line = newLine
                    sources[lossMarkers[index].source].needsRewrite = true
                    changed = true
                }
            }
            reserved = lossMarkers.reduce(0) { $0 + $1.bytes }
            guard reserved <= maximum else { throw Failure.tooLarge }
            while total > maximum - reserved, let removed = pop(&entries) { total -= removed.bytes; changed = true }
        }
        for marker in lossMarkers { push(marker, into: &entries); total += marker.bytes }
        guard changed else { return }
        var staged: [URL] = []
        defer { for url in staged { try? FileManager.default.removeItem(at: url) } }
        // Commit a surviving loss marker (including scope_incomplete) before
        // deleting identity records in another file. An interrupted second
        // rename must leave either old identity or the conservative marker.
        let markerSources = Set(lossMarkers.map { $0.source })
        let commitOrder = sources.indices.sorted {
            if markerSources.contains($0) != markerSources.contains($1) { return markerSources.contains($0) }
            return $0 < $1
        }
        for index in commitOrder {
            let source = sources[index]
            let selected = entries.filter { $0.source == index }.sorted { $0.order < $1.order }
            guard selected.count != source.count || source.needsRewrite else { continue }
            let temporary = directory.appendingPathComponent(".aitm-retention-\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw Failure.io }
            staged.append(temporary)
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                for entry in selected { try handle.write(contentsOf: entry.line); try handle.write(contentsOf: Data([10])) }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            try commit {
                try ordinary(source.url, directory: false)
                guard try readLines(source.url, consume: { _ in }) == source.digest else { throw Failure.changed }
                guard rename(temporary.path, source.url.path) == 0 else { throw Failure.io }
            }
        }
    }

    private static func sourceLossMarker(_ object: [String: Any]) -> (event: String, scopeIncomplete: Bool)? {
        guard let session = object["session_id"] as? String, session.isEmpty,
              let version = object["plan_version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              let name = object["event"] as? String, let signal = object["plan_signal"] as? String else { return nil }
        var scopeIncomplete = false
        if let raw = object["scope_incomplete"] {
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
            scopeIncomplete = flag.boolValue
        }
        func same(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }
        if version.doubleValue == 2 && same(signal, "source_uncertain") && same(name, "AITMSourceUncertain") {
            return ("AITMSourceUncertain", scopeIncomplete)
        }
        if version.doubleValue == 2 && same(signal, "source_uncertain") && same(name, "AITMPartialTail") {
            return ("AITMPartialTail", scopeIncomplete)
        }
        if version.doubleValue == 1 && same(signal, "uncertain") && same(name, "Unknown") {
            return ("AITMSourceUncertain", scopeIncomplete)
        }
        return nil
    }

    private static func readLines(_ url: URL, consume: (Data) throws -> Void) throws -> SHA256.Digest {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.unsafePath }
        var hash = SHA256()
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            hash.update(data: chunk); pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if !line.isEmpty {
                    guard line.count <= 1_048_576, String(data: line, encoding: .utf8) != nil else { throw Failure.tooLarge }
                    try consume(line)
                }
            }
            guard pending.count <= 1_048_576 else { throw Failure.tooLarge }
        }
        guard pending.isEmpty else { throw Failure.invalidRecord }
        return hash.finalize()
    }

    private static func cleanBackups(_ directory: URL, cutoff: Date, commit: Commit) throws {
        guard exists(directory) else { return }
        try ordinary(directory, directory: true)
        let prefix = "settings.json.ai-task-monitor-backup-"
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && UUID(uuidString: String($0.lastPathComponent.dropFirst(prefix.count))) != nil }
        var backups: [(URL, Date)] = []
        for url in candidates {
            do {
                try ordinary(url, directory: false)
                guard let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                backups.append((url, modified))
            } catch Failure.unsafePath { continue }
        }
        backups.sort { $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1 }
        for (url, modified) in backups.dropFirst() where modified < cutoff {
            try commit {
                try ordinary(url, directory: false)
                guard try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified else { throw Failure.changed }
                guard unlink(url.path) == 0 else { throw Failure.io }
            }
        }
    }

    private static func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    private static func ordinary(_ url: URL, directory: Bool) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { throw Failure.unsafePath }
    }
    private static func older(_ a: Entry, _ b: Entry) -> Bool {
        a.time == b.time ? (a.source == b.source ? a.order < b.order : a.source < b.source) : a.time < b.time
    }
    private static func push(_ item: Entry, into heap: inout [Entry]) {
        heap.append(item); var index = heap.count - 1
        while index > 0 { let parent = (index - 1) / 2; guard older(heap[index], heap[parent]) else { break }; heap.swapAt(index, parent); index = parent }
    }
    private static func pop(_ heap: inout [Entry]) -> Entry? {
        guard !heap.isEmpty else { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let result = heap[0]; heap[0] = heap.removeLast(); var index = 0
        while true {
            let left = index * 2 + 1; guard left < heap.count else { break }
            let right = left + 1; let child = right < heap.count && older(heap[right], heap[left]) ? right : left
            guard older(heap[child], heap[index]) else { break }; heap.swapAt(index, child); index = child
        }
        return result
    }
}
