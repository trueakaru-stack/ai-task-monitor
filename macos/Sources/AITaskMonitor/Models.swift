import Foundation

enum TaskProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }
    var displayName: String { self == .codex ? "Codex" : "Claude Code" }
}

enum ProgressKind: String, Codable {
    case exact
    case approximate
    case none
}

enum StepStatus: String, Codable {
    case done
    case active
    case pending
}

struct TaskStep: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var status: StepStatus

    init(id: String = UUID().uuidString, title: String, status: StepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

struct MonitoredTask: Identifiable, Codable, Equatable {
    let id: String
    var provider: TaskProvider
    var title: String
    var activity: String
    var isActive: Bool
    var progress: Int?
    var progressKind: ProgressKind
    var steps: [TaskStep]
    var updatedAt: Date
    var isUnconfirmed: Bool = false
    var loopWarning: LoopWarning? = nil

    var progressLabel: String? {
        guard let progress else { return nil }
        return progressKind == .approximate ? "≈\(progress)%" : "\(progress)%"
    }

    static func progress(for steps: [TaskStep]) -> Int? {
        guard !steps.isEmpty else { return nil }
        let completed = steps.filter { $0.status == .done }.count
        return Int((Double(completed) / Double(steps.count) * 100).rounded())
    }
}

enum TaskSnapshotMerger {
    static func merge(previous: [MonitoredTask], current: [MonitoredTask], terminalIDs: Set<String>) -> [MonitoredTask] {
        let currentIDs = Set(current.map(\.id))
        var result = current
        for task in previous where !currentIDs.contains(task.id) && !terminalIDs.contains(task.id) {
            var uncertain = task
            uncertain.isActive = false
            uncertain.isUnconfirmed = true
            uncertain.activity = "Статус не подтверждён"
            result.append(uncertain)
        }
        return result
    }
}

enum ProviderFilter: String, CaseIterable, Identifiable {
    case all
    case codex
    case claude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Все"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        }
    }
}
