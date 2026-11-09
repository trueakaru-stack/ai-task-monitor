import CoreFoundation
import CryptoKit
import Foundation

struct ClaudeLoopEvent {
    enum Kind: String { case start, failed, success, edit, stop, reset, phase }

    let sessionID: String
    let toolID: String
    let kind: Kind
    let fingerprint: String?
    let exitCode: Int32?
    let time: Date
}

// Raw hook input exists only in the short-lived hook process. Only a keyed
// fingerprint and bounded event metadata are passed to the monitor.
struct ClaudeLoopInput {
    let sessionID: String
    let toolID: String
    let kind: ClaudeLoopEvent.Kind
    let shell: String?
    let command: String?
    let directory: String?
    let exitCode: Int32?

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...90).contains($0.value) ||
                (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
        }
    }

    static func classify(_ input: [String: Any]) -> ClaudeLoopInput? {
        let session = input.string("session_id")
        guard validID(session) else { return nil }
        let event = input.string("hook_event_name")
        let tool = input.string("tool_name")
        var kind: ClaudeLoopEvent.Kind?
        var exitCode: Int32?
        if ["Stop", "SessionEnd", "StopFailure", "UserPromptSubmit"].contains(event) {
            kind = .stop
        } else if ["PreToolUse", "PostToolUse"].contains(event) &&
                    ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool) {
            kind = .edit
        } else if ["Bash", "PowerShell"].contains(tool) {
            switch event {
            case "PreToolUse": kind = .start
            case "PostToolUse":
                let interrupted = boolean(input.object("tool_response")?["interrupted"])
                kind = interrupted == false ? .success : .reset
            case "PostToolUseFailure":
                let interrupted = boolean(input["is_interrupt"])
                if interrupted == false, let error = input["error"] as? String,
                   let code = Self.exitCode(from: error), code != 0 {
                    kind = .failed
                    exitCode = code
                } else {
                    kind = .reset
                }
            default: break
            }
        }
        guard let kind else { return nil }
        guard [.start, .failed, .success].contains(kind) else {
            return ClaudeLoopInput(sessionID: session, toolID: "", kind: kind, shell: nil,
                                   command: nil, directory: nil, exitCode: nil)
        }
        let toolID = input.string("tool_use_id")
        let command = input.object("tool_input")?["command"] as? String
        let directory = input["cwd"] as? String
        guard validID(toolID), let command, !command.isEmpty, command.utf8.count <= 131_072,
              let directory, !directory.isEmpty, directory.utf8.count <= 32_768 else {
            return ClaudeLoopInput(sessionID: session, toolID: "", kind: .reset, shell: nil,
                                   command: nil, directory: nil, exitCode: nil)
        }
        return ClaudeLoopInput(sessionID: session, toolID: toolID, kind: kind, shell: tool,
                               command: command, directory: directory, exitCode: exitCode)
    }

    func payload(key: Data) -> Data? {
        guard key.count == 32 else { return nil }
        var value: [String: Any] = ["session": sessionID, "tool": toolID, "kind": kind.rawValue]
        if [.start, .failed, .success].contains(kind) {
            guard let shell, let command, let directory else { return nil }
            let canonical = "claude\0\(shell)\0\(directory.utf8.count):\(directory)\(command.utf8.count):\(command)"
            let digest = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: key))
            value["fingerprint"] = digest.map { String(format: "%02x", $0) }.joined()
            if kind == .failed, let exitCode { value["exitCode"] = exitCode }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value), data.count <= 4096 else { return nil }
        return data
    }

    private static func boolean(_ raw: Any?) -> Bool? {
        guard let raw else { return false }
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func exitCode(from error: String) -> Int32? {
        guard var line = error.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) else { return nil }
        if line.hasSuffix("\r") { line.removeLast() }
        let prefix = "Exit code "
        guard line.hasPrefix(prefix) else { return nil }
        let code = String(line.dropFirst(prefix.count))
        guard !code.isEmpty, code.unicodeScalars.enumerated().allSatisfy({ index, scalar in
            (48...57).contains(scalar.value) || (index == 0 && scalar.value == 45)
        }) else { return nil }
        return Int32(code)
    }
}

enum ClaudeLoopPayload {
    static func parse(_ data: Data, now: Date = Date()) -> ClaudeLoopEvent? {
        guard data.count >= 2, data.count <= 4096,
              let value = ClaudeJSONValidation.object(data),
              Set(value.keys).isSubset(of: ["session", "tool", "kind", "fingerprint", "exitCode"]),
              let session = value["session"] as? String, ClaudeLoopInput.validID(session),
              let name = value["kind"] as? String, let kind = ClaudeLoopEvent.Kind(rawValue: name),
              let tool = value["tool"] as? String else { return nil }
        var fingerprint: String?
        var code: Int32?
        if [.start, .failed, .success].contains(kind) {
            guard ClaudeLoopInput.validID(tool), let hash = value["fingerprint"] as? String,
                  hash.utf8.count == 64, hash.unicodeScalars.allSatisfy({
                      (48...57).contains($0.value) || (97...102).contains($0.value)
                  }) else { return nil }
            fingerprint = hash
            if kind == .failed {
                guard let number = value["exitCode"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max),
                      number.int32Value != 0 else { return nil }
                code = number.int32Value
            }
        }
        if kind == .phase {
            guard ClaudeLoopInput.validID(tool), let hash = value["fingerprint"] as? String,
                  ClaudePhaseEvidence.validDigest(hash), value["exitCode"] == nil else { return nil }
            fingerprint = hash
        }
        return ClaudeLoopEvent(sessionID: session, toolID: tool, kind: kind,
                               fingerprint: fingerprint, exitCode: code, time: now)
    }
}

struct ClaudeLoopTracker {
    private struct Started { let fingerprint: String; let time: Date }
    private(set) var threshold: Int
    private(set) var windowMinutes: Int
    private(set) var lastSeen = Date.distantPast
    private(set) var dismissed = false
    private var fingerprint: String?
    private var exitCode: Int32?
    private var times: [Date] = []
    private var inFlight: [String: Started] = [:]
    private var overlap = false
    private var seen: Set<String> = []
    private var seenOrder: [String] = []

    init(threshold: Int = 5, windowMinutes: Int = 10) {
        self.threshold = threshold
        self.windowMinutes = windowMinutes
    }

    var warning: LoopWarning? {
        guard times.count >= threshold, !dismissed else { return nil }
        return LoopWarning(threshold: threshold, windowMinutes: windowMinutes)
    }

    mutating func configure(threshold: Int, windowMinutes: Int) {
        guard (3...10).contains(threshold), (1...30).contains(windowMinutes) else { return }
        if self.threshold != threshold || self.windowMinutes != windowMinutes {
            reset()
            self.threshold = threshold
            self.windowMinutes = windowMinutes
        }
    }

    mutating func dismiss() { if warning != nil { dismissed = true } }

    mutating func refresh(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(windowMinutes) * 60)
        times.removeAll { $0 < cutoff }
        if times.count < threshold { dismissed = false }
        if inFlight.values.contains(where: { $0.time < cutoff }) { reset() }
    }

    mutating func consume(_ event: ClaudeLoopEvent, now: Date) {
        guard event.time <= now.addingTimeInterval(300), event.time >= lastSeen else {
            reset()
            lastSeen = event.time
            return
        }
        lastSeen = event.time
        refresh(now: now)
        switch event.kind {
        case .stop, .reset: reset(); return
        case .edit:
            resetSequence()
            if !inFlight.isEmpty { overlap = true }
            return
        case .phase: return
        case .start, .failed, .success: break
        }
        guard ClaudeLoopInput.validID(event.toolID), let current = event.fingerprint else { reset(); return }
        let eventID = event.kind.rawValue + "|" + event.toolID
        guard seen.insert(eventID).inserted else { return }
        seenOrder.append(eventID)
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
        if event.kind == .start {
            if !inFlight.isEmpty { resetSequence(); overlap = true }
            if let fingerprint, fingerprint != current { resetSequence() }
            if inFlight.count >= 32 { reset() }
            inFlight[event.toolID] = Started(fingerprint: current, time: event.time)
            return
        }
        guard let started = inFlight.removeValue(forKey: event.toolID) else { reset(); return }
        if overlap {
            resetSequence()
            if inFlight.isEmpty { overlap = false }
            return
        }
        guard started.fingerprint == current, event.kind == .failed, let code = event.exitCode, code != 0 else {
            resetSequence()
            return
        }
        if fingerprint != current || exitCode != code {
            resetSequence()
            fingerprint = current
            exitCode = code
        }
        let cutoff = event.time.addingTimeInterval(-Double(windowMinutes) * 60)
        times.removeAll { $0 < cutoff }
        if times.count < threshold { dismissed = false }
        times.append(event.time)
        if times.count > 10 { times.removeFirst(times.count - 10) }
    }

    private mutating func resetSequence() {
        fingerprint = nil
        exitCode = nil
        times.removeAll()
        dismissed = false
    }

    private mutating func reset() {
        resetSequence()
        inFlight.removeAll()
        overlap = false
    }
}
