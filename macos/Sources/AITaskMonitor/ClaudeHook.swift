import Foundation
import Darwin

enum ClaudeHook {
    static func run() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 1_048_576,
              let value = try? JSONSerialization.jsonObject(with: data),
              let input = value as? [String: Any] else { return 0 }

        let record = makeRecord(from: input)
        do {
            try FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            let lockPath = AppPaths.supportDirectory.appendingPathComponent("claude-events.lock").path
            let lockDescriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
            guard lockDescriptor >= 0 else { throw HookError.lock }
            defer { Darwin.close(lockDescriptor) }
            guard flock(lockDescriptor, LOCK_EX) == 0 else { throw HookError.lock }
            defer { flock(lockDescriptor, LOCK_UN) }
            try rotateIfNeeded()
            let line = try JSONSerialization.data(withJSONObject: record) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: AppPaths.claudeEvents.path) {
                FileManager.default.createFile(atPath: AppPaths.claudeEvents.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: AppPaths.claudeEvents)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return 0
        } catch {
            return ProcessInfo.processInfo.environment["AI_TASK_MONITOR_AUDIT"] == "1" ? 1 : 0
        }
    }

    static func makeRecord(from input: [String: Any]) -> [String: Any] {
        let toolInput = input.object("tool_input") ?? [:]
        let eventName = input.string("hook_event_name").isEmpty ? "Unknown" : input.string("hook_event_name")
        let toolName = FileHelpers.normalized(input.string("tool_name"), limit: 120)
        let subject = FileHelpers.normalized(input.string("task_subject").isEmpty ? toolInput.string("subject") : input.string("task_subject"), limit: 240)
        let taskID = input.string("task_id").isEmpty ? (toolInput.string("taskId").isEmpty ? toolInput.string("task_id") : toolInput.string("taskId")) : input.string("task_id")
        let active = !["Stop", "SessionEnd", "StopFailure"].contains(eventName)
        return [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "provider": "claude",
            "session_id": input.string("session_id"),
            "event": eventName,
            "active": active,
            "activity": activity(event: eventName, tool: toolName, subject: subject),
            "task_id": taskID,
            "task_subject": subject,
            "task_status": toolInput.string("status"),
            "tool_name": toolName
        ]
    }

    private static func activity(event: String, tool: String, subject: String) -> String {
        switch event {
        case "UserPromptSubmit": return "New request"
        case "PreToolUse": return tool.isEmpty ? "Running tool" : "Running: \(tool)"
        case "PostToolUse": return tool.isEmpty ? "Tool completed" : "Completed: \(tool)"
        case "PostToolUseFailure": return tool.isEmpty ? "Tool failed" : "Failed: \(tool)"
        case "TaskCreated": return subject.isEmpty ? "Added step" : "Added step: \(subject)"
        case "TaskCompleted": return subject.isEmpty ? "Completed step" : "Completed step: \(subject)"
        case "SubagentStart": return "Subagent started"
        case "SubagentStop": return "Subagent stopped"
        case "Stop": return "Waiting for the next request"
        case "SessionEnd": return "Session ended"
        default: return event
        }
    }

    private static func rotateIfNeeded() throws {
        guard let size = (try? AppPaths.claudeEvents.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 8_388_608 else { return }
        let tail = try FileHelpers.tail(of: AppPaths.claudeEvents, maximumBytes: 4_194_304)
        let trimmed = tail.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        try Data(trimmed.utf8).write(to: AppPaths.claudeEvents, options: .atomic)
    }

    private enum HookError: Error { case lock }
}
