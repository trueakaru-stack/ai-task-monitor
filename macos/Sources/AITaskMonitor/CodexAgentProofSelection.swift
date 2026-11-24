import Foundation

// The reader uses cached links only to choose which files to inspect. Every
// selected header is verified again before it can become evidence.
final class CodexAgentProofSelection {
    struct Batch {
        let childIDs: Set<String>
        let nodeIDs: Set<String>
        let incomplete: Bool
    }

    private let lock = NSLock()
    private var previousChild: String?
    private var fullBudgetNext = false

    func next(chains: [String: [String]], maximumNodes: Int = 32,
              prioritizing: [String] = [], repeating: Set<String>? = nil) -> Batch {
        precondition(maximumNodes > 0)
        lock.lock(); defer { lock.unlock() }
        let children = chains.keys.sorted()
        var nodes: Set<String> = []
        var included: Set<String> = []
        var incomplete = false

        if let repeating {
            for child in repeating.sorted() {
                guard let chain = chains[child], chain.first == child, !chain.isEmpty,
                      Set(chain).count == chain.count, chain.count <= maximumNodes else {
                    incomplete = true
                    continue
                }
                let needed = Set(chain).subtracting(nodes)
                guard nodes.count + needed.count <= maximumNodes else { incomplete = true; continue }
                nodes.formUnion(needed)
                included.insert(child)
            }
            // A repeated selection does not move the ordinary rotation cursor.
            return Batch(childIDs: included, nodeIDs: nodes, incomplete: incomplete || included.count != children.count)
        }

        guard !children.isEmpty else { return Batch(childIDs: [], nodeIDs: [], incomplete: false) }
        // Preserve room for newly observed tasks: priority is capped at half
        // of the node budget, while the rest continues its round-robin scan.
        // If a valid chain cannot coexist with those priorities, give the
        // next regular pass the full budget so that it cannot starve.
        let priorityLimit = fullBudgetNext ? 0 : maximumNodes / 2
        fullBudgetNext = false
        for child in prioritizing where !included.contains(child) {
            guard let chain = chains[child], chain.first == child, !chain.isEmpty,
                  Set(chain).count == chain.count, chain.count <= maximumNodes else { continue }
            let needed = Set(chain).subtracting(nodes)
            guard nodes.count + needed.count <= priorityLimit else { continue }
            nodes.formUnion(needed)
            included.insert(child)
        }
        let priorityNodes = nodes
        let first = previousChild.flatMap { previous in children.firstIndex(where: { $0 > previous }) } ?? 0
        for offset in children.indices {
            let child = children[(first + offset) % children.count]
            if included.contains(child) { continue }
            guard let chain = chains[child], chain.first == child,
                  !chain.isEmpty, Set(chain).count == chain.count else {
                incomplete = true
                previousChild = child
                continue
            }
            let needed = Set(chain).subtracting(nodes)
            if chain.count > maximumNodes {
                incomplete = true
                previousChild = child
                continue
            }
            guard nodes.count + needed.count <= maximumNodes else {
                incomplete = true
                if !priorityNodes.isEmpty && priorityNodes.union(chain).count > maximumNodes { fullBudgetNext = true }
                break
            }
            nodes.formUnion(needed)
            included.insert(child)
            previousChild = child
        }
        return Batch(childIDs: included, nodeIDs: nodes, incomplete: incomplete || included.count != children.count)
    }
}
