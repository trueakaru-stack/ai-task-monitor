import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexAmbiguousRootMetadataWorkerTests: XCTestCase {
    func testChangedIncompleteOrUnsupportedCandidateSetsAreNotConfirmed() throws {
        let worker = CodexAmbiguousRootMetadataWorker()
        let id = "019127f4-35ae-7c73-9e72-a10123456789"
        let first = URL(fileURLWithPath: "/synthetic/a.jsonl")
        let second = URL(fileURLWithPath: "/synthetic/b.jsonl")
        let third = URL(fileURLWithPath: "/synthetic/c.jsonl")
        let baseline = [id: [first, second]]
        XCTAssertFalse(worker.poll(candidates: baseline, targets: [id], verify: { _, _ in true }).contains(id))
        worker.waitUntilIdleForTests()
        XCTAssertTrue(worker.poll(candidates: baseline, targets: [id], verify: { _, _ in true }).contains(id))
        worker.waitUntilIdleForTests()
        let changed = [id: [first, second, third]]
        XCTAssertFalse(worker.poll(candidates: changed, targets: [id], verify: { _, _ in false }).contains(id))
        worker.waitUntilIdleForTests()
        XCTAssertFalse(worker.poll(candidates: changed, targets: [id], verify: { _, _ in false }).contains(id))
        worker.waitUntilIdleForTests()
        let tooMany = [id: (0..<9).map { URL(fileURLWithPath: "/synthetic/\($0).jsonl") }]
        XCTAssertFalse(worker.poll(candidates: tooMany, targets: [id], verify: { _, _ in true }).contains(id))
        let compressed = [id: [first, URL(fileURLWithPath: "/synthetic/b.jsonl.zst")]]
        XCTAssertFalse(worker.poll(candidates: compressed, targets: [id], verify: { _, _ in true }).contains(id))
        worker.waitUntilIdleForTests()
    }
}
