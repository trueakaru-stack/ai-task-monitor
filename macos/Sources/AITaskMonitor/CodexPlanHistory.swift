import Foundation

struct CodexPlanSnapshot {
    var steps: [TaskStep] = []
    var confirmed = false
    var currentTurn = ""
}

enum CodexPlanParser {
    static func consume(_ line: Substring, into state: inout CodexPlanSnapshot) {
        guard line.contains("update_plan") || line.contains("task_started") || line.contains("turn_started"),
              let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else { return }
        let kind = payload.string("type")
        if record.string("type") == "event_msg", ["task_started", "turn_started"].contains(kind) {
            let turn = payload.string("turn_id")
            if turn.isEmpty || state.currentTurn.isEmpty || turn != state.currentTurn {
                if !state.steps.isEmpty { state.confirmed = false }
            }
            state.currentTurn = turn
            return
        }
        guard ["custom_tool_call", "function_call"].contains(kind) else { return }
        let turn = payload.string("turn_id")
        if !turn.isEmpty && !state.currentTurn.isEmpty && turn != state.currentTurn { return }
        let name = payload.string("name")
        let inputText = payload.string("input").isEmpty ? payload.string("arguments") : payload.string("input")
        if name == "update_plan", let inputData = inputText.data(using: .utf8),
           let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
           let plan = input["plan"] as? [[String: Any]] {
            let candidate = plan.compactMap { item -> TaskStep? in
                guard let title = item["step"] as? String, !title.isEmpty,
                      let status = status(item["status"] as? String) else { return nil }
                return TaskStep(title: title, status: status)
            }
            if plan.isEmpty || !candidate.isEmpty { state.steps = candidate; state.confirmed = true }
            return
        }
        if name != "update_plan" && !inputText.contains("update_plan(") { return }
        let candidate = legacyPlan(inputText)
        if !candidate.isEmpty { state.steps = candidate; state.confirmed = true }
    }

    static func parse(_ text: String) -> CodexPlanSnapshot {
        var state = CodexPlanSnapshot()
        for line in text.split(whereSeparator: \.isNewline) { consume(line, into: &state) }
        return state
    }

    private static func status(_ value: String?) -> StepStatus? {
        switch value {
        case "completed": return .done
        case "in_progress": return .active
        case "pending": return .pending
        default: return nil
        }
    }

    private static func legacyPlan(_ input: String) -> [TaskStep] {
        let pattern = #"step\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(completed|in_progress|pending)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input),
                  let status = status(String(input[statusRange])),
                  let encodedTitle = ("[\"" + String(input[titleRange]) + "\"]").data(using: .utf8),
                  let titles = try? JSONSerialization.jsonObject(with: encodedTitle) as? [String],
                  let title = titles.first, !title.isEmpty else { return nil }
            return TaskStep(title: title, status: status)
        }
    }
}

/// Incrementally scans complete JSONL records and retains the last published
/// plan in memory. Replaced, truncated or rewritten files are rescanned.
final class CodexPlanHistoryCache {
    private struct Entry {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let offset: UInt64
        let anchor: Data
        let snapshot: CodexPlanSnapshot
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func read(from url: URL) throws -> CodexPlanSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        lock.lock()
        let previous = entries[url.path]
        lock.unlock()
        if let previous, previous.device == device, previous.inode == inode,
           previous.size == size, previous.modified == modified { return previous.snapshot }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var state = CodexPlanSnapshot()
        if let previous, previous.device == device, previous.inode == inode,
           size > previous.size, try anchor(of: handle, at: previous.offset) == previous.anchor {
            offset = previous.offset
            state = previous.snapshot
        }
        try handle.seek(toOffset: offset)
        var cursor = offset
        var completeOffset = offset
        var line = Data()
        var oversized = false
        let maximumLine = 16_777_216
        while cursor < size {
            let remaining = Int(min(UInt64(65_536), size - cursor))
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { throw CocoaError(.fileReadUnknown) }
            for byte in chunk {
                cursor += 1
                if byte == 10 {
                    if oversized { throw CocoaError(.fileReadTooLarge) }
                    let text = String(decoding: line, as: UTF8.self)
                    CodexPlanParser.consume(text[...], into: &state)
                    line.removeAll(keepingCapacity: true)
                    completeOffset = cursor
                } else if !oversized {
                    if line.count < maximumLine { line.append(byte) }
                    else { line.removeAll(keepingCapacity: true); oversized = true }
                }
            }
        }
        let savedAnchor = try anchor(of: handle, at: completeOffset)
        let entry = Entry(device: device, inode: inode, size: size, modified: modified,
                          offset: completeOffset, anchor: savedAnchor, snapshot: state)
        lock.lock()
        if entries.count >= 128 && entries[url.path] == nil { entries.removeAll(keepingCapacity: true) }
        entries[url.path] = entry
        lock.unlock()
        return state
    }

    private func anchor(of handle: FileHandle, at offset: UInt64) throws -> Data {
        let count = Int(min(offset, UInt64(128)))
        try handle.seek(toOffset: offset - UInt64(count))
        return try handle.read(upToCount: count) ?? Data()
    }
}
