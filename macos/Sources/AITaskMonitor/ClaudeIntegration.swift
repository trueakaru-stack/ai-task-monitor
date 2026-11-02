import Foundation

enum ClaudeIntegration {
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]

    static var isClaudeInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.claudeSettings.deletingLastPathComponent().path)
    }

    static var isConnected: Bool {
        (try? connectionState()) ?? false
    }

    static func connectionState(settingsURL: URL = AppPaths.claudeSettings) throws -> Bool {
        let data: Data
        do { data = try Data(contentsOf: settingsURL) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return false }
        guard !data.isEmpty else { return false }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw IntegrationError.invalidSettings }
        guard let value = root["hooks"] else { return false }
        guard let hooks = value as? [String: Any] else { throw IntegrationError.invalidSettings }
        return events.contains { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains(where: isOwnedHook) == true
            }
        }
    }

    static func setConnected(_ connect: Bool) throws {
        let directory = AppPaths.claudeSettings.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = try readSettings()
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if connect, FileManager.default.fileExists(atPath: AppPaths.claudeSettings.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try FileManager.default.copyItem(at: AppPaths.claudeSettings, to: directory.appendingPathComponent("settings.json.ai-task-monitor-backup-\(stamp)"))
        }
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                var updated = group
                guard var commands = group["hooks"] as? [[String: Any]] else { return connect ? group : group }
                commands.removeAll(where: isOwnedHook)
                guard !commands.isEmpty else { return nil }
                updated["hooks"] = commands
                return updated
            }
            if connect {
                groups.append(["hooks": [["type": "command", "command": hookCommand, "timeout": 10]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A])
        try data.write(to: AppPaths.claudeSettings, options: .atomic)
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    private static var hookCommand: String { hookCommand(for: executablePath) }

    static func hookCommand(for executable: String) -> String {
        "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "' --claude-hook"
    }

    private static func isOwnedHook(_ hook: [String: Any]) -> Bool {
        isOwnedHook(hook, executable: executablePath)
    }

    static func isOwnedHook(_ hook: [String: Any], executable: String) -> Bool {
        guard hook.keys.allSatisfy({ ["type", "command", "timeout"].contains($0) }),
              hook["type"] as? String == "command",
              let command = hook["command"] as? String else { return false }
        let legacy = "\"\(executable.replacingOccurrences(of: "\"", with: "\\\""))\" --claude-hook"
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == hookCommand(for: executable) || normalized == legacy
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: AppPaths.claudeSettings.path) else { return [:] }
        let data = try Data(contentsOf: AppPaths.claudeSettings)
        guard !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let settings = value as? [String: Any] else { throw IntegrationError.invalidSettings }
        return settings
    }

    private enum IntegrationError: LocalizedError {
        case invalidSettings
        var errorDescription: String? { "Настройки Claude Code имеют неподдерживаемый формат и не были изменены." }
    }
}
