import Foundation
import XCTest
@testable import AITaskMonitor

@MainActor
func waitForCodexRead(_ store: TaskStore, timeout: TimeInterval = 5,
                      file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while store.testCodexReadInFlight && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertFalse(store.testCodexReadInFlight, "The source read did not finish", file: file, line: line)
}
