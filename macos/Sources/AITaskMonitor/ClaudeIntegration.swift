import Darwin
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
        let destination = try settingsDestination(for: settingsURL)
        let root = try settingsObject(from: readSettingsData(at: destination))
        let hooks = try hooksObject(from: root)
        var connected = false
        for event in events {
            for group in try groupsForEvent(event, in: hooks) {
                if try commandsForGroup(group).contains(where: isOwnedHook) { connected = true }
            }
        }
        return connected
    }

    static func setConnected(_ connect: Bool, settingsURL: URL = AppPaths.claudeSettings,
                             executable: String? = nil, beforeCommit: (() throws -> Void)? = nil) throws {
        let fileManager = FileManager.default
        let destination = try settingsDestination(for: settingsURL)
        let original = try readSettingsData(at: destination)
        if !connect && original == nil { return }
        var root = try settingsObject(from: original)
        var hooks = try hooksObject(from: root)
        let executable = executable ?? executablePath
        let expectedCommand = hookCommand(for: executable)
        var changed = false
        for event in events {
            let groups = try groupsForEvent(event, in: hooks)
            var keptGroups: [[String: Any]] = []
            var hasCurrent = false
            for group in groups {
                guard group["hooks"] != nil else { keptGroups.append(group); continue }
                var updated = group
                var keptCommands: [[String: Any]] = []
                var removedOwned = false
                for command in try commandsForGroup(group) {
                    if isOwnedHook(command, executable: executable) {
                        if connect && (command["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedCommand {
                            hasCurrent = true
                            keptCommands.append(command)
                        } else {
                            changed = true
                            removedOwned = true
                        }
                    } else {
                        keptCommands.append(command)
                    }
                }
                if removedOwned && keptCommands.isEmpty { continue }
                if removedOwned { updated["hooks"] = keptCommands }
                keptGroups.append(updated)
            }
            if connect && !hasCurrent {
                keptGroups.append(["hooks": [["type": "command", "command": expectedCommand, "timeout": 10]]])
                changed = true
            }
            if keptGroups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = keptGroups }
        }
        guard changed else { return }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([0x0A])
        let directory = settingsURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try beforeCommit?()
        try ensureSettingsUnchanged(settingsURL, destination: destination, original: original)
        if original != nil {
            let backup = directory.appendingPathComponent("settings.json.ai-task-monitor-backup-\(UUID().uuidString)")
            try fileManager.copyItem(at: destination, to: backup)
            try ensureSettingsUnchanged(settingsURL, destination: destination, original: original)
        }
        try data.write(to: destination, options: .atomic)
    }

    private static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

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

    private static func readSettingsData(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }

    private static func settingsDestination(for url: URL) throws -> URL {
        let path = url.standardizedFileURL.path
        var info = stat()
        if path.withCString({ lstat($0, &info) }) != 0 {
            if errno == ENOENT { return URL(fileURLWithPath: path) }
            throw IntegrationError.invalidSettingsLink
        }
        let kind = info.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK),
              let resolved = path.withCString({ realpath($0, nil) }) else {
            throw IntegrationError.invalidSettingsLink
        }
        defer { free(resolved) }
        let destination = URL(fileURLWithPath: String(cString: resolved)).standardizedFileURL
        var targetInfo = stat()
        guard destination.path.withCString({ lstat($0, &targetInfo) }) == 0,
              (targetInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw IntegrationError.invalidSettingsLink
        }
        return destination
    }

    private static func ensureSettingsUnchanged(_ settingsURL: URL, destination: URL, original: Data?) throws {
        let currentDestination = try settingsDestination(for: settingsURL)
        guard currentDestination == destination, try readSettingsData(at: destination) == original else {
            throw IntegrationError.settingsChanged
        }
    }

    private static func settingsObject(from data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let settings = value as? [String: Any] else { throw IntegrationError.invalidSettings }
        return settings
    }

    private static func hooksObject(from root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw IntegrationError.invalidSettings }
        return hooks
    }

    private static func groupsForEvent(_ event: String, in hooks: [String: Any]) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw IntegrationError.invalidSettings }
        return groups
    }

    private static func commandsForGroup(_ group: [String: Any]) throws -> [[String: Any]] {
        guard let value = group["hooks"] else { return [] }
        guard let commands = value as? [[String: Any]] else { throw IntegrationError.invalidSettings }
        return commands
    }

    private enum IntegrationError: LocalizedError {
        case invalidSettings
        case invalidSettingsLink
        case settingsChanged
        var errorDescription: String? {
            switch self {
            case .invalidSettings: return "Настройки Claude Code имеют неподдерживаемый формат и не были изменены."
            case .invalidSettingsLink: return "Файл настроек Claude Code недоступен или содержит некорректную ссылку. Изменения не внесены."
            case .settingsChanged: return "Настройки Claude Code изменились во время подключения. Попробуйте ещё раз."
            }
        }
    }
}
