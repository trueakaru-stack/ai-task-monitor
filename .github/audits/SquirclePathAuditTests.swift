import CoreGraphics
import SwiftUI
import XCTest
@testable import AITaskMonitor

/// Exports the untransformed native paths for comparison with the Windows tabs.
final class SquirclePathAuditTests: XCTestCase {
    @MainActor func testExportSyntheticTabPaths() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_EXPORT_SQUIRCLE"] == "1" else {
            throw XCTSkip("Squircle path export is opt-in.")
        }
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1", env["GITHUB_ACTIONS"] == "true",
              env["CI"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", let temporary = env["RUNNER_TEMP"],
              let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticSquircleAudit", code: 1)
        }
        let fixtures: [(name: String, width: CGFloat, height: CGFloat, radius: CGFloat)] = [
            ("tabs-reference", 520, 42, 14),
            ("tab-reference", 168, 34, 10),
            ("tabs-wide-synthetic", 820, 42, 14),
            ("tab-wide-synthetic", 268, 34, 10)
        ]
        var records: [[String: Any]] = []
        for fixture in fixtures {
            let rect = CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height)
            let path = Squircle(radius: fixture.radius).path(in: rect).cgPath
            XCTAssertFalse(path.isEmpty, "The synthetic shape must have a path.")
            var elements: [[String: Any]] = []
            var unsupportedType = false
            path.applyWithBlock { pointer in
                let element = pointer.pointee
                let name: String
                let pointCount: Int
                switch element.type {
                case .moveToPoint: name = "move"; pointCount = 1
                case .addLineToPoint: name = "line"; pointCount = 1
                case .addQuadCurveToPoint: name = "quadratic"; pointCount = 2
                case .addCurveToPoint: name = "cubic"; pointCount = 3
                case .closeSubpath: name = "close"; pointCount = 0
                @unknown default: name = "unknown"; pointCount = 0; unsupportedType = true
                }
                let points = (0..<pointCount).map { index in
                    let point = element.points[index]
                    return [Double(point.x), Double(point.y)]
                }
                elements.append(["type": name, "points": points])
            }
            XCTAssertFalse(unsupportedType, "The path contains an unsupported element type.")
            XCTAssertEqual(elements.first?["type"] as? String, "move")
            XCTAssertEqual(elements.last?["type"] as? String, "close")
            let bounds = path.boundingBoxOfPath
            records.append(["name": fixture.name, "radius": Double(fixture.radius),
                            "rect": [0, 0, Double(fixture.width), Double(fixture.height)],
                            "bounds": [Double(bounds.minX), Double(bounds.minY),
                                       Double(bounds.width), Double(bounds.height)],
                            "elements": elements])
        }
        let report: [String: Any] = ["platform": ProcessInfo.processInfo.operatingSystemVersionString,
                                     "coordinates": "Untransformed CGPath points in the supplied rectangle.",
                                     "shapes": records]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("squircle-paths.json"), options: .atomic)
    }
}
