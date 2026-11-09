import Foundation
import CoreFoundation
import Darwin

// Bound work and preserve byte identity. The input must already have passed
// strict UTF-8 decoding; never truncate an identifier to fit this limit.
func claudeSessionKey(_ value: String) -> String? {
    let bytes = Array(value.utf8.prefix(257))
    guard !bytes.isEmpty, bytes.count <= 256 else { return nil }
    if bytes.allSatisfy({ $0 < 128 }) && bytes.first != 0x7e { return value }
    let hex = Array("0123456789abcdef".utf8)
    var output: [UInt8] = [0x7e]
    output.reserveCapacity(1 + bytes.count * 2)
    for byte in bytes { output.append(hex[Int(byte >> 4)]); output.append(hex[Int(byte & 15)]) }
    return String(decoding: output, as: UTF8.self)
}

enum ClaudeReadError: Error { case incomplete, invalidRecord, unsupportedIdentity, journalBusy }
private typealias ClaudeRecord = ([String: Any], Date, String)
private typealias ClaudeFileBytes = (data: Data, truncated: Bool, device: UInt64, inode: UInt64, length: UInt64)
private typealias ClaudeInput = (records: [ClaudeRecord], truncated: Bool, sourceLosses: [Date],
                                 freshStartDates: [String: Date], scopeIncomplete: Bool, prefixTitles: [String: [String]])

// Retention and the hook hold this same lock while changing either journal.
// Do not combine a current-file snapshot from before cleanup with a legacy
// snapshot from after cleanup. Busy means retry; it is not a clean source.
private func withClaudeJournalReadLock<T>(_ file: URL, timing: ((UInt64) -> Void)?, _ action: () throws -> T) throws -> T {
    let path = file.deletingLastPathComponent().appendingPathComponent("claude-events.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw ClaudeReadError.incomplete }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ClaudeReadError.incomplete }
    if flock(descriptor, LOCK_SH | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK || errno == EAGAIN { throw ClaudeReadError.journalBusy }
        throw ClaudeReadError.incomplete
    }
    let started = DispatchTime.now().uptimeNanoseconds
    defer {
        flock(descriptor, LOCK_UN)
        let finished = DispatchTime.now().uptimeNanoseconds
        if let timing { timing(finished >= started ? finished - started : 0) }
    }
    return try action()
}

// A reader instance must remember a marker even if another operation removes
// it while the monitor is running. Copying the reader shares the latch.
private final class ClaudeSourceLossLatch {
    private let lock = NSLock()
    private var known = false
    private var affected: Set<String> = []
    private var saturated = false
    private let maximumSessions = 1024
    private struct FileStamp {
        let device: UInt64
        let inode: UInt64
        let length: UInt64
        let suffix: Data
    }
    private var files: [String: FileStamp] = [:]

    // Compare an already-observed tail with the same byte range in the next
    // bounded snapshot. Replacement, shrinkage and a broken suffix revoke trust.
    // This is detection during this reader's lifetime, not crash durability.
    func observe(_ path: String, file: ClaudeFileBytes?) {
        lock.lock(); defer { lock.unlock() }
        guard let file else {
            if files.removeValue(forKey: path) != nil { known = true; saturated = true; affected.removeAll() }
            return
        }
        if let old = files[path] {
            var continuity = old.device == file.device && old.inode == file.inode && file.length >= old.length
            if continuity && !old.suffix.isEmpty {
                let newStart = file.length - UInt64(file.data.count)
                let oldStart = old.length - UInt64(old.suffix.count)
                if oldStart < newStart || old.length > file.length {
                    continuity = false
                } else {
                    let offset = Int(oldStart - newStart)
                    let end = offset + old.suffix.count
                    continuity = end <= file.data.count && file.data.subdata(in: offset..<end) == old.suffix
                }
            }
            if !continuity { known = true; saturated = true; affected.removeAll() }
        }
        files[path] = FileStamp(device: file.device, inode: file.inode, length: file.length,
                                suffix: Data(file.data.suffix(4096)))
    }

    func record(_ ids: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        known = true
        guard !saturated else { return }
        for id in ids where !affected.contains(id) {
            if affected.count >= maximumSessions { saturated = true; affected.removeAll(); return }
            affected.insert(id)
        }
    }

    func markSaturated() { lock.lock(); known = true; saturated = true; affected.removeAll(); lock.unlock() }

    func state() -> (known: Bool, affected: Set<String>, saturated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (known, affected, saturated)
    }
}

// Capture bounded bytes under the shared journal lock. JSON parsing happens
// after unlocking so a slow parse does not needlessly hold up Claude hooks.
private func readClaudeFile(_ url: URL) throws -> ClaudeFileBytes {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(handle.fileDescriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        throw ClaudeReadError.incomplete
    }
    let length = try handle.seekToEnd()
    let limit: UInt64 = 4_194_304
    let count = min(limit, length)
    let start = length - count
    try handle.seek(toOffset: start)
    var data = try handle.read(upToCount: Int(count)) ?? Data()
    guard data.count == Int(count) else { throw ClaudeReadError.incomplete }
    guard data.isEmpty || data.last == 0x0a else { throw ClaudeReadError.incomplete }
    let truncated = start > 0
    if truncated {
        guard let newline = data.firstIndex(of: 0x0a) else { throw ClaudeReadError.incomplete }
        data = Data(data[data.index(after: newline)...])
    }
    return (data, truncated, UInt64(bitPattern: Int64(info.st_dev)), UInt64(info.st_ino), length)
}

// A complete invalid line can belong to any session: do not replace bytes or
// skip it and then accept another session's terminal record. An incomplete
// final write is retried on the next poll instead of being parsed as complete.
private func readClaudeRecords(_ input: ClaudeFileBytes, noteLoss: (Set<String>) -> Void) throws -> ClaudeInput {
    let data = input.data
    let truncated = input.truncated
    var records: [ClaudeRecord] = []
    var sourceLosses: [Date] = []
    let lines = data.split(separator: 0x0a, omittingEmptySubsequences: true)
    var recoveryIndex: Int? = nil
    var lastLossIndex: Int? = nil
    var firstSeen: [String: Int] = [:]
    var scopeIncomplete = false
    for (index, bytes) in lines.enumerated() {
        guard let marker = ClaudeJSONValidation.object(Data(bytes)),
              let session = marker["session_id"] as? String else { continue }
        if !session.isEmpty {
            if let id = claudeSessionKey(session), firstSeen[id] == nil { firstSeen[id] = index }
            continue
        }
        guard session.isEmpty,
              let timestamp = FileHelpers.isoDate(marker["timestamp"]) else { continue }
        let name = marker.string("event"), signal = marker.string("plan_signal")
        let isNew = phaseVersionTwo(marker) && sameBytes(signal, "source_uncertain") &&
            (sameBytes(name, "AITMSourceUncertain") || sameBytes(name, "AITMPartialTail"))
        let isOld = phaseVersion(marker, 1) && sameBytes(name, "Unknown") && sameBytes(signal, "uncertain")
        if isNew || isOld {
            noteLoss(Set(firstSeen.keys))
            sourceLosses.append(timestamp)
            lastLossIndex = index
            if let raw = marker["scope_incomplete"] {
                if let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() { scopeIncomplete = scopeIncomplete || flag.boolValue }
                else { scopeIncomplete = true }
            }
            if isNew && sameBytes(name, "AITMPartialTail") { recoveryIndex = index }
        }
    }
    let first = recoveryIndex.map { $0 + 1 } ?? 0
    // Before a partial-tail boundary, individual valid titles remain useful
    // for display only. Never use these rows to infer activity or status.
    var prefixTitles: [String: [String]] = [:]
    var prefixSeen: [String: Set<Data>] = [:]
    if let boundary = recoveryIndex {
        for bytes in lines.prefix(boundary) {
            guard let event = ClaudeJSONValidation.object(Data(bytes)),
                  FileHelpers.isoDate(event["timestamp"]) != nil,
                  let raw = event["session_id"] as? String, let id = claudeSessionKey(raw) else { continue }
            let phase = phaseOf(event)
            let name = event.string("event"), tool = event.string("tool_name")
            let taskNotice = ["TaskCreated", "TaskCompleted"].contains { sameBytes($0, name) }
            let taskTool = ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains { sameBytes($0, name) } &&
                ["TaskCreate", "TaskUpdate"].contains { sameBytes($0, tool) }
            guard taskNotice || taskTool, phase.kind != "none", !phase.taskID.isEmpty,
                  claudeSessionKey(phase.taskID) != nil, !phase.title.isEmpty,
                  phase.title.utf8.count <= 1024 else { continue }
            let titleBytes = Data(phase.title.utf8)
            if !(prefixSeen[id] ?? []).contains(titleBytes), (prefixTitles[id]?.count ?? 0) < 4096 {
                prefixSeen[id, default: []].insert(titleBytes)
                prefixTitles[id, default: []].append(phase.title)
            }
        }
    }
    var freshStartDates: [String: Date] = [:]
    var rejectedStartIDs: Set<String> = []
    for (index, bytes) in lines.enumerated().dropFirst(first) {
        let line = Data(bytes)
        guard let event = ClaudeJSONValidation.object(line),
              let timestamp = FileHelpers.isoDate(event["timestamp"]),
              let session = event["session_id"] as? String else { throw ClaudeReadError.invalidRecord }
        let newMarker = sameBytes(event.string("event"), "AITMSourceUncertain") && phaseVersionTwo(event) &&
            sameBytes(event.string("plan_signal"), "source_uncertain")
        let oldMarker = sameBytes(event.string("event"), "Unknown") && phaseVersion(event, 1) &&
            sameBytes(event.string("plan_signal"), "uncertain")
        if session.isEmpty && (newMarker || oldMarker) { continue }
        guard let id = claudeSessionKey(session) else { throw ClaudeReadError.unsupportedIdentity }
        if let lastLossIndex, index > lastLossIndex, sameBytes(event.string("event"), "SessionStart") {
            if firstSeen[id] == index, !rejectedStartIDs.contains(id), phaseVersionTwo(event),
               sameBytes(event.string("session_start_source"), "startup") {
                freshStartDates[id] = timestamp
            } else {
                freshStartDates.removeValue(forKey: id)
                rejectedStartIDs.insert(id)
            }
        }
        records.append((event, timestamp, id))
    }
    return (records, truncated, sourceLosses, freshStartDates, scopeIncomplete, prefixTitles)
}

private func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

private func safeStageID(_ value: String) -> Bool {
    let bytes = Array(value.utf8.prefix(129))
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    return bytes.allSatisfy { (48...57).contains($0) || (65...90).contains($0) ||
        (97...122).contains($0) || $0 == 45 || $0 == 95 }
}

private func phaseVersion(_ event: [String: Any], _ version: Double) -> Bool {
    guard let n = event["plan_version"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
    return n.doubleValue == version
}
private func phaseVersionTwo(_ event: [String: Any]) -> Bool { phaseVersion(event, 2) }

private struct ClaudePhase {
    var kind: String
    var tool: String = ""
    var taskID: String = ""
    var title: String = ""
    var status: String = ""
    var previousStatus: String = ""
    var intentStatus: String = ""
}

// Only the hook's validated, minimal PostToolUse records can mutate status.
// Old records, failure and unlinked lifecycle notifications remain uncertain.
private func phaseOf(_ event: [String: Any]) -> ClaudePhase {
    let name = event.string("event"), tool = event.string("tool_name")
    let id = event.string("task_id"), title = event.string("task_subject")
    if sameBytes(name, "TaskCreated") || sameBytes(name, "TaskCompleted") {
        let expected = sameBytes(name, "TaskCreated") ? "created_notice" : "completed_notice"
        guard phaseVersionTwo(event), sameBytes(event.string("plan_signal"), expected), safeStageID(id),
              Array(title.utf8.prefix(1025)).count <= 1024 else {
            return ClaudePhase(kind: "legacy", taskID: id, title: title)
        }
        return ClaudePhase(kind: expected, taskID: id, title: title)
    }
    let isPhaseEvent = ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains { sameBytes(name, $0) }
    let isTargetTool = ["TaskCreate", "TaskUpdate"].contains { sameBytes(tool, $0) }
    if isPhaseEvent && tool.isEmpty { return ClaudePhase(kind: "uncertain", taskID: id, title: title) }
    if !isPhaseEvent && (!id.isEmpty || !event.string("task_status").isEmpty) {
        return ClaudePhase(kind: "legacy", taskID: id, title: title)
    }
    if !isPhaseEvent || !isTargetTool {
        if phaseVersionTwo(event), sameBytes(event.string("plan_signal"), "uncertain") {
            return ClaudePhase(kind: "uncertain")
        }
        return ClaudePhase(kind: "none")
    }
    guard phaseVersionTwo(event) else { return ClaudePhase(kind: "legacy", tool: tool, taskID: id, title: title) }
    let signal = event.string("plan_signal")
    if sameBytes(signal, "attempt"), sameBytes(name, "PreToolUse") {
        let intent = event.string("task_intent_status")
        if sameBytes(tool, "TaskUpdate"), safeStageID(id),
           ["pending", "in_progress", "completed"].contains(where: { sameBytes(intent, $0) }) {
            return ClaudePhase(kind: "attempt", tool: tool, taskID: id, intentStatus: intent)
        }
        if sameBytes(tool, "TaskCreate"), id.isEmpty, !title.isEmpty, Array(title.utf8.prefix(1025)).count <= 1024 {
            return ClaudePhase(kind: "attempt", tool: tool, title: title)
        }
        return ClaudePhase(kind: "uncertain", tool: tool, taskID: id)
    }
    if sameBytes(signal, "failure"), sameBytes(name, "PostToolUseFailure") {
        return ClaudePhase(kind: "failure", tool: tool, taskID: id)
    }
    let status = event.string("task_status")
    let previousStatus = event.string("task_from_status")
    let validStatus = ["pending", "in_progress", "completed"].contains { sameBytes(status, $0) }
    if sameBytes(name, "PostToolUse"), safeStageID(id) {
        if sameBytes(signal, "observed_update"), sameBytes(tool, "TaskUpdate"), title.isEmpty, validStatus,
           ["pending", "in_progress", "completed"].contains(where: { sameBytes(previousStatus, $0) }),
           !sameBytes(previousStatus, status) {
            return ClaudePhase(kind: "observed_update", tool: tool, taskID: id, status: status, previousStatus: previousStatus)
        }
        if sameBytes(signal, "observed_create"), sameBytes(tool, "TaskCreate"), status.isEmpty,
           previousStatus.isEmpty, !title.isEmpty, Array(title.utf8.prefix(1025)).count <= 1024 {
            return ClaudePhase(kind: "observed_create", tool: tool, taskID: id, title: title, status: status)
        }
    }
    return ClaudePhase(kind: "uncertain", tool: tool, taskID: id, title: title)
}

private struct ClaudePhaseAttempt {
    let tool: String
    let taskID: String
    let title: Data
    let intentStatus: String
    let date: Date
    var sources: UInt8
}

private struct ClaudePhaseSignature: Hashable {
    let kind: String
    let taskID: String
    let status: String
    let previousStatus: String
    let title: Data
}

private struct ClaudeSeenObservation: Hashable {
    let signature: ClaudePhaseSignature
    let date: Date
}

private struct ClaudePhaseNotice {
    let title: Data
    let date: Date
    var sources: UInt8
}

private struct ClaudePhaseTracker {
    var createAttempts: [Data: ClaudePhaseAttempt] = [:]
    var updateAttempts: [String: ClaudePhaseAttempt] = [:]
    var correlatedAttempts: [String: ClaudePhaseAttempt] = [:]
    var usedCallIDs: Set<String> = []
    var createdNotices: [String: ClaudePhaseNotice] = [:]
    var completedNotices: [String: ClaudePhaseNotice] = [:]
    var seen: [ClaudeSeenObservation: UInt8] = [:]
    var lastStatuses: [String: String] = [:]
    var lastTitles: [String: Data] = [:]
    var createdIDs: Set<String> = []
    var unobservedStatuses: Set<String> = []
    var inconsistent = false
    var sawObservation = false

    mutating func consume(_ phase: ClaudePhase, at date: Date, source: Int, callID: String? = nil) {
        let bit = UInt8(1 << source)
        switch phase.kind {
        case "none": break
        case "attempt":
            let title = Data(phase.title.utf8)
            let attempt = ClaudePhaseAttempt(tool: phase.tool, taskID: phase.taskID, title: title,
                                             intentStatus: phase.intentStatus, date: date, sources: bit)
            if let callID {
                if usedCallIDs.contains(callID) { inconsistent = true }
                else if var old = correlatedAttempts[callID] {
                    if old.date == date && sameBytes(old.tool, attempt.tool) && sameBytes(old.taskID, attempt.taskID) &&
                       old.title == attempt.title && sameBytes(old.intentStatus, attempt.intentStatus) && (old.sources & bit) == 0 {
                        old.sources |= bit; correlatedAttempts[callID] = old
                    } else { inconsistent = true }
                } else { correlatedAttempts[callID] = attempt }
            } else if sameBytes(phase.tool, "TaskCreate") {
                if var old = createAttempts[title] {
                    if old.date == date && (old.sources & bit) == 0 { old.sources |= bit; createAttempts[title] = old }
                    else { inconsistent = true }
                } else { createAttempts[title] = attempt }
            } else if sameBytes(phase.tool, "TaskUpdate"), safeStageID(phase.taskID) {
                if var old = updateAttempts[phase.taskID] {
                    if old.date == date && sameBytes(old.intentStatus, phase.intentStatus) && (old.sources & bit) == 0 {
                        old.sources |= bit; updateAttempts[phase.taskID] = old
                    } else { inconsistent = true }
                } else { updateAttempts[phase.taskID] = attempt }
            } else { inconsistent = true }
        case "created_notice", "completed_notice":
            let title = Data(phase.title.utf8)
            if !title.isEmpty, let previous = lastTitles[phase.taskID], previous != title { inconsistent = true }
            let notice = ClaudePhaseNotice(title: title, date: date, sources: bit)
            if phase.kind == "created_notice" {
                if var old = createdNotices[phase.taskID] {
                    if old.date == date && old.title == title && (old.sources & bit) == 0 { old.sources |= bit; createdNotices[phase.taskID] = old }
                    else { inconsistent = true }
                } else { createdNotices[phase.taskID] = notice }
            } else {
                if var old = completedNotices[phase.taskID] {
                    if old.date == date && old.title == title && (old.sources & bit) == 0 { old.sources |= bit; completedNotices[phase.taskID] = old }
                    else { inconsistent = true }
                } else { completedNotices[phase.taskID] = notice }
            }
        case "observed_create", "observed_update":
            sawObservation = true
            let signature = ClaudePhaseSignature(kind: phase.kind, taskID: phase.taskID, status: phase.status,
                                                 previousStatus: phase.previousStatus, title: Data(phase.title.utf8))
            let observation = ClaudeSeenObservation(signature: signature, date: date)
            if let old = seen[observation] {
                if (old & bit) != 0 { inconsistent = true } else { seen[observation] = old | bit }
                return
            }
            seen[observation] = bit
            if let callID {
                if usedCallIDs.contains(callID) { inconsistent = true }
                else if let attempt = correlatedAttempts.removeValue(forKey: callID) {
                    if date <= attempt.date || !sameBytes(attempt.tool, phase.tool) { inconsistent = true }
                    if phase.kind == "observed_create" && attempt.title != signature.title { inconsistent = true }
                    if phase.kind == "observed_update" &&
                       (!sameBytes(attempt.taskID, phase.taskID) || !sameBytes(attempt.intentStatus, phase.status)) { inconsistent = true }
                }
                usedCallIDs.insert(callID)
            }
            if phase.kind == "observed_create" {
                if !createdIDs.insert(phase.taskID).inserted || lastStatuses[phase.taskID] != nil { inconsistent = true }
                unobservedStatuses.insert(phase.taskID)
                if let attempt = createAttempts.removeValue(forKey: signature.title) {
                    // No raw or derived call identifier is stored. Matching
                    // fields cannot prove the response belongs to this call.
                    inconsistent = true
                    if date <= attempt.date { inconsistent = true }
                }
                if let notice = createdNotices.removeValue(forKey: phase.taskID) {
                    if date <= notice.date || (!notice.title.isEmpty && notice.title != signature.title) { inconsistent = true }
                }
                lastTitles[phase.taskID] = signature.title
            } else {
                unobservedStatuses.remove(phase.taskID)
                if let attempt = updateAttempts.removeValue(forKey: phase.taskID) {
                    // Same task/status may belong to a different invocation.
                    inconsistent = true
                    if date <= attempt.date || !sameBytes(attempt.intentStatus, phase.status) { inconsistent = true }
                }
                if sameBytes(phase.status, "completed"), let notice = completedNotices.removeValue(forKey: phase.taskID) {
                    if date <= notice.date || (!notice.title.isEmpty && lastTitles[phase.taskID] != notice.title) { inconsistent = true }
                }
            }
            if phase.kind == "observed_update" {
                if let previous = lastStatuses[phase.taskID], !sameBytes(previous, phase.previousStatus) { inconsistent = true }
                lastStatuses[phase.taskID] = phase.status
            }
        default: inconsistent = true
        }
    }

    var isUncertain: Bool {
        inconsistent || !createAttempts.isEmpty || !updateAttempts.isEmpty ||
            !correlatedAttempts.isEmpty || !createdNotices.isEmpty || !completedNotices.isEmpty ||
            !unobservedStatuses.isEmpty || !sawObservation
    }
}

struct ClaudeTaskSnapshot {
    var tasks: [MonitoredTask] = []
    var terminalIDs: Set<String> = []
    var interruptedIDs: Set<String> = []
    var neutralEndedIDs: Set<String> = []
    var sourceUncertain = false
}

struct ClaudeTaskReader {
    let eventFile: URL
    let legacyFile: URL?
    let usesExplicitFile: Bool
    private let sourceLossLatch: ClaudeSourceLossLatch
    private let readLockTiming: ((UInt64) -> Void)?

    init(eventFile: URL? = nil, legacyFile: URL? = nil, readLockTiming: ((UInt64) -> Void)? = nil) {
        self.eventFile = eventFile ?? AppPaths.claudeEvents
        self.legacyFile = legacyFile ?? (eventFile == nil ? AppPaths.legacyClaudeEvents : nil)
        self.usesExplicitFile = eventFile != nil
        self.sourceLossLatch = ClaudeSourceLossLatch()
        self.readLockTiming = readLockTiming
    }

    // Called when a previously present journal disappears between polls.
    func noteSourceLoss() { sourceLossLatch.markSaturated() }

    func readTasks(now: Date = Date(), observedSince: Date? = nil) -> [MonitoredTask] {
        (try? readSnapshot(now: now, observedSince: observedSince).tasks) ?? []
    }

    func readSnapshot(now: Date = Date(), observedSince: Date? = nil,
                      phaseEvidence: ClaudePhaseEvidence? = nil) throws -> ClaudeTaskSnapshot {
        do {
            return try readSnapshotImpl(now: now, observedSince: observedSince, phaseEvidence: phaseEvidence)
        } catch ClaudeReadError.journalBusy {
            // A cooperative writer holding the shared lock is not a loss.
            throw ClaudeReadError.journalBusy
        } catch {
            // A failed read can conceal overwritten or dropped events. No
            // later successful read alone repairs their provenance.
            sourceLossLatch.markSaturated()
            throw error
        }
    }

    private func readSnapshotImpl(now: Date, observedSince: Date?,
                                  phaseEvidence: ClaudePhaseEvidence?) throws -> ClaudeTaskSnapshot {
        let files: (ClaudeFileBytes, Result<ClaudeFileBytes?, Error>) = try withClaudeJournalReadLock(eventFile, timing: readLockTiming) {
            let current = try readClaudeFile(eventFile)
            guard let legacyFile, !current.data.isEmpty else { return (current, .success(nil)) }
            do {
                return (current, .success(try readClaudeFile(legacyFile)))
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError { return (current, .success(nil)) }
                return (current, .failure(error))
            }
        }
        sourceLossLatch.observe(eventFile.standardizedFileURL.path, file: files.0)
        if let legacyFile, !files.0.data.isEmpty {
            switch files.1 {
            case .success(let legacy): sourceLossLatch.observe(legacyFile.standardizedFileURL.path, file: legacy)
            case .failure: sourceLossLatch.markSaturated()
            }
        }
        let currentInput = try readClaudeRecords(files.0, noteLoss: { sourceLossLatch.record($0) })
        var current = currentInput.records
        var observedIDs = Set(current.map { $0.2 })
        var legacy: [([String: Any], Date, String)] = []
        var legacyTruncated = false
        var losses = currentInput.sourceLosses
        var scopeIncomplete = currentInput.scopeIncomplete
        var prefixTitles = currentInput.prefixTitles
        if !observedIDs.isEmpty, let legacyBytes = try files.1.get() {
            let prior = try readClaudeRecords(legacyBytes, noteLoss: { sourceLossLatch.record($0) })
            legacyTruncated = prior.truncated
            losses.append(contentsOf: prior.sourceLosses)
            scopeIncomplete = scopeIncomplete || prior.scopeIncomplete
            for (id, titles) in prior.prefixTitles { prefixTitles[id, default: []].append(contentsOf: titles) }
            legacy = prior.records
        }
        if currentInput.truncated || legacyTruncated { sourceLossLatch.markSaturated() }
        let sourceUncertain = sourceLossLatch.state().known
        if sourceUncertain && scopeIncomplete { sourceLossLatch.markSaturated() }
        // No documented event generation/order proves a fresh scope after a
        // source loss. Until such evidence exists, keep all observed Claude
        // sessions uncertain. A later startup or wall clock is not a proof.
        let freshStartIDs: Set<String> = []
        if sourceUncertain { sourceLossLatch.markSaturated() }
        if let lastLoss = losses.max() {
            if let observedSince, lastLoss < observedSince {
                // Do not revive older records. Restart time is not proof of a
                // new agent generation, so uncertainty remains latched.
                // Keep prior titles for sessions observed active during this
                // monitoring run, without reviving unrelated older sessions.
                let newlyObserved = Set(current.compactMap { event, date, id in
                    date >= observedSince && event["active"] as? Bool == true ? id : nil
                })
                current = current.filter { $0.1 >= observedSince || newlyObserved.contains($0.2) }
                legacy = legacy.filter { $0.1 >= observedSince || newlyObserved.contains($0.2) }
                observedIDs = Set(current.map { $0.2 })
            }
        }
        legacy = legacy.filter { observedIDs.contains($0.2) }
        let freshIDs = Set(current.compactMap { item -> String? in
            if let observedSince, item.1 < observedSince { return nil }
            guard item.0["active"] as? Bool == true else { return nil }
            return item.2
        })
        // Preserve ordering anomalies before sorting. The two files may overlap
        // and do not share a monotonic sequence or a reliable common cursor.
        typealias Observation = (date: Date, active: Bool?)
        var latest: [[String: Observation]] = [[:], [:]]
        var latestActive: [[String: Observation]] = [[:], [:]]
        let uncertainIDs = (currentInput.truncated || legacyTruncated) ? observedIDs :
            (sourceUncertain ? observedIDs.subtracting(freshStartIDs) : [])
        var timeUncertain: Set<String> = uncertainIDs
        // Plan ordering is separate from session activity. A short reversal of
        // two plan mutations can make progress unsafe without proving the
        // session itself stopped or became inactive.
        var planUncertain: Set<String> = uncertainIDs
        var latestPrompt: [[String: Date]] = [[:], [:]]
        var latestStep: [[String: Date]] = [[:], [:]]
        var latestTask: [[PlanTaskKey: Date]] = [[:], [:]]
        var taskIdentityBytes: [PlanTaskKey: Data] = [:]
        // Legacy is scanned first. Store its evidence only; compare each
        // current event against it without retaining a second timestamp index.
        var legacyEffects: [PlanStepTimeKey: PlanEffectSummary] = [:]
        var legacyPromptTimes: Set<PlanTimeKey> = []
        var legacyStepTimes: Set<PlanTimeKey> = []
        var legacyActivity: [PlanTimeKey: UInt8] = [:]
        var sessionsWithPrompt: Set<String> = []
        for (source, records) in [legacy, current].enumerated() {
            for (event, date, id) in records {
                let active = event["active"] as? Bool
                let timeKey = PlanTimeKey(session: id, date: date)
                if let previous = latest[source][id] {
                    let reversed = previous.date.timeIntervalSince(date)
                    if reversed > 60 || (reversed > 0 && previous.active != nil && active != nil && previous.active != active) {
                        timeUncertain.insert(id)
                    }
                    if date >= previous.date { latest[source][id] = (date, active) }
                } else { latest[source][id] = (date, active) }
                if let active {
                    if let previous = latestActive[source][id] {
                        if date < previous.date && previous.active != active { timeUncertain.insert(id) }
                        if date >= previous.date { latestActive[source][id] = (date, active) }
                    } else { latestActive[source][id] = (date, active) }
                    // Equal-time activity conflicts cannot be discarded when a
                    // later same-source event replaces the latest observation.
                    let bit: UInt8 = active ? 1 : 2
                    let opposite: UInt8 = active ? 2 : 1
                    if source == 0 { legacyActivity[timeKey, default: 0] |= bit }
                    else if ((legacyActivity[timeKey] ?? 0) & opposite) != 0 { timeUncertain.insert(id) }
                }
                let name = event.string("event")
                let isPrompt = name == "UserPromptSubmit" && active != false
                if isPrompt {
                    sessionsWithPrompt.insert(id)
                    if let previous = latestPrompt[source][id], date < previous { planUncertain.insert(id) }
                    if let previous = latestStep[source][id], date < previous { planUncertain.insert(id) }
                    if latestPrompt[source][id] == nil || date > latestPrompt[source][id]! {
                        latestPrompt[source][id] = date
                    }
                    if source == 0 { legacyPromptTimes.insert(timeKey) }
                    else if legacyStepTimes.contains(timeKey) { planUncertain.insert(id) }
                }
                let taskID = event.string("task_id")
                let phase = phaseOf(event)
                if !taskID.isEmpty, phase.kind != "none" {
                    guard let taskIdentity = claudeSessionKey(taskID) else { planUncertain.insert(id); continue }
                    let taskKey = PlanTaskKey(session: id, task: taskIdentity)
                    let rawIdentity = Data(taskID.utf8)
                    if let prior = taskIdentityBytes[taskKey], prior != rawIdentity { planUncertain.insert(id) }
                    else { taskIdentityBytes[taskKey] = rawIdentity }
                    if let previous = latestTask[source][taskKey], date < previous { planUncertain.insert(id) }
                    if let previous = latestPrompt[source][id], date < previous { planUncertain.insert(id) }
                    if latestTask[source][taskKey] == nil || date > latestTask[source][taskKey]! {
                        latestTask[source][taskKey] = date
                    }
                    if latestStep[source][id] == nil || date > latestStep[source][id]! {
                        latestStep[source][id] = date
                    }
                    if source == 0 { legacyStepTimes.insert(timeKey) }
                    else if legacyPromptTimes.contains(timeKey) { planUncertain.insert(id) }
                    if let effect = planStepEffect(event) {
                        let stepKey = PlanStepTimeKey(task: taskKey, date: date)
                        if source == 0 {
                            var summary = legacyEffects[stepKey] ?? PlanEffectSummary()
                            summary.record(effect)
                            legacyEffects[stepKey] = summary
                        } else if let summary = legacyEffects[stepKey], summary.conflicts(with: effect) {
                            planUncertain.insert(id)
                        }
                    }
                }
            }
        }
        for (id, prior) in latest[0] {
            if let present = latest[1][id],
               prior.date > present.date || (prior.date == present.date && prior.active != nil && present.active != nil && prior.active != present.active) {
                timeUncertain.insert(id)
            }
        }
        for (id, prior) in latestActive[0] {
            if let present = latestActive[1][id], prior.date >= present.date && prior.active != present.active {
                timeUncertain.insert(id)
            }
        }
        let ordered = (legacy + current).enumerated().sorted { left, right in
            if left.element.1 != right.element.1 { return left.element.1 < right.element.1 }
            return left.offset < right.offset
        }
        // A fingerprint must identify at most one row per source; cross-file
        // overlap is allowed, repeated identical rows in one file are not.
        var phaseCounts: [[String: Int]] = [[:], [:]]
        if let phaseEvidence, !phaseEvidence.poisoned {
            for (source, records) in [legacy, current].enumerated() {
                for (event, _, _) in records {
                    let kind = phaseOf(event).kind
                    if ["attempt", "observed_create", "observed_update"].contains(kind),
                       let fingerprint = phaseEvidence.fingerprint(event) {
                        phaseCounts[source][fingerprint, default: 0] += 1
                    }
                }
            }
        }
        var sessions: [String: SessionState] = [:]
        var phaseTrackers: [String: ClaudePhaseTracker] = [:]
        for entry in ordered {
            let event = entry.element.0
            let id = entry.element.2
            var tracker = phaseTrackers[id] ?? ClaudePhaseTracker()
            let phase = phaseOf(event)
            let source = entry.offset < legacy.count ? 0 : 1
            var callID: String?
            if ["attempt", "observed_create", "observed_update"].contains(phase.kind),
               let phaseEvidence, let fingerprint = phaseEvidence.fingerprint(event),
               (phaseCounts[0][fingerprint] ?? 0) <= 1, (phaseCounts[1][fingerprint] ?? 0) <= 1 {
                callID = phaseEvidence.toolID(fingerprint: fingerprint, session: id)
            }
            tracker.consume(phase, at: entry.element.1, source: source, callID: callID)
            phaseTrackers[id] = tracker
            var state = sessions[id] ?? SessionState(id: id)
            let isNewPrompt = event.string("event") == "UserPromptSubmit" && (event["active"] as? Bool) != false
            let becameActive = (event["active"] as? Bool) == true && !state.isActive
            if isNewPrompt || becameActive {
                if isNewPrompt && !state.steps.isEmpty { state.planConfirmed = false }
                state.startedAt = entry.element.1
                state.startKey = "event:" + event.string("timestamp")
            }
            state.updatedAt = entry.element.1
            state.lastEvent = event.string("event")
            if !event.string("activity").isEmpty { state.activity = localizedActivity(event) }
            state.isActive = event["active"] as? Bool ?? state.isActive
            if sameBytes(state.lastEvent, "Stop") {
                let background = phaseVersionTwo(event) ? event.string("stop_background") : "unknown"
                state.backgroundUncertain = !sameBytes(background, "clear")
            } else if sameBytes(state.lastEvent, "StopFailure") {
                // Failure of the main response does not establish that
                // background work has finished.
                state.backgroundUncertain = true
            }
            let phaseLost = phaseEvidence?.isSessionUncertain(id) ?? false
            updateSteps(event, state: &state, retainHistoricalTitles: sourceUncertain || phaseLost)
            sessions[id] = state
        }

        var result = ClaudeTaskSnapshot()
        result.sourceUncertain = sourceUncertain
        for state in sessions.values {
            let age = now.timeIntervalSince(state.updatedAt)
            let timeAnomaly = age < -60 || (!state.isActive && age < 0) || timeUncertain.contains(state.id)
            if !state.isActive && !timeAnomaly && !state.backgroundUncertain && ["Stop", "SessionEnd", "StopFailure"].contains(state.lastEvent) {
                var recognized = false
                if let observedSince {
                    if state.updatedAt >= observedSince { recognized = true }
                } else {
                    recognized = true
                }
                if recognized {
                    let id = "claude:\(state.id)"
                    if state.lastEvent == "Stop" { result.neutralEndedIDs.insert(id) }
                    else { result.terminalIDs.insert(id); result.interruptedIDs.insert(id) }
                }
                continue
            }
            guard (state.isActive || timeAnomaly || state.backgroundUncertain), freshIDs.contains(state.id) else { continue }
            if state.titleHistoryOverflow { result.sourceUncertain = true }
            let liveSteps = state.stepsOrder.compactMap { state.steps[$0] }
            let unconfirmed = age >= 7_200 || timeAnomaly || state.backgroundUncertain
            // A step observed without any prompt boundary is not proof that
            // it belongs to the currently observed user request.
            let channelIdentitySupported = ClaudeLoopInput.validID(state.id)
            let channelSessionUncertain = phaseEvidence?.isSessionUncertain(state.id) ?? false
            let planConfirmed = state.planConfirmed && !unconfirmed && channelIdentitySupported && !channelSessionUncertain && !planUncertain.contains(state.id) &&
                sessionsWithPrompt.contains(state.id) && !(phaseTrackers[state.id]?.isUncertain ?? true)
            var seenTitles = Set(liveSteps.map { Data($0.title.utf8) })
            var previousTitles: [String] = []
            for title in (prefixTitles[state.id] ?? []) + state.titleHistory {
                if seenTitles.insert(Data(title.utf8)).inserted {
                    if previousTitles.count < 4096 { previousTitles.append(title) }
                    else { result.sourceUncertain = true }
                }
            }
            let historical = previousTitles.enumerated().map { index, title in
                TaskStep(id: "~aitm-observed-\(index)", title: title, status: .pending)
            }
            let steps = planConfirmed ? liveSteps : historical + liveSteps
            let progress = planConfirmed ? MonitoredTask.progress(for: steps) : nil
            result.tasks.append(MonitoredTask(
                id: "claude:\(state.id)", provider: .claude, title: tr("Задача Claude Code", "Claude Code task"),
                activity: unconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : state.activity, isActive: !unconfirmed, progress: progress,
                progressKind: progress == nil ? .none : .approximate,
                steps: steps, updatedAt: state.updatedAt, isUnconfirmed: unconfirmed,
                startedAt: state.startedAt, startKey: state.startKey, planConfirmed: planConfirmed
            ))
        }
        result.tasks.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    // An event carrying only task_id does not change an existing step's
    // status or title. Keep earlier meaningful observations for conflict
    // detection instead of letting such a later record replace them.
    private func planStepEffect(_ event: [String: Any]) -> PlanStepEffect? {
        let phase = phaseOf(event)
        let status = phase.status
        let subject = phase.title
        let statusEffect: Int?
        if sameBytes(status, "completed") { statusEffect = 2 }
        else if sameBytes(status, "in_progress") { statusEffect = 1 }
        else if sameBytes(status, "pending") { statusEffect = 0 }
        else { statusEffect = nil }
        let titleEffect: Data? = subject.isEmpty ? nil : Data(subject.utf8)
        guard statusEffect != nil || titleEffect != nil else { return nil }
        return PlanStepEffect(status: statusEffect, title: titleEffect)
    }

    private func updateSteps(_ event: [String: Any], state: inout SessionState, retainHistoricalTitles: Bool) {
        let phase = phaseOf(event)
        guard phase.kind != "none", !phase.taskID.isEmpty, let key = claudeSessionKey(phase.taskID) else { return }
        let subject = Array(phase.title.utf8.prefix(1025)).count <= 1024 ? phase.title : ""
        if state.steps[key] == nil {
            state.steps[key] = TaskStep(id: key, title: subject.isEmpty ? tr("Этап \(phase.taskID)", "Step \(phase.taskID)") : subject, status: .pending)
            state.stepsOrder.append(key)
            if !subject.isEmpty { state.explicitTitleIDs.insert(key) }
        } else if !subject.isEmpty {
            if state.explicitTitleIDs.contains(key), let old = state.steps[key]?.title,
               !Data(old.utf8).elementsEqual(subject.utf8) {
                // Reuse or renaming of an ID is not a confirmed plan boundary.
                // Keep actual earlier titles, never the generated placeholder.
                state.planConfirmed = false
                let bytes = Data(old.utf8)
                if retainHistoricalTitles && !state.historyTitleBytes.contains(bytes) {
                    if state.titleHistory.count < 4096 {
                        state.titleHistory.append(old)
                        state.historyTitleBytes.insert(bytes)
                    } else { state.titleHistoryOverflow = true }
                }
            }
            state.steps[key]?.title = subject
            state.explicitTitleIDs.insert(key)
        }
        if sameBytes(phase.status, "completed") { state.steps[key]?.status = .done }
        else if sameBytes(phase.status, "in_progress") { state.steps[key]?.status = .active }
        else if sameBytes(phase.status, "pending") { state.steps[key]?.status = .pending }
    }

    private func localizedActivity(_ event: [String: Any]) -> String {
        let tool = event.string("tool_name")
        let subject = event.string("task_subject")
        switch event.string("event") {
        case "UserPromptSubmit": return tr("Обрабатывает новый запрос", "Processing a new request")
        case "PreToolUse": return tool.isEmpty ? tr("Выполняет действие", "Running an action") : tr("Выполняет: \(tool)", "Running: \(tool)")
        case "PostToolUse":
            let phase = phaseOf(event)
            if phase.kind == "uncertain" || phase.kind == "legacy" {
                return tr("Действие не подтверждено", "Action unconfirmed")
            }
            return tool.isEmpty ? tr("Действие завершено", "Action completed") : tr("Завершено: \(tool)", "Completed: \(tool)")
        case "PostToolUseFailure": return tool.isEmpty ? tr("Ошибка действия", "Action failed") : tr("Ошибка: \(tool)", "Failed: \(tool)")
        case "TaskCreated", "TaskCompleted": return subject.isEmpty ? tr("Обрабатывает этап", "Processing step") : tr("Обрабатывает этап: \(subject)", "Processing step: \(subject)")
        case "SubagentStart": return tr("Запущен дополнительный агент", "Subagent started")
        case "SubagentStop": return tr("Дополнительный агент завершён", "Subagent finished")
        default: return ""
        }
    }

}

private struct PlanTaskKey: Hashable {
    let session: String
    let task: String
}

private struct PlanTimeKey: Hashable {
    let session: String
    let date: Date
}

private struct PlanStepTimeKey: Hashable {
    let task: PlanTaskKey
    let date: Date
}

private struct PlanStepEffect {
    let status: Int?
    let title: Data?
}

// One bounded summary per task and timestamp, rather than pairwise comparison
// of every overlapping line. Missing fields represent no mutation.
private struct PlanEffectSummary {
    private var statuses: UInt8 = 0
    private var firstTitle: Data?
    private var multipleTitles = false

    init() {}

    mutating func record(_ effect: PlanStepEffect) {
        if let status = effect.status { statuses |= UInt8(1) << status }
        if let title = effect.title {
            if let firstTitle {
                if firstTitle != title { multipleTitles = true }
            } else { firstTitle = title }
        }
    }

    func conflicts(with effect: PlanStepEffect) -> Bool {
        if let status = effect.status, statuses != 0 {
            let same = UInt8(1) << status
            if (statuses & same) != statuses { return true }
        }
        if let title = effect.title, let firstTitle, multipleTitles || firstTitle != title { return true }
        return false
    }
}

private struct SessionState {
    let id: String
    var activity = ""
    var isActive = false
    var lastEvent = ""
    var updatedAt = Date.distantPast
    var startedAt = Date.distantPast
    var startKey = ""
    var planConfirmed = true
    var backgroundUncertain = false
    var steps: [String: TaskStep] = [:]
    var stepsOrder: [String] = []
    var explicitTitleIDs: Set<String> = []
    var titleHistory: [String] = []
    var historyTitleBytes: Set<Data> = []
    var titleHistoryOverflow = false
}
