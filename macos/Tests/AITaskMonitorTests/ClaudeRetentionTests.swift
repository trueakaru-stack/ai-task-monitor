import Darwin
import Foundation
import XCTest
@testable import AITaskMonitor

final class ClaudeRetentionTests: XCTestCase {
    func testCleanupHonorsAgeSizeAndPreservesNewestBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-retention-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let backups = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(), legacy = data.appendingPathComponent("claude-events.jsonl"), current = data.appendingPathComponent("claude-events-v2.jsonl")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func event(_ date: Date, _ marker: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: date), "marker": marker]) + Data([10])
        }
        try (event(now.addingTimeInterval(-8 * 86_400), "expired") + event(now.addingTimeInterval(-60), "recent")).write(to: legacy)
        try event(now, "newest").write(to: current)
        let first = backups.appendingPathComponent("settings.json.ai-task-monitor-backup-\(UUID().uuidString)")
        let second = backups.appendingPathComponent("settings.json.ai-task-monitor-backup-\(UUID().uuidString)")
        let foreign = backups.appendingPathComponent("settings.json.ai-task-monitor-backup-foreign")
        for url in [first, second, foreign] { try Data("backup".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-40 * 86_400)], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31 * 86_400)], ofItemAtPath: second.path)
        let policy = ClaudeRetentionPolicy(days: 7, maximumMB: 1)
        try ClaudeRetention.clean(directory: data, backups: backups, now: now, policy: policy)
        XCTAssertFalse(String(decoding: try Data(contentsOf: legacy), as: UTF8.self).contains("expired"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: legacy), as: UTF8.self).contains("recent"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))

        let older = try event(now.addingTimeInterval(-60), String(repeating: "a", count: 700))
        let newer = try event(now, String(repeating: "b", count: 700))
        try Data(repeating: 0, count: 0).write(to: legacy)
        let oldHandle = try FileHandle(forWritingTo: legacy)
        for _ in 0..<1_000 { try oldHandle.write(contentsOf: older) }
        try oldHandle.close()
        try Data(repeating: 0, count: 0).write(to: current)
        let newHandle = try FileHandle(forWritingTo: current)
        for _ in 0..<1_000 { try newHandle.write(contentsOf: newer) }
        try newHandle.close()
        try ClaudeRetention.clean(directory: data, backups: backups, now: now, policy: policy)
        let oldData = try Data(contentsOf: legacy), newData = try Data(contentsOf: current)
        XCTAssertLessThanOrEqual(oldData.count + newData.count, 1_000_000)
        XCTAssertTrue(String(decoding: newData, as: UTF8.self).contains(String(repeating: "b", count: 100)))
    }

    func testMalformedBusyAndLinkedEventsNeverOverwriteTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-retention-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true), backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let event = data.appendingPathComponent("claude-events-v2.jsonl"), now = Date(), policy = ClaudeRetentionPolicy(days: 7, maximumMB: 1)
        let invalid = Data("not-json\n".utf8)
        try invalid.write(to: event)
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: data, backups: backups, now: now, policy: policy))
        XCTAssertEqual(try Data(contentsOf: event), invalid)
        let lock = open(data.appendingPathComponent("claude-events.lock").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(lock, 0)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: data, backups: backups, now: now, policy: policy))
        flock(lock, LOCK_UN); close(lock)
        XCTAssertEqual(try Data(contentsOf: event), invalid)
        try FileManager.default.removeItem(at: event)
        let outside = root.appendingPathComponent("outside.jsonl")
        try invalid.write(to: outside)
        try FileManager.default.createSymbolicLink(at: event, withDestinationURL: outside)
        XCTAssertThrowsError(try ClaudeRetention.clean(directory: data, backups: backups, now: now, policy: policy))
        XCTAssertEqual(try Data(contentsOf: outside), invalid)
    }

    func testPolicyDefaultsOverridesAndInvalidValues() throws {
        let suite = "aitm-retention-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("Cannot create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ClaudeRetentionPolicy.load(from: defaults), ClaudeRetentionPolicy(days: 7, maximumMB: 10))
        defaults.set(30, forKey: "claudeRetentionDays"); defaults.set(100, forKey: "claudeMaximumMB")
        XCTAssertEqual(ClaudeRetentionPolicy.load(from: defaults), ClaudeRetentionPolicy(days: 30, maximumMB: 100))
        defaults.set(31, forKey: "claudeRetentionDays")
        XCTAssertNil(ClaudeRetentionPolicy.load(from: defaults))
    }
}
