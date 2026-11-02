import Foundation

struct CodexTaskReader {
    let codexHome: URL
    private let fileManager = FileManager.default

    init(codexHome: URL? = nil) {
        if let codexHome {
            self.codexHome = codexHome
        } else if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], !configured.isEmpty {
            self.codexHome = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            self.codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    func readTasks(now: Date = Date()) -> [MonitoredTask] {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        guard let text = try? FileHelpers.tail(of: index, maximumBytes: 2_000_000) else { return [] }
        var sessions: [String: [String: Any]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let item = FileHelpers.jsonObject(line) else { continue }
            let id = item.string("id")
            if !id.isEmpty { sessions[id] = item }
        }

        return sessions.values.compactMap { session in
            let id = session.string("id")
            let title = session.string("thread_name")
            guard !id.isEmpty, title != "Guardian review", let file = sessionFile(id: id) else { return nil }
            guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < 7_200,
                  let tail = try? FileHelpers.tail(of: file, maximumBytes: 4_194_304),
                  isRunning(tail: tail) else { return nil }

            let steps = parsePlan(from: tail)
            let activity = parseActivity(from: tail)
            let progress = MonitoredTask.progress(for: steps)
            return MonitoredTask(
                id: id,
                provider: .codex,
                title: title.isEmpty ? "Задача Codex" : title,
                activity: activity,
                isActive: true,
                progress: progress,
                progressKind: progress == nil ? .none : .exact,
                steps: steps,
                updatedAt: modified
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func isRunning(tail: String) -> Bool {
        var running = false
        var turnID = ""
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let record = FileHelpers.jsonObject(line), record.string("type") == "event_msg",
                  let payload = record.object("payload") else { continue }
            let eventTurnID = payload.string("turn_id")
            switch payload.string("type") {
            case "task_started", "turn_started":
                running = true
                turnID = eventTurnID
            case "task_complete", "turn_complete", "turn_aborted":
                if !turnID.isEmpty && !eventTurnID.isEmpty && turnID != eventTurnID { continue }
                running = false
            default:
                continue
            }
        }
        return running
    }

    func parsePlan(from tail: String) -> [TaskStep] {
        var latest: [TaskStep] = []
        for line in tail.split(whereSeparator: \.isNewline) where line.contains("update_plan") {
            guard let record = FileHelpers.jsonObject(line),
                  let payload = record.object("payload"),
                  ["custom_tool_call", "function_call"].contains(payload.string("type")) else { continue }
            let name = payload.string("name")
            let inputText = payload.string("input").isEmpty ? payload.string("arguments") : payload.string("input")
            if name == "update_plan", let inputData = inputText.data(using: .utf8),
               let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
               let plan = input["plan"] as? [[String: Any]] {
                let candidate = plan.compactMap { item -> TaskStep? in
                    guard let step = item["step"] as? String, !step.isEmpty,
                          let status = planStatus(item["status"] as? String) else { return nil }
                    return TaskStep(title: step, status: status)
                }
                if plan.isEmpty || !candidate.isEmpty { latest = candidate }
                continue
            }
            if name != "update_plan" && !inputText.contains("update_plan(") { continue }
            let candidate = parseLegacyPlan(inputText)
            if !candidate.isEmpty { latest = candidate }
        }
        return latest
    }

    private func planStatus(_ value: String?) -> StepStatus? {
        switch value {
        case "completed": return .done
        case "in_progress": return .active
        case "pending": return .pending
        default: return nil
        }
    }

    private func parseLegacyPlan(_ input: String) -> [TaskStep] {
        let pattern = #"step\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*status\s*:\s*"(completed|in_progress|pending)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard let titleRange = Range(match.range(at: 1), in: input),
                  let statusRange = Range(match.range(at: 2), in: input),
                  let status = planStatus(String(input[statusRange])),
                  let encodedTitle = ("[\"" + String(input[titleRange]) + "\"]").data(using: .utf8),
                  let titles = try? JSONSerialization.jsonObject(with: encodedTitle) as? [String],
                  let title = titles.first, !title.isEmpty else { return nil }
            return TaskStep(title: title, status: status)
        }
    }

    func parseActivity(from tail: String) -> String {
        var latest = ""
        for line in tail.split(whereSeparator: \.isNewline) {
            guard let record = FileHelpers.jsonObject(line), let payload = record.object("payload") else { continue }
            if record.string("type") == "event_msg", payload.string("type") == "agent_reasoning" {
                latest = payload.string("text")
            } else if payload.string("type") == "message", payload.string("phase") == "commentary" {
                for part in payload.array("content") where part.string("type") == "output_text" {
                    latest = part.string("text")
                }
            } else if payload.string("type") == "item_completed", let item = payload.object("item"),
                      item.string("type") == "AgentMessage", item.string("phase") == "commentary" {
                for part in item.array("content") where part.string("type") == "Text" {
                    latest = part.string("text")
                }
            }
        }
        return FileHelpers.normalized(latest.replacingOccurrences(of: #"^\*\*(.*?)\*\*$"#, with: "$1", options: .regularExpression), limit: 600)
    }

    private func sessionFile(id: String) -> URL? {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix("\(id).jsonl") { return url }
        return nil
    }
}
