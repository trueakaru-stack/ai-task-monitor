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

    private let codexReader: CodexTaskReader
    private let claudeReader: ClaudeTaskReader
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

    static func preview() -> TaskStore {
        TaskStore(previewTasks: [
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
                title: "Проверить интеграцию Claude Code с длинным названием задачи",
                activity: "Выполняет проверку локальных lifecycle hooks и сохранения событий",
                isActive: true, progress: nil, progressKind: .none,
                steps: [], updatedAt: Date().addingTimeInterval(-15)
            )
        ])
    }

    var providers: Set<TaskProvider> { Set(tasks.map(\.provider)) }
    var filteredTasks: [MonitoredTask] {
        switch selectedProvider {
        case .all: return tasks
        case .codex: return tasks.filter { $0.provider == .codex }
        case .claude: return tasks.filter { $0.provider == .claude }
        }
    }

    func count(for filter: ProviderFilter) -> Int {
        switch filter {
        case .all: return tasks.count
        case .codex: return tasks.filter { $0.provider == .codex }.count
        case .claude: return tasks.filter { $0.provider == .claude }.count
        }
    }

    func refresh() {
        let combined = (codexReader.readTasks() + claudeReader.readTasks())
            .filter(\.isActive)
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
            sourceMessage = "Не удалось изменить настройки Claude Code"
        }
    }
}
