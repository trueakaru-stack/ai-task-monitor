import Foundation

/// Checks bounded sets of competing rollout headers off the UI thread.
/// A proof never chooses an active rollout or establishes task completion.
final class CodexAmbiguousRootMetadataWorker {
    private struct Proof {
        let paths: Set<String>
        let checkedAt: TimeInterval
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai-task-monitor.codex-ambiguous-root-metadata", qos: .utility)
    private var proofs: [String: Proof] = [:]
    private var running = false
    private var cursor: String?
    private let maximumIDs = 8
    private let maximumVersions = 8
    private let maximumCached = 64

    func poll(candidates: [String: [URL]], targets: Set<String>,
              verify: @escaping (String, [URL]) -> Bool) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let eligible = targets.filter { id in
            guard UUID(uuidString: id) != nil, let files = candidates[id],
                  files.count >= 2, files.count <= maximumVersions else { return false }
            return files.allSatisfy { $0.lastPathComponent.hasSuffix(".jsonl") }
        }.sorted()
        let eligibleIDs = Set(eligible)
        let paths = Dictionary(uniqueKeysWithValues: eligible.compactMap { id in
            candidates[id].map { (id, Set($0.map { $0.standardizedFileURL.path })) }
        })
        let now = ProcessInfo.processInfo.systemUptime
        proofs = proofs.filter { id, proof in
            eligibleIDs.contains(id) && paths[id] == proof.paths && now - proof.checkedAt <= 10
        }
        let available = Set(proofs.keys)
        if !running && !eligible.isEmpty {
            running = true
            let start = cursor.flatMap { last in eligible.firstIndex(where: { $0 > last }) } ?? 0
            let batch = (0..<min(maximumIDs, eligible.count)).map { eligible[(start + $0) % eligible.count] }
            cursor = batch.last
            let requests = batch.compactMap { id in candidates[id].map { (id, $0) } }
            queue.async { [self] in
                var results: [String: Proof] = [:]
                for (id, files) in requests where verify(id, files) {
                    results[id] = Proof(paths: Set(files.map { $0.standardizedFileURL.path }),
                                        checkedAt: ProcessInfo.processInfo.systemUptime)
                }
                lock.lock()
                for (id, _) in requests { proofs.removeValue(forKey: id) }
                for (id, proof) in results where proofs.count < maximumCached { proofs[id] = proof }
                running = false
                lock.unlock()
            }
        }
        return available
    }

    func waitUntilIdleForTests() { queue.sync {} }
}
