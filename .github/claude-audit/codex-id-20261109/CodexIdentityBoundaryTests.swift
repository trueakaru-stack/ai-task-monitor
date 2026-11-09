import Foundation
import XCTest
@testable import AITaskMonitor

final class CodexIdentityBoundaryTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aitm-codex-id-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeIndex(_ ids: [String], at url: URL) throws {
        let lines = try ids.map { id in
            String(decoding: try JSONSerialization.data(withJSONObject: ["id": id, "thread_name": "Тестовый заголовок"]), as: UTF8.self)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }

    func testSupportedIDsAndUnicodeTitlesRemainReadable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.jsonl")
        let ids = ["019127f4-35ae-7c73-9e72-a10123456789", "Synthetic_One-2", String(repeating: "a", count: 128)]
        try writeIndex(ids, at: index)
        let sessions = try CodexSessionIndexCache().read(from: index)
        XCTAssertEqual(Set(sessions.keys), Set(ids))
        XCTAssertEqual(sessions[ids[0]]?.string("thread_name"), "Тестовый заголовок")
    }

    func testOtherProviderNamespacesAndUnsupportedIDsFailBeforeCache() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.jsonl")
        let cache = CodexSessionIndexCache()
        try writeIndex(["safe-session"], at: index)
        XCTAssertNotNil(try cache.read(from: index)["safe-session"])
        for invalid in ["claude:~c3a9", "codex-cloud:hash", "kimi:one", "deepseek:one", "hermes:one", "opencode:one",
                        "é", "e\u{301}", "white space", "dot.name", "slash/name", "\u{0000}", String(repeating: "a", count: 129)] {
            try writeIndex(["safe-session", invalid], at: index)
            XCTAssertThrowsError(try cache.read(from: index), "Unsupported ID unexpectedly entered the cache")
        }
        try writeIndex(["safe-session", "other-session"], at: index)
        XCTAssertEqual(Set(try cache.read(from: index).keys), Set(["safe-session", "other-session"]))
    }

    @MainActor
    func testCollisionMakesCodexUnavailableWithoutHidingClaude() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let index = codex.appendingPathComponent("session_index.jsonl")
        try writeIndex(["safe-session"], at: index)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date().addingTimeInterval(2))
        let codexEvent = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"synthetic"}}"# + "\n"
        try Data(codexEvent.utf8).write(to: sessions.appendingPathComponent("rollout-safe-session.jsonl"))
        let claude = root.appendingPathComponent("claude.jsonl")
        let claudeEvent = #"{"timestamp":"\#(timestamp)","session_id":"other","event":"UserPromptSubmit","active":true}"# + "\n"
        try Data(claudeEvent.utf8).write(to: claude)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: codex),
                              claudeReader: ClaudeTaskReader(eventFile: claude),
                              journal: DiagnosticJournal(directory: root.appendingPathComponent("journal")))
        store.refresh()
        XCTAssertTrue(store.tasks.contains { $0.provider == .codex && $0.id == "safe-session" && $0.isActive })
        XCTAssertTrue(store.tasks.contains { $0.provider == .claude && $0.id == "claude:other" && $0.isActive })
        try writeIndex(["claude:other"], at: index)
        store.refresh()
        XCTAssertTrue(store.unavailableSources.contains(.codex))
        XCTAssertTrue(store.tasks.contains { $0.provider == .codex && $0.id == "safe-session" && $0.isUnconfirmed })
        XCTAssertTrue(store.tasks.contains { $0.provider == .claude && $0.id == "claude:other" && $0.isActive })
    }
}
