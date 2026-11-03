import Foundation
import Darwin

enum ClaudeHook {
    static func run() -> Int32 {
        guard let data = readBoundedInput(FileHandle.standardInput),
              let value = try? JSONSerialization.jsonObject(with: data),
              let input = value as? [String: Any] else { return 0 }
        return process(input)
    }

    static func process(_ input: [String: Any], directory: URL = AppPaths.supportDirectory) -> Int32 {
        let record = makeRecord(from: input)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let events = directory.appendingPathComponent("claude-events-v2.jsonl")
            let lockPath = directory.appendingPathComponent("claude-events.lock").path
            let lockDescriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR) }
            guard lockDescriptor >= 0 else { throw HookError.lock }
            defer { Darwin.close(lockDescriptor) }
            guard flock(lockDescriptor, LOCK_EX) == 0 else { throw HookError.lock }
            defer { flock(lockDescriptor, LOCK_UN) }
            try rotateIfNeeded(at: events)
            let line = try JSONSerialization.data(withJSONObject: record) + Data([0x0A])
            if !FileManager.default.fileExists(atPath: events.path) {
                FileManager.default.createFile(atPath: events.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: events)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            ClaudeLoopClient.send(input, profile: directory)
            return 0
        } catch {
            return ProcessInfo.processInfo.environment["AI_TASK_MONITOR_AUDIT"] == "1" ? 1 : 0
        }
    }

    static func readBoundedInput(_ handle: FileHandle, maximumBytes: Int = 1_048_576) -> Data? {
        precondition(maximumBytes >= 0 && maximumBytes < Int.max)
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let chunk = handle.readData(ofLength: min(4096, remaining))
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        return nil
    }

    static func makeRecord(from input: [String: Any]) -> [String: Any] {
        let toolInput = input.object("tool_input") ?? [:]
        let eventName = input.string("hook_event_name").isEmpty ? "Unknown" : input.string("hook_event_name")
        let toolName = FileHelpers.normalized(input.string("tool_name"), limit: 120)
        let subject = FileHelpers.normalized(input.string("task_subject").isEmpty ? toolInput.string("subject") : input.string("task_subject"), limit: 240)
        let taskID = input.string("task_id").isEmpty ? (toolInput.string("taskId").isEmpty ? toolInput.string("task_id") : toolInput.string("taskId")) : input.string("task_id")
        let active = !["Stop", "SessionEnd", "StopFailure"].contains(eventName)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "timestamp": formatter.string(from: Date()),
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

    private static func rotateIfNeeded(at events: URL) throws {
        guard let size = (try? events.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > 8_388_608 else { return }
        let tail = try FileHelpers.tail(of: events, maximumBytes: 4_194_304)
        let trimmed = tail.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        try Data(trimmed.utf8).write(to: events, options: .atomic)
    }

    private enum HookError: Error { case lock }
}
