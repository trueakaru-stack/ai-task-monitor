import Foundation

enum AppPaths {
    static let supportDirectory: URL = {
        if let override = ProcessInfo.processInfo.environment["AI_TASK_MONITOR_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI Task Monitor", isDirectory: true)
    }()

    static let claudeEvents = supportDirectory.appendingPathComponent("claude-events-v2.jsonl")
    static let legacyClaudeEvents = supportDirectory.appendingPathComponent("claude-events.jsonl")
    static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")
}
