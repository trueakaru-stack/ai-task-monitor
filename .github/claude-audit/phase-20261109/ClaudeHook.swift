import Foundation
import CoreFoundation
import Darwin
import Dispatch

enum ClaudeHook {
    static func run() -> Int32 {
        guard let data = readBoundedInput(FileHandle.standardInput),
              let input = ClaudeJSONValidation.object(data) else {
            // Unknown input may have changed a plan. Persist a minimal source
            // uncertainty marker; never persist the malformed input itself.
            return process(["hook_event_name": "Unknown", "session_id": ""])
        }
        return process(input)
    }

    static func process(_ input: [String: Any], directory: URL = AppPaths.supportDirectory,
                        retentionPolicy: () -> ClaudeRetentionPolicy? = { ClaudeRetentionPolicy.load() },
                        sendLoop: ([String: Any], URL) -> Void = { input, profile in ClaudeLoopClient.send(input, profile: profile) }) -> Int32 {
        let record = makeRecord(from: input)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let events = directory.appendingPathComponent("claude-events-v2.jsonl")
            do {
                let lockPath = directory.appendingPathComponent("claude-events.lock").path
                let lockDescriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR) }
                guard lockDescriptor >= 0 else { throw HookError.lock }
                defer { Darwin.close(lockDescriptor) }
                var lockInfo = stat()
                guard fstat(lockDescriptor, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG else { throw HookError.lock }
                guard acquireEventLock(lockDescriptor) else { throw HookError.lock }
                defer { flock(lockDescriptor, LOCK_UN) }
                var existing = stat()
                if lstat(events.path, &existing) == 0 && (existing.st_mode & S_IFMT) != S_IFREG { throw HookError.lock }
                try rotateIfNeeded(at: events, policy: retentionPolicy())
                let line = try JSONSerialization.data(withJSONObject: record) + Data([0x0A])
                let eventDescriptor = open(events.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard eventDescriptor >= 0 else { throw HookError.lock }
                let handle = FileHandle(fileDescriptor: eventDescriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(eventDescriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else { throw HookError.lock }
                try handle.write(contentsOf: line)
            }
            sendLoop(input, directory)
            return 0
        } catch {
            return ProcessInfo.processInfo.environment["AI_TASK_MONITOR_AUDIT"] == "1" ? 1 : 0
        }
    }

    private static func acquireEventLock(_ descriptor: Int32) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EAGAIN else { return false }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            usleep(useconds_t(max(1, min(UInt64(20_000), (deadline - now) / 1_000))))
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
        let rawEventName = input.string("hook_event_name")
        let knownEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "TaskCreated",
                           "TaskCompleted", "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd"]
        let eventName = knownEvents.first { same($0, rawEventName) } ?? "Unknown"
        let rawToolName = input.string("tool_name")
        let toolName = safeID(rawToolName) ? rawToolName : ""
        let stage = eventName == "Unknown" ? StageAssessment(signal: "uncertain") :
            assessStage(event: eventName, tool: input.string("tool_name"), input: input, toolInput: toolInput)
        let subject = stage.subject ?? ""
        let taskID = stage.taskID ?? ""
        let rawSession = input.string("session_id")
        let boundedSession = Array(rawSession.utf8.prefix(257))
        let session = !boundedSession.isEmpty && boundedSession.count <= 256 ? rawSession : ""
        let active = !["Stop", "SessionEnd", "StopFailure"].contains(eventName)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "timestamp": formatter.string(from: Date()),
            "provider": "claude",
            "session_id": session,
            "event": eventName,
            "active": active,
            "activity": activity(event: eventName, tool: toolName, subject: subject),
            "task_id": taskID,
            "task_subject": subject,
            "task_status": stage.status ?? "",
            "task_from_status": stage.previousStatus ?? "",
            "task_intent_status": stage.intentStatus ?? "",
            "tool_name": toolName,
            "plan_version": 1,
            "plan_signal": stage.signal,
            "plan_call_id": stage.callID ?? ""
        ]
    }

    private struct StageAssessment {
        var signal: String = "none"
        var taskID: String? = nil
        var subject: String? = nil
        var status: String? = nil
        var previousStatus: String? = nil
        var intentStatus: String? = nil
        var callID: String? = nil
    }

    private static func same(_ left: String, _ right: String) -> Bool {
        left.utf8.elementsEqual(right.utf8)
    }

    private static func safeID(_ value: String) -> Bool {
        let bytes = Array(value.utf8.prefix(129))
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
            (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    private static func safeSubject(_ value: String) -> Bool {
        let bytes = Array(value.utf8.prefix(1025))
        return !bytes.isEmpty && bytes.count <= 1024 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isTrueBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    private static func validStatus(_ status: String) -> Bool {
        ["pending", "in_progress", "completed"].contains { same(status, $0) }
    }

    // This narrow synthetic response shape is not a claim about every Claude
    // version. Only a minimal derived signal is persisted, never the response.
    private static func assessStage(event: String, tool: String, input: [String: Any], toolInput: [String: Any]) -> StageAssessment {
        let call = input.string("tool_use_id")
        let callID = safeID(call) ? call : nil
        if same(event, "TaskCreated") || same(event, "TaskCompleted") {
            let id = input.string("task_id")
            let subject = input.string("task_subject")
            return StageAssessment(signal: "unlinked", taskID: safeID(id) ? id : nil,
                                   subject: safeSubject(subject) ? subject : nil, callID: callID)
        }
        guard same(event, "PreToolUse") || same(event, "PostToolUse") || same(event, "PostToolUseFailure") else {
            return StageAssessment()
        }
        let isCreate = same(tool, "TaskCreate")
        let isUpdate = same(tool, "TaskUpdate")
        if !isCreate && !isUpdate {
            return tool.isEmpty ? StageAssessment(signal: "uncertain") : StageAssessment()
        }
        let candidateID = toolInput.string("taskId")
        let taskID = isUpdate && safeID(candidateID) ? candidateID : nil
        if isUpdate {
            for alias in ["id", "task_id"] where toolInput[alias] != nil {
                guard let alternate = toolInput[alias] as? String, same(alternate, candidateID) else {
                    return StageAssessment(signal: "uncertain", callID: callID)
                }
            }
        }
        if same(event, "PreToolUse") {
            if isCreate {
                let subject = toolInput.string("subject")
                guard safeSubject(subject) else { return StageAssessment(signal: "uncertain", callID: callID) }
                return StageAssessment(signal: "attempt", subject: subject, callID: callID)
            }
            let requestedStatus = toolInput.string("status")
            guard taskID != nil, validStatus(requestedStatus) else { return StageAssessment(signal: "uncertain", callID: callID) }
            return StageAssessment(signal: "attempt", taskID: taskID, intentStatus: requestedStatus, callID: callID)
        }
        if same(event, "PostToolUseFailure") {
            return StageAssessment(signal: "failure", taskID: taskID, callID: callID)
        }
        guard let response = input.object("tool_response"),
              response["error"] == nil || response["error"] is NSNull else {
            return StageAssessment(signal: "uncertain", taskID: taskID, callID: callID)
        }
        if isCreate {
            let requested = toolInput.string("subject")
            guard (response["success"] == nil || isTrueBoolean(response["success"])),
                  let task = response.object("task"), let returnedID = task["id"] as? String,
                  let returnedSubject = task["subject"] as? String,
                  safeID(returnedID), safeSubject(requested), safeSubject(returnedSubject),
                  same(requested, returnedSubject) else {
                return StageAssessment(signal: "uncertain", callID: callID)
            }
            return StageAssessment(signal: "observed_create", taskID: returnedID, subject: returnedSubject,
                                   status: "pending", callID: callID)
        }
        let status = toolInput.string("status")
        guard let id = taskID, isTrueBoolean(response["success"]),
              let returnedID = response["taskId"] as? String, same(id, returnedID),
              validStatus(status), let fields = response["updatedFields"] as? [Any],
              let change = response.object("statusChange"),
              let from = change["from"] as? String, let to = change["to"] as? String,
              validStatus(from), validStatus(to), !same(from, to), same(to, status) else {
            return StageAssessment(signal: "uncertain", taskID: taskID, callID: callID)
        }
        var seen = Set<Data>()
        var hasStatus = false
        for field in fields {
            guard let name = field as? String, seen.insert(Data(name.utf8)).inserted else {
                return StageAssessment(signal: "uncertain", taskID: id, callID: callID)
            }
            if same(name, "status") { hasStatus = true }
        }
        guard hasStatus else { return StageAssessment(signal: "uncertain", taskID: id, callID: callID) }
        return StageAssessment(signal: "observed_update", taskID: id, status: status, previousStatus: from, callID: callID)
    }

    private static func activity(event: String, tool: String, subject: String) -> String {
        switch event {
        case "UserPromptSubmit": return "New request"
        case "PreToolUse": return tool.isEmpty ? "Running tool" : "Running: \(tool)"
        case "PostToolUse": return tool.isEmpty ? "Tool completed" : "Completed: \(tool)"
        case "PostToolUseFailure": return tool.isEmpty ? "Tool failed" : "Failed: \(tool)"
        case "TaskCreated", "TaskCompleted": return subject.isEmpty ? "Processing step" : "Processing step: \(subject)"
        case "SubagentStart": return "Subagent started"
        case "SubagentStop": return "Subagent stopped"
        case "Stop": return "Waiting for the next request"
        case "SessionEnd": return "Session ended"
        default: return event
        }
    }

    private static func rotateIfNeeded(at events: URL, policy: ClaudeRetentionPolicy?) throws {
        guard let policy,
              let size = (try? events.resourceValues(forKeys: [.fileSizeKey]).fileSize), size > policy.maximumMB * 1_000_000 else { return }
        let handle = try FileHandle(forReadingFrom: events)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        let count = min(UInt64(policy.maximumMB * 900_000), length)
        try handle.seek(toOffset: length - count)
        let tail = try handle.read(upToCount: Int(count)) ?? Data()
        guard tail.count == Int(count), let kept = preservedTailBytes(tail, beginsMidFile: length > count) else {
            throw HookError.invalidRecord
        }
        try kept.write(to: events, options: .atomic)
    }

    // Rotation must not repair invalid UTF-8 into a different session ID.
    static func preservedTailBytes(_ data: Data, beginsMidFile: Bool) -> Data? {
        guard data.isEmpty || data.last == 0x0a else { return nil }
        guard beginsMidFile else { return data }
        guard let newline = data.firstIndex(of: 0x0a) else { return nil }
        return Data(data[data.index(after: newline)...])
    }

    private enum HookError: Error { case lock, invalidRecord }
}
