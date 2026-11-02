import Foundation

enum ClaudeIntegration {
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]

    static var isClaudeInstalled: Bool {
        FileManager.default.fileExists(atPath: AppPaths.claudeSettings.deletingLastPathComponent().path)
    }

    static var isConnected: Bool {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
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
        var root = readSettings() ?? [:]
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

    private static var hookCommand: String {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "\"\(executable.replacingOccurrences(of: "\"", with: "\\\""))\" --claude-hook"
    }

    private static func isOwnedHook(_ hook: [String: Any]) -> Bool {
        let command = hook["command"] as? String ?? ""
        return command.contains("AI Task Monitor.app/Contents/MacOS/AITaskMonitor") && command.contains("--claude-hook")
    }

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: AppPaths.claudeSettings), !data.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
