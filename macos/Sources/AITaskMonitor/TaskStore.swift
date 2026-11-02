import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published var selectedProvider: ProviderFilter = .all
    @Published var showsSettings = false
    @Published var isCompact = false
    @Published var compactIndex = 0
    @Published var sourceMessage = ""
    @Published private(set) var unavailableSources: [TaskProvider] = []

    private let codexReader: CodexTaskReader
    private let claudeReader: ClaudeTaskReader
    private let monitoringStartedAt = Date()
    private var previousCodex: [MonitoredTask] = []
    private var previousClaude: [MonitoredTask] = []
    private var sawCodexHome = false
    private var sawClaudeEvents = false
    private var timer: Timer?

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        if let previewTasks {
            tasks = previewTasks
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    static func preview(unavailableSources: [TaskProvider] = []) -> TaskStore {
        let store = TaskStore(previewTasks: [
            MonitoredTask(
                id: "codex-preview", provider: .codex,
                title: "Создать индикатор прогресса задач",
                activity: "Проверяю нативную сборку и формирую установочный образ",
                isActive: true, progress: 60, progressKind: .exact,
                steps: [
                    TaskStep(title: "Собрать модель активных задач", status: .done),
                    TaskStep(title: "Подключить локальные источники", status: .done),
                    TaskStep(title: "Проверить интерфейс macOS", status: .done),
                    TaskStep(title: "Собрать универсальное приложение", status: .active),
                    TaskStep(title: "Опубликовать установочный образ", status: .pending),
                    TaskStep(title: "Проверить установку на чистом Mac", status: .pending)
                ], updatedAt: Date()
            ),
            MonitoredTask(
                id: "claude-preview", provider: .claude,
                title: "Задача Claude Code",
                activity: "Выполняет проверку локальных lifecycle hooks и сохранения событий",
                isActive: true, progress: nil, progressKind: .none,
                steps: [], updatedAt: Date().addingTimeInterval(-15)
            )
        ])
        store.unavailableSources = unavailableSources
        store.tasks = store.tasks.map { task in
            guard unavailableSources.contains(task.provider) else { return task }
            var uncertain = task
            uncertain.isActive = false
            uncertain.isUnconfirmed = true
            uncertain.activity = "Статус не подтверждён"
            return uncertain
        }
        return store
    }

    var providers: Set<TaskProvider> { Set(tasks.map(\.provider)) }
    var unavailableMessage: String {
        guard !unavailableSources.isEmpty else { return "" }
        return "Нет данных от " + unavailableSources.map(\.displayName).joined(separator: ", ")
    }
    var filteredTasks: [MonitoredTask] {
        switch selectedProvider {
        case .all: return tasks
        case .codex: return tasks.filter { $0.provider == .codex }
        case .claude: return tasks.filter { $0.provider == .claude }
        }
    }

    func count(for filter: ProviderFilter) -> Int {
        switch filter {
        case .all: return tasks.filter(\.isActive).count
        case .codex: return tasks.filter { $0.isActive && $0.provider == .codex }.count
        case .claude: return tasks.filter { $0.isActive && $0.provider == .claude }.count
        }
    }

    func refresh() {
        var unavailable: [TaskProvider] = []
        do {
            let exists = FileManager.default.fileExists(atPath: codexReader.codexHome.path)
            if !exists && sawCodexHome { throw CocoaError(.fileReadNoSuchFile) }
            if exists { sawCodexHome = true }
            let snapshot = try codexReader.readSnapshot(observedSince: monitoringStartedAt)
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
        } catch {
            unavailable.append(.codex)
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
        }
        do {
            let exists = FileManager.default.fileExists(atPath: claudeReader.eventFile.path)
            if !exists && sawClaudeEvents { throw CocoaError(.fileReadNoSuchFile) }
            if exists {
                sawClaudeEvents = true
                let snapshot = try claudeReader.readSnapshot(observedSince: monitoringStartedAt)
                previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
            }
        } catch {
            unavailable.append(.claude)
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
        }
        unavailableSources = unavailable
        let combined = (previousCodex + previousClaude)
            .filter { $0.isActive || $0.isUnconfirmed }
            .sorted { $0.updatedAt > $1.updatedAt }
        tasks = combined
        if compactIndex >= max(combined.count, 1) { compactIndex = 0 }
        if selectedProvider == .codex, !providers.contains(.codex) { selectedProvider = .all }
        if selectedProvider == .claude, !providers.contains(.claude) { selectedProvider = .all }
    }

    func setClaudeConnected(_ connected: Bool) {
        do {
            try ClaudeIntegration.setConnected(connected)
            sourceMessage = connected ? "Подключено. Перезапустите Claude Code." : "Отключено"
        } catch {
            sourceMessage = error.localizedDescription
        }
    }
}
