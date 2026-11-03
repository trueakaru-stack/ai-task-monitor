import Foundation
import XCTest
@testable import AITaskMonitor

final class ActivityIndicatorTests: XCTestCase {
    func testIndicatorStretchesTravelsAndReturns() {
        let cases: [(TimeInterval, CGFloat, CGFloat)] = [
            (0, 4, 0), (0.225, 10, 0), (0.45, 16, 0),
            (0.675, 10, 6), (0.9, 4, 12),
            (1.125, 10, 6), (1.35, 16, 0), (1.8, 4, 0)
        ]
        for (time, expectedWidth, expectedOffset) in cases {
            let geometry = ActivityIndicatorGeometry.at(time)
            XCTAssertEqual(geometry.width, expectedWidth, accuracy: 0.0001)
            XCTAssertEqual(geometry.offsetX, expectedOffset, accuracy: 0.0001)
        }
    }

    func testCycleWrapsAndRemainsWithinItsReservedWidth() {
        for step in 0...180 {
            let geometry = ActivityIndicatorGeometry.at(Double(step) / 100)
            XCTAssertGreaterThanOrEqual(geometry.width, 4)
            XCTAssertLessThanOrEqual(geometry.width, 16)
            XCTAssertGreaterThanOrEqual(geometry.offsetX, 0)
            XCTAssertLessThanOrEqual(geometry.offsetX + geometry.width, 16.0001)
        }
        XCTAssertEqual(ActivityIndicatorGeometry.at(-0.45).width, ActivityIndicatorGeometry.at(1.35).width, accuracy: 0.0001)
    }
}
