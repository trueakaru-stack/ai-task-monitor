import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexAgentProofSelectionTests: XCTestCase {
    func testRepeatRechecksSameChainsWithoutAdvancingRotation() {
        let selector = CodexAgentProofSelection()
        let chains = Dictionary(uniqueKeysWithValues: (0..<8).map { ("child-\($0)", ["child-\($0)", "root"]) })
        let first = selector.next(chains: chains, maximumNodes: 3)
        let repeated = selector.next(chains: chains, maximumNodes: 3, repeating: first.childIDs)
        XCTAssertEqual(repeated.childIDs, first.childIDs)
        XCTAssertEqual(repeated.nodeIDs, first.nodeIDs)
        XCTAssertTrue(repeated.incomplete)
        let following = selector.next(chains: chains, maximumNodes: 3)
        XCTAssertTrue(first.childIDs.isDisjoint(with: following.childIDs), "Revalidation must not skip the next rotating slice")

        var changed = chains
        let target = first.childIDs.sorted()[0]
        changed[target] = [target, "new-root"]
        let modified = selector.next(chains: changed, maximumNodes: 3, repeating: [target])
        XCTAssertEqual(modified.nodeIDs, [target, "new-root"], "Repeat must inspect the new chain, not reuse old evidence")
        changed.removeValue(forKey: target)
        let missing = selector.next(chains: changed, maximumNodes: 3, repeating: [target])
        XCTAssertTrue(missing.childIDs.isEmpty)
        XCTAssertTrue(missing.incomplete)
    }

    func testPrioritiesKeepRoomForEveryOtherChain() {
        let selector = CodexAgentProofSelection()
        let chains = Dictionary(uniqueKeysWithValues: (0..<70).map {
            (String(format: "child-%03d", $0), [String(format: "child-%03d", $0), "root"])
        })
        let priority = (0..<5).map { String(format: "child-%03d", $0) }
        var visited: Set<String> = []
        for _ in 0..<6 {
            let batch = selector.next(chains: chains, prioritizing: priority)
            XCTAssertLessThanOrEqual(batch.nodeIDs.count, 32)
            XCTAssertTrue(Set(priority).isSubset(of: batch.childIDs))
            XCTAssertTrue(batch.incomplete)
            visited.formUnion(batch.childIDs)
        }
        XCTAssertEqual(visited, Set(chains.keys), "Known agents must not starve new chains")
    }

    func testLongChainGetsFullBudgetAfterPriorityConflict() {
        let selector = CodexAgentProofSelection()
        let priority = (0..<15).map { String(format: "p-%02d", $0) }
        var chains = Dictionary(uniqueKeysWithValues: priority.map { ($0, [$0, "shared-root"]) })
        let long = ["a-long"] + (0..<16).map { "ancestor-\($0)" }
        chains["a-long"] = long
        chains["z-neighbor"] = ["z-neighbor", "root-neighbor"]
        let limited = selector.next(chains: chains, prioritizing: priority)
        XCTAssertTrue(Set(priority).isSubset(of: limited.childIDs))
        XCTAssertFalse(limited.childIDs.contains("a-long"))
        let repeatLimited = selector.next(chains: chains, prioritizing: priority, repeating: limited.childIDs)
        XCTAssertEqual(repeatLimited.childIDs, limited.childIDs)
        let full = selector.next(chains: chains, prioritizing: priority)
        XCTAssertTrue(full.childIDs.contains("a-long"), "A valid long chain must receive the full bounded budget")
        XCTAssertTrue(Set(long).isSubset(of: full.nodeIDs))
        var visited = full.childIDs
        for _ in 0..<5 { visited.formUnion(selector.next(chains: chains, prioritizing: priority).childIDs) }
        XCTAssertTrue(visited.contains("z-neighbor"), "Later chains must also be visited")
    }

    func testBatchesIncludeCompleteChainsAndEventuallyVisitEveryChild() {
        var chains: [String: [String]] = [:]
        for index in 0..<70 {
            let id = String(format: "child-%03d", index)
            chains[id] = [id, "parent", "root"]
        }
        let selector = CodexAgentProofSelection()
        var visited: Set<String> = []
        for _ in 0..<4 {
            let batch = selector.next(chains: chains)
            XCTAssertLessThanOrEqual(batch.nodeIDs.count, 32)
            XCTAssertTrue(batch.incomplete)
            for id in batch.childIDs {
                XCTAssertTrue(Set(chains[id]!).isSubset(of: batch.nodeIDs))
            }
            visited.formUnion(batch.childIDs)
        }
        XCTAssertEqual(visited, Set(chains.keys))
    }

    func testOversizedOrCyclicChainDoesNotPreventOtherChildren() {
        let selector = CodexAgentProofSelection()
        let tooDeep = (0..<33).map { "deep-\($0)" }
        let chains = ["deep-0": tooDeep, "valid": ["valid", "root"],
                      "cycle": ["cycle", "parent", "cycle"]]
        let batch = selector.next(chains: chains)
        XCTAssertEqual(batch.childIDs, ["valid"])
        XCTAssertEqual(batch.nodeIDs, ["valid", "root"])
        XCTAssertTrue(batch.incomplete)
    }

    func testSeparateAncestorsNeverGetSplitAcrossBatches() {
        let selector = CodexAgentProofSelection()
        let chains = ["a": ["a", "middle-a", "root-a"],
                      "b": ["b", "middle-b", "root-b"]]
        let first = selector.next(chains: chains, maximumNodes: 3)
        let second = selector.next(chains: chains, maximumNodes: 3)
        XCTAssertEqual(first.childIDs, ["a"])
        XCTAssertEqual(first.nodeIDs, Set(chains["a"]!))
        XCTAssertEqual(second.childIDs, ["b"])
        XCTAssertEqual(second.nodeIDs, Set(chains["b"]!))
        XCTAssertTrue(first.incomplete && second.incomplete)
    }
}
