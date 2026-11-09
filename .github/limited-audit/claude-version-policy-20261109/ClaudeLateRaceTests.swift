import Foundation
import XCTest
@testable import AITaskMonitor

// Counterexample fixture only. Run with the test-only ClaudeIntegration copy;
// its seam models the timing of an unrelated writer using synthetic files.
// The assertions demonstrate the current defect and are not release criteria.
final class ClaudeLateRaceTests: XCTestCase {
    private let executable = "/synthetic/AI Task Monitor"
    private let initial = Data("{\"foreign\":\"before\"}".utf8)
    private let concurrent = Data("{\"foreign\":\"newer-by-other-writer\"}".utf8)

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-late-race-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func foreignValue(_ settings: URL) throws -> String? {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        return root["foreign"] as? String
    }

    private func backups(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.ai-task-monitor-backup-") }
    }

    func testEarlierConcurrentEditIsDetectedAndPreserved() throws {
        try withDirectory { root in
            let settings = root.appendingPathComponent("settings.json")
            try initial.write(to: settings)
            XCTAssertThrowsError(try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable, beforeCommit: {
                try self.concurrent.write(to: settings, options: .atomic)
            }))
            XCTAssertEqual(try Data(contentsOf: settings), concurrent)
            XCTAssertTrue(try backups(root).isEmpty)
        }
    }

    func testLateConcurrentEditAfterCheckIsOverwrittenDespiteAtomicWrite() throws {
        try withDirectory { root in
            let settings = root.appendingPathComponent("settings.json")
            try initial.write(to: settings)
            var laterWriterRan = false
            try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable, beforeAtomicWrite: {
                try self.concurrent.write(to: settings, options: .atomic)
                laterWriterRan = true
            })
            XCTAssertTrue(laterWriterRan)
            XCTAssertEqual(try foreignValue(settings), "before", "The late foreign edit is lost in the present implementation")
            XCTAssertNotEqual(try Data(contentsOf: settings), concurrent)
            let saved = try XCTUnwrap(backups(root).first)
            XCTAssertEqual(try Data(contentsOf: saved), initial)
        }
    }

    func testLateCreationAfterMissingFileCheckIsOverwrittenWithoutBackup() throws {
        try withDirectory { root in
            let settings = root.appendingPathComponent("settings.json")
            var laterWriterRan = false
            try ClaudeIntegration.setConnected(true, settingsURL: settings, executable: executable, beforeAtomicWrite: {
                try self.concurrent.write(to: settings, options: .atomic)
                laterWriterRan = true
            })
            XCTAssertTrue(laterWriterRan)
            XCTAssertNil(try foreignValue(settings), "The other writer's newly created member is lost")
            XCTAssertTrue(try backups(root).isEmpty)
        }
    }
}
