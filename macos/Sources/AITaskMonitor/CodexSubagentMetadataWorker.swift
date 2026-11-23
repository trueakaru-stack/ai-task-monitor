import Foundation

/// Reads bounded metadata batches off the interface thread. A caller must
/// compare the returned file stamp with the current candidate before use.
final class CodexSubagentMetadataWorker {
    struct Stamp: Equatable {
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

    struct Observation {
        let file: URL
        let stamp: Stamp
        let parentID: String?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai-task-monitor.codex-subagent-metadata", qos: .utility)
    private var observations: [String: Observation] = [:]
    private var order: [String] = []
    private var running = false
    private var cursor: String?
    private let maximumBatch = 16
    private let maximumCached = 512
    private let maximumNeeded = 32

    func poll(candidates: [String: URL], visibleIDs: Set<String>,
              load: @escaping (String, URL) throws -> Observation) -> [String: Observation] {
        lock.lock()
        defer { lock.unlock() }
        var needed = visibleIDs
        // Follow only known IDs. A missing or conflicting edge never becomes
        // an inferred relationship from a name or a path.
        for _ in 0..<128 {
            let old = needed.count
            for id in Array(needed) {
                guard let entry = observations[id], let parent = entry.parentID else { continue }
                needed.insert(parent)
            }
            if needed.count == old || needed.count >= maximumCached { break }
        }
        let ids = needed.filter { candidates[$0] != nil }.sorted()
        let selected: [String]
        if ids.count <= maximumNeeded {
            selected = ids
        } else {
            let start = cursor.flatMap { last in ids.firstIndex(where: { $0 > last }) } ?? 0
            selected = (0..<maximumNeeded).map { ids[(start + $0) % ids.count] }
        }
        let available = observations.filter { id, entry in
            needed.contains(id) && candidates[id]?.standardizedFileURL == entry.file.standardizedFileURL
        }
        if !running && !selected.isEmpty {
            running = true
            let start = cursor.flatMap { last in selected.firstIndex(where: { $0 > last }) } ?? 0
            let batch = (0..<min(maximumBatch, selected.count)).map { selected[(start + $0) % selected.count] }
            cursor = batch.last
            let request = batch.compactMap { id in candidates[id].map { (id, $0) } }
            queue.async { [self] in
                var updates: [String: Observation] = [:]
                var failed: Set<String> = []
                for (id, url) in request {
                    do { updates[id] = try load(id, url) }
                    catch { failed.insert(id) }
                }
                lock.lock()
                for id in failed { observations.removeValue(forKey: id); order.removeAll { $0 == id } }
                for (id, entry) in updates {
                    order.removeAll { $0 == id }
                    order.append(id)
                    observations[id] = entry
                }
                while order.count > maximumCached {
                    observations.removeValue(forKey: order.removeFirst())
                }
                running = false
                lock.unlock()
            }
        }
        return available
    }

    func waitUntilIdleForTests() { queue.sync {} }
}
