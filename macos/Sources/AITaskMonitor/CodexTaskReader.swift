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
        let pattern = #"\"type\":\"event_msg\",\"payload\":\{\"type\":\"(task_started|task_complete)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(tail.startIndex..., in: tail)
        guard let match = regex.matches(in: tail, range: range).last,
              let stateRange = Range(match.range(at: 1), in: tail) else { return false }
        return tail[stateRange] == "task_started"
    }

    func parsePlan(from tail: String) -> [TaskStep] {
        var latest: [TaskStep] = []
        for line in tail.split(whereSeparator: \.isNewline) where line.contains("update_plan") {
            guard let record = FileHelpers.jsonObject(line),
                  let payload = record.object("payload"),
                  payload.string("type") == "custom_tool_call",
                  let inputData = payload.string("input").data(using: .utf8),
                  let input = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
                  let plan = input["plan"] as? [[String: Any]] else { continue }
            let candidate = plan.compactMap { item -> TaskStep? in
                guard let step = item["step"] as? String, !step.isEmpty else { return nil }
                let status: StepStatus
                switch item["status"] as? String {
                case "completed": status = .done
                case "in_progress": status = .active
                default: status = .pending
                }
                return TaskStep(title: step, status: status)
            }
            if !candidate.isEmpty { latest = candidate }
        }
        return latest
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
