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
            return process(["hook_event_name": "AITMSourceUncertain", "session_id": ""])
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
                try markDamagedTailIfNeeded(at: events)
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
        if session.isEmpty || same(rawEventName, "AITMSourceUncertain") {
            return ["timestamp": formatter.string(from: Date()), "provider": "claude", "session_id": "",
                    "event": "AITMSourceUncertain", "plan_version": 2, "plan_signal": "source_uncertain"]
        }
        var record: [String: Any] = [
            "timestamp": formatter.string(from: Date()),
            "provider": "claude",
            "session_id": session,
            "event": eventName,
            "active": active,
            "activity": activity(event: eventName, tool: toolName, subject: subject, signal: stage.signal),
            "task_id": taskID,
            "task_subject": subject,
            "task_status": stage.status ?? "",
            "task_from_status": stage.previousStatus ?? "",
            "task_intent_status": stage.intentStatus ?? "",
            "tool_name": toolName,
            "plan_version": 2,
            "plan_signal": stage.signal
        ]
        if same(eventName, "Stop") { record["stop_background"] = stopBackground(input) }
        return record
    }

    private static func stopBackground(_ input: [String: Any]) -> String {
        let background = input["background_tasks"] as? [Any]
        let scheduled = input["session_crons"] as? [Any]
        if (background?.isEmpty == false) || (scheduled?.isEmpty == false) { return "observed" }
        if let background, let scheduled, background.isEmpty, scheduled.isEmpty { return "clear" }
        return "unknown"
    }

    private struct StageAssessment {
        var signal: String = "none"
        var taskID: String? = nil
        var subject: String? = nil
        var status: String? = nil
        var previousStatus: String? = nil
        var intentStatus: String? = nil
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
        if same(event, "TaskCreated") || same(event, "TaskCompleted") {
            let id = input.string("task_id")
            let subject = input.string("task_subject")
            guard safeID(id) else { return StageAssessment(signal: "uncertain") }
            let kind = same(event, "TaskCreated") ? "created_notice" : "completed_notice"
            return StageAssessment(signal: kind, taskID: id, subject: safeSubject(subject) ? subject : nil)
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
                    return StageAssessment(signal: "uncertain")
                }
            }
        }
        if same(event, "PreToolUse") {
            if isCreate {
                let subject = toolInput.string("subject")
                guard safeSubject(subject) else { return StageAssessment(signal: "uncertain") }
                return StageAssessment(signal: "attempt", subject: subject)
            }
            let requestedStatus = toolInput.string("status")
            guard taskID != nil, validStatus(requestedStatus) else { return StageAssessment(signal: "uncertain") }
            return StageAssessment(signal: "attempt", taskID: taskID, intentStatus: requestedStatus)
        }
        if same(event, "PostToolUseFailure") {
            return StageAssessment(signal: "failure", taskID: taskID)
        }
        guard let response = input.object("tool_response"),
              response["error"] == nil || response["error"] is NSNull else {
            return StageAssessment(signal: "uncertain", taskID: taskID)
        }
        if isCreate {
            let requested = toolInput.string("subject")
            guard (response["success"] == nil || isTrueBoolean(response["success"])),
                  let task = response.object("task"), let returnedID = task["id"] as? String,
                  let returnedSubject = task["subject"] as? String,
                  safeID(returnedID), safeSubject(requested), safeSubject(returnedSubject),
                  same(requested, returnedSubject) else {
                return StageAssessment(signal: "uncertain")
            }
            return StageAssessment(signal: "observed_create", taskID: returnedID, subject: returnedSubject, status: "pending")
        }
        let status = toolInput.string("status")
        guard let id = taskID, isTrueBoolean(response["success"]),
              let returnedID = response["taskId"] as? String, same(id, returnedID),
              validStatus(status), let fields = response["updatedFields"] as? [Any],
              let change = response.object("statusChange"),
              let from = change["from"] as? String, let to = change["to"] as? String,
              validStatus(from), validStatus(to), !same(from, to), same(to, status) else {
            return StageAssessment(signal: "uncertain", taskID: taskID)
        }
        var seen = Set<Data>()
        var hasStatus = false
        for field in fields {
            guard let name = field as? String, seen.insert(Data(name.utf8)).inserted else {
                return StageAssessment(signal: "uncertain", taskID: id)
            }
            if same(name, "status") { hasStatus = true }
        }
        // A simultaneous rename or other update is not represented by this
        // status-only record; do not confirm a stale title.
        guard hasStatus, fields.count == 1, toolInput["subject"] == nil else { return StageAssessment(signal: "uncertain", taskID: id) }
        return StageAssessment(signal: "observed_update", taskID: id, status: status, previousStatus: from)
    }

    private static func activity(event: String, tool: String, subject: String, signal: String) -> String {
        switch event {
        case "UserPromptSubmit": return "New request"
        case "PreToolUse": return tool.isEmpty ? "Running tool" : "Running: \(tool)"
        case "PostToolUse":
            if same(signal, "uncertain") { return "Action unconfirmed" }
            return tool.isEmpty ? "Tool completed" : "Completed: \(tool)"
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
        var replacement = kept
        replacement.append(try markerLine("AITMSourceUncertain"))
        try replacement.write(to: events, options: .atomic)
    }

    // Replace only an invalid final fragment and add the loss marker in the
    // same atomic rename. A crash before rename leaves the old damaged file.
    private static func markDamagedTailIfNeeded(at events: URL) throws {
        let descriptor = open(events.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return }
            throw HookError.invalidRecord
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else { throw HookError.invalidRecord }
        let length = try handle.seekToEnd()
        guard length > 0 else { return }
        let count = min(UInt64(1_048_578), length)
        try handle.seek(toOffset: length - count)
        let tail = try handle.read(upToCount: Int(count)) ?? Data()
        guard tail.count == Int(count) else { throw HookError.invalidRecord }
        let incomplete = tail.last != 0x0a
        var invalid = incomplete
        if !incomplete {
            // Empty trailing lines are ignored by the reader and retention;
            // they must not hide a damaged final non-empty record.
            var end = tail.endIndex
            while end > tail.startIndex && tail[tail.index(before: end)] == 0x0a { end = tail.index(before: end) }
            if end == tail.startIndex {
                guard length == count else { throw HookError.invalidRecord }
                return
            }
            let prefix = tail[..<end]
            let lastLine: Data
            if let newline = prefix.lastIndex(of: 0x0a) { lastLine = Data(prefix[prefix.index(after: newline)...]) }
            else { lastLine = Data(prefix) }
            invalid = !validBoundaryRecord(lastLine)
        }
        guard invalid else { return }
        // Avoid unbounded memory when a non-cooperating writer has grown the
        // file beyond the product's 100 MB retention plus one hook input.
        guard length <= 101_048_576 else { throw HookError.invalidRecord }
        try handle.seek(toOffset: 0)
        let original = try handle.read(upToCount: Int(length)) ?? Data()
        guard original.count == Int(length) else { throw HookError.invalidRecord }
        var fragmentEnd = original.endIndex
        if !incomplete {
            while fragmentEnd > original.startIndex && original[original.index(before: fragmentEnd)] == 0x0a {
                fragmentEnd = original.index(before: fragmentEnd)
            }
        }
        let beforeFragment = original[..<fragmentEnd]
        let cutoff: Data.Index
        if let newline = beforeFragment.lastIndex(of: 0x0a) { cutoff = original.index(after: newline) }
        else { cutoff = original.startIndex }
        let temporary = events.deletingLastPathComponent().appendingPathComponent(".aitm-tail-repair-\(UUID().uuidString).tmp")
        let writerDescriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard writerDescriptor >= 0 else { throw HookError.invalidRecord }
        let writer = FileHandle(fileDescriptor: writerDescriptor, closeOnDealloc: true)
        defer { try? writer.close(); _ = unlink(temporary.path) }
        try writer.write(contentsOf: Data(original[..<cutoff]))
        try writer.write(contentsOf: markerLine("AITMPartialTail"))
        try writer.synchronize()
        try writer.close()
        var after = stat(), pathInfo = stat()
        guard fstat(descriptor, &after) == 0, lstat(events.path, &pathInfo) == 0,
              opened.st_dev == after.st_dev, opened.st_ino == after.st_ino,
              opened.st_size == after.st_size, opened.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              opened.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              opened.st_dev == pathInfo.st_dev, opened.st_ino == pathInfo.st_ino,
              (pathInfo.st_mode & S_IFMT) == S_IFREG else { throw HookError.invalidRecord }
        guard rename(temporary.path, events.path) == 0 else { throw HookError.invalidRecord }
    }

    private static func validBoundaryRecord(_ bytes: Data) -> Bool {
        guard let event = ClaudeJSONValidation.object(bytes), FileHelpers.isoDate(event["timestamp"]) != nil,
              let session = event["session_id"] as? String else { return false }
        if !session.isEmpty { return !event.string("event").isEmpty && claudeSessionKey(session) != nil }
        let name = event.string("event"), signal = event.string("plan_signal")
        guard let version = event["plan_version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID() else { return false }
        return (version.doubleValue == 2 && ["AITMSourceUncertain", "AITMPartialTail"].contains { same(name, $0) } && same(signal, "source_uncertain")) ||
            (version.doubleValue == 1 && same(name, "Unknown") && same(signal, "uncertain"))
    }

    private static func markerLine(_ event: String) throws -> Data {
        var marker = makeRecord(from: ["hook_event_name": "AITMSourceUncertain", "session_id": ""])
        marker["event"] = event
        return try JSONSerialization.data(withJSONObject: marker) + Data([0x0a])
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
