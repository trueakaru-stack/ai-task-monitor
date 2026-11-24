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

    func next(chains: [String: [String]], maximumNodes: Int = 32) -> Batch {
        precondition(maximumNodes > 0)
        lock.lock(); defer { lock.unlock() }
        let children = chains.keys.sorted()
        guard !children.isEmpty else { return Batch(childIDs: [], nodeIDs: [], incomplete: false) }
        let first = previousChild.flatMap { previous in children.firstIndex(where: { $0 > previous }) } ?? 0
        var nodes: Set<String> = []
        var included: Set<String> = []
        var incomplete = false
        for offset in children.indices {
            let child = children[(first + offset) % children.count]
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
                break
            }
            nodes.formUnion(needed)
            included.insert(child)
            previousChild = child
        }
        return Batch(childIDs: included, nodeIDs: nodes, incomplete: incomplete)
    }
}
