import Foundation

enum TaskProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    case kimi
    case deepseek
    case hermes
    case opencode

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .kimi: return "Kimi Code"
        case .deepseek: return "DeepSeek Harness"
        case .hermes: return "Hermes Agent"
        case .opencode: return "OpenCode"
        }
    }
}

enum ProgressKind: String, Codable {
    case exact
    case approximate
    case none
}

enum ProgressBasis: String, Codable {
    case task
    case steps
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
    var isWaiting: Bool = false
    var loopWarning: LoopWarning? = nil
    var startedAt: Date = .distantPast
    var startKey: String = ""
    var planConfirmed: Bool = true
    var progressBasis: ProgressBasis? = nil

    var planStatusNote: String? {
        guard !steps.isEmpty else { return nil }
        if !planConfirmed || (provider == .claude && isUnconfirmed) {
            return tr("План не подтверждён", "Plan unconfirmed")
        }
        if provider == .claude {
            return tr("По известным этапам · возможна неточность", "Based on observed steps; may be inaccurate")
        }
        return nil
    }

    var progressLabel: String? {
        var basis = progressBasis ?? (steps.isEmpty ? .task : .steps)
        if (progress == nil || progressKind == .none) && !steps.isEmpty { basis = .steps }
        if basis == .steps {
            guard !steps.isEmpty, planConfirmed, !isUnconfirmed else { return nil }
            let active = steps.indices.filter { steps[$0].status == .active }
            if active.count == 1 {
                let current = active[0] + 1
                return tr("Этап \(current) из \(steps.count)", "Step \(current) of \(steps.count)")
            }
            let done = steps.filter { $0.status == .done }.count
            return tr("Готово \(done) из \(steps.count)", "Done \(done) of \(steps.count)")
        }
        guard let progress, progressKind != .none else { return nil }
        let value = progressKind == .approximate ? "≈\(progress)%" : "\(progress)%"
        return value
    }

    static func progress(for steps: [TaskStep]) -> Int? {
        guard !steps.isEmpty else { return nil }
        let completed = steps.filter { $0.status == .done }.count
        return Int((Double(completed) / Double(steps.count) * 100).rounded())
    }
}

struct TaskFocusTracker {
    private var priorities: [String: Int] = [:]
    private var nextPriority = 0

    init() {}

    mutating func reconcile(current: [MonitoredTask], previous: [MonitoredTask], selectedID: String?, monitoringStartedAt: Date = .distantFuture) -> (tasks: [MonitoredTask], selectedID: String?) {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let present = Set(current.map(\.id))
        priorities = priorities.filter { present.contains($0.key) }
        let activated = current.filter { task in
            let recentlyObserved = (task.isUnconfirmed || task.isWaiting) && !task.startKey.isEmpty && task.startedAt >= monitoringStartedAt
            guard task.isActive || recentlyObserved else { return false }
            guard let old = previousByID[task.id] else { return true }
            let newTurn = !task.startKey.isEmpty && task.startKey != old.startKey
            let becameActive = task.isActive && !old.isActive && (task.startKey.isEmpty || old.startKey.isEmpty)
            return newTurn || becameActive
        }.sorted { left, right in
            let leftStart = left.startedAt == .distantPast ? left.updatedAt : left.startedAt
            let rightStart = right.startedAt == .distantPast ? right.updatedAt : right.startedAt
            return leftStart == rightStart ? left.id < right.id : leftStart < rightStart
        }
        for task in activated {
            nextPriority += 1
            priorities[task.id] = nextPriority
        }
        let ordered = current.sorted { left, right in
            let leftPriority = priorities[left.id] ?? 0
            let rightPriority = priorities[right.id] ?? 0
            if leftPriority != rightPriority { return leftPriority > rightPriority }
            if left.isActive != right.isActive { return left.isActive }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return left.id < right.id
        }
        let visible = ordered.prefix(3)
        let requested = activated.last?.id ?? selectedID
        let selected = requested.flatMap { id in visible.contains { $0.id == id } ? id : nil } ?? visible.first?.id
        return (ordered, selected)
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
            uncertain.isWaiting = false
            uncertain.activity = tr("Статус не подтверждён", "Status unconfirmed")
            result.append(uncertain)
        }
        return result
    }
}

enum ProviderFilter: String, CaseIterable, Identifiable {
    case all
    case codex
    case claude
    case kimi
    case deepseek
    case hermes
    case opencode

    var id: String { rawValue }
    var title: String {
        provider?.displayName ?? tr("Все", "All")
    }
    var provider: TaskProvider? { TaskProvider(rawValue: rawValue) }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return tr("Как в системе", "System")
        case .light: return tr("Светлая", "Light")
        case .dark: return tr("Тёмная", "Dark")
        }
    }
}
