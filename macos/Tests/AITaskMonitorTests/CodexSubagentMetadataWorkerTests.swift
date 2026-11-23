import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexSubagentMetadataWorkerTests: XCTestCase {
    private func stamp() throws -> CodexSubagentMetadataWorker.Stamp {
        try XCTUnwrap(CodexSubagentMetadataWorker.Stamp([
            .systemNumber: NSNumber(value: 1), .systemFileNumber: NSNumber(value: 2),
            .size: NSNumber(value: 3), .modificationDate: Date(timeIntervalSince1970: 1_000)
        ]))
    }

    func testBlockedReadDoesNotBlockPoll() throws {
        let worker = CodexSubagentMetadataWorker()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let id = "019127f4-35ae-7c73-9e72-a10123456789"
        let file = URL(fileURLWithPath: "/synthetic/one")
        let proof = try stamp()
        defer { release.signal(); worker.waitUntilIdleForTests() }
        _ = worker.poll(candidates: [id: file], visibleIDs: [id]) { _, url in
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            return .init(file: url, stamp: proof, parentID: nil)
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = ProcessInfo.processInfo.systemUptime
        _ = worker.poll(candidates: [id: file], visibleIDs: [id]) { _, url in
            .init(file: url, stamp: proof, parentID: nil)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
    }

    func testLargeInputReadsBoundedBatchesAndAdvances() throws {
        let worker = CodexSubagentMetadataWorker()
        let proof = try stamp()
        let ids = (1...50).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let candidates = Dictionary(uniqueKeysWithValues: ids.map { ($0, URL(fileURLWithPath: "/synthetic/" + $0)) })
        let lock = NSLock()
        var seen: Set<String> = []
        let load: (String, URL) throws -> CodexSubagentMetadataWorker.Observation = { id, url in
            lock.lock(); seen.insert(id); lock.unlock()
            return .init(file: url, stamp: proof, parentID: nil)
        }
        for _ in 0..<5 {
            _ = worker.poll(candidates: candidates, visibleIDs: Set(ids), load: load)
            worker.waitUntilIdleForTests()
        }
        lock.lock()
        let unique = seen.count
        lock.unlock()
        XCTAssertEqual(unique, ids.count)
    }
}
