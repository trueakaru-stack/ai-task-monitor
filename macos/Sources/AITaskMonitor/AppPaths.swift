import Foundation

enum AppPaths {
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI Task Monitor", isDirectory: true)
    }()

    static let claudeEvents = supportDirectory.appendingPathComponent("claude-events.jsonl")
    static let claudeSettings = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("settings.json")
}
