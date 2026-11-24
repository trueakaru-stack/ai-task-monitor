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

struct CodexAgentDetail: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let activity: String
    let isActive: Bool
    let isUnconfirmed: Bool
    var loopWarning: LoopWarning?
}

struct CodexFileIdentity: Codable, Hashable {
    let device: UInt64
    let inode: UInt64
}

struct CompactTaskSelectionKey: Hashable {
    let provider: TaskProvider
    let id: String
    let file: CodexFileIdentity?
    let startKey: String
}

private struct CompactTaskSourceKey: Hashable {
    let provider: TaskProvider
    let id: String
}

struct CompactTaskDot: Identifiable {
    struct ID: Hashable {
        let key: CompactTaskSelectionKey
        let occurrence: Int
        let generation: UInt64?
    }

    let task: MonitoredTask
    let occurrence: Int
    let visibleIndex: Int
    let generation: UInt64?
    var id: ID { ID(key: task.compactSelectionKey, occurrence: occurrence, generation: generation) }
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
    var codexAgentCount: Int? = nil
    var codexAgentsUnconfirmed: Bool? = nil
    var codexAgents: [CodexAgentDetail]? = nil
    var lastKnownActivity: String? = nil
    var lastActivityIdentityConfirmed: Bool? = nil
    var lastActivityFileIdentity: CodexFileIdentity? = nil
    var usesDerivedCodexParentTitle: Bool? = nil

    var compactSelectionKey: CompactTaskSelectionKey {
        CompactTaskSelectionKey(provider: provider, id: id, file: lastActivityFileIdentity, startKey: startKey)
    }

    func codexAgentCountLabel(includingStatus: Bool) -> String? {
        guard let count = codexAgentCount, count > 0 else { return nil }
        let lastHundred = count % 100, last = count % 10
        let russian: String
        if (11...14).contains(lastHundred) { russian = "агентов" }
        else if last == 1 { russian = "агент" }
        else if (2...4).contains(last) { russian = "агента" }
        else { russian = "агентов" }
        let english = count == 1 ? "agent" : "agents"
        if includingStatus && codexAgentsUnconfirmed == true {
            return tr("(\(count) \(russian), статус не подтверждён)",
                      "(\(count) \(english), status unconfirmed)")
        }
        return tr("(\(count) \(russian))", "(\(count) \(english))")
    }

    var codexAgentCountLabel: String? { codexAgentCountLabel(includingStatus: true) }
    var codexAgentStatusLabel: String? {
        guard codexAgentsUnconfirmed == true else { return nil }
        if codexAgentCount == 1 { return tr("Статус агента не подтверждён", "Agent status unconfirmed") }
        return tr("Статус агентов не подтверждён", "Agent status unconfirmed")
    }

    var displayedActivity: String {
        guard provider == .codex, isUnconfirmed,
              ["Статус не подтверждён", "Status unconfirmed"].contains(activity),
              lastActivityIdentityConfirmed == true,
              let last = lastKnownActivity, !last.isEmpty else { return activity }
        return tr("Статус не подтверждён. Последнее: \(last)", "Status unconfirmed. Last: \(last)")
    }

    var planStatusNote: String? {
        guard !steps.isEmpty else { return nil }
        if !planConfirmed || isUnconfirmed {
            return tr("План не подтверждён", "Plan unconfirmed")
        }
        if provider == .claude {
            return tr("По известным этапам, возможна неточность", "Based on observed steps; may be inaccurate")
        }
        return nil
    }

    var stepCountLabel: String {
        let count = steps.count
        let lastHundred = count % 100
        let lastDigit = count % 10
        let russian: String
        if (11...14).contains(lastHundred) { russian = "этапов" }
        else if lastDigit == 1 { russian = "этап" }
        else if (2...4).contains(lastDigit) { russian = "этапа" }
        else { russian = "этапов" }
        return tr("\(count) \(russian)", "\(count) \(count == 1 ? "step" : "steps")")
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
        guard let progress, progressKind != .none, !isUnconfirmed else { return nil }
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

    mutating func prioritize(_ id: String) {
        nextPriority += 1
        priorities[id] = nextPriority
    }

    mutating func reconcile(current: [MonitoredTask], previous: [MonitoredTask], selectedID: String?, monitoringStartedAt: Date = .distantFuture,
                            selectableKeys: Set<CompactTaskSelectionKey>? = nil) -> (tasks: [MonitoredTask], selectedID: String?) {
        let previousBySource = Dictionary(grouping: previous, by: { CompactTaskSourceKey(provider: $0.provider, id: $0.id) })
        let present = Set(current.map(\.id))
        priorities = priorities.filter { present.contains($0.key) }
        let activated = current.filter { task in
            let recentlyObserved = (task.isUnconfirmed || task.isWaiting) && !task.startKey.isEmpty && task.startedAt >= monitoringStartedAt
            guard task.isActive || recentlyObserved else { return false }
            guard let sameSource = previousBySource[CompactTaskSourceKey(provider: task.provider, id: task.id)] else { return true }
            let sameFile = task.lastActivityFileIdentity.map { file in
                sameSource.filter { $0.lastActivityFileIdentity == file }
            } ?? []
            let candidates = sameFile.isEmpty ? sameSource : sameFile
            if task.startKey.isEmpty {
                return task.isActive && candidates.allSatisfy { !$0.isActive }
            }
            return !candidates.contains { $0.startKey == task.startKey }
        }.sorted { left, right in
            let leftStart = left.startedAt == .distantPast ? left.updatedAt : left.startedAt
            let rightStart = right.startedAt == .distantPast ? right.updatedAt : right.startedAt
            return leftStart == rightStart ? left.id < right.id : leftStart < rightStart
        }
        for task in activated where selectableKeys?.contains(task.compactSelectionKey) ?? true {
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
        let visible = ordered.filter { selectableKeys?.contains($0.compactSelectionKey) ?? true }.prefix(3)
        let requested = activated.last(where: { selectableKeys?.contains($0.compactSelectionKey) ?? true })?.id ?? selectedID
        let selected = requested.flatMap { id in visible.contains { $0.id == id } ? id : nil } ?? visible.first?.id
        return (ordered, selected)
    }
}

enum TaskSnapshotMerger {
    static func confirmCodexActivities(_ tasks: [MonitoredTask], files: [String: CodexFileIdentity]) -> [MonitoredTask] {
        tasks.map { task in
            guard task.provider == .codex, task.isUnconfirmed, let identity = task.lastActivityFileIdentity,
                  files[task.id] == identity else { return task }
            var confirmed = task
            confirmed.lastActivityIdentityConfirmed = true
            return confirmed
        }
    }

    static func merge(previous: [MonitoredTask], current: [MonitoredTask], terminalIDs: Set<String>) -> [MonitoredTask] {
        let currentIDs = Set(current.map(\.id))
        var result = current
        for task in previous where !currentIDs.contains(task.id) && !terminalIDs.contains(task.id) {
            var uncertain = task
            if uncertain.provider == .codex && uncertain.lastKnownActivity == nil &&
                !task.activity.isEmpty && !["Статус не подтверждён", "Status unconfirmed", "Выполняется", "Working"].contains(task.activity) {
                uncertain.lastKnownActivity = task.activity
            }
            if uncertain.provider == .codex { uncertain.lastActivityIdentityConfirmed = false }
            if uncertain.provider == .codex && uncertain.usesDerivedCodexParentTitle == true {
                uncertain.title = tr("Задача Codex", "Codex task")
                uncertain.usesDerivedCodexParentTitle = false
            }
            uncertain.isActive = false
            uncertain.isUnconfirmed = true
            uncertain.isWaiting = false
            uncertain.planConfirmed = false
            uncertain.progress = nil
            uncertain.progressKind = .none
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
