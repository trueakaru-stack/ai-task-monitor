import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexAgentProofSelectionTests: XCTestCase {
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
