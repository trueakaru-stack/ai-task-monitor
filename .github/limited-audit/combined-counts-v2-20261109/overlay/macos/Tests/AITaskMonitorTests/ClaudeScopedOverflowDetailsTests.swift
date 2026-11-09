import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeScopedOverflowDetailsTests: XCTestCase {
    func testOverflowNamesOnlyAffectedSession() throws {
        let result = try ClaudeScopedOverflowFixture.make()
        XCTAssertEqual(result.titleHistoryOverflowIDs, ["claude:case"])
        XCTAssertFalse(result.sourceUncertain)
    }
}
