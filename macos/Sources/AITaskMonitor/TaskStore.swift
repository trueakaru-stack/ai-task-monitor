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
    @Published var showsJournal = false
    @Published private(set) var diagnosticSettings = DiagnosticSettings()
    @Published private(set) var journalEvents: [DiagnosticEvent] = []
    @Published private(set) var journalTaskNames: [String: String] = [:]
    @Published private(set) var journalError = ""

    private let codexReader: CodexTaskReader
    private let claudeReader: ClaudeTaskReader
    private let diagnosticWorker: DiagnosticWorker?
    private let monitoringStartedAt = Date()
    private var previousCodex: [MonitoredTask] = []
    private var previousClaude: [MonitoredTask] = []
    private var sawCodexHome = false
    private var sawClaudeEvents = false
    private var nextJournalMaintenance = Date.distantPast
    private var loopDetectors: [String: LoopDetector] = [:]
    private var timer: Timer?

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil, journal: DiagnosticJournal? = nil) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.diagnosticWorker = previewTasks == nil ? DiagnosticWorker(journal: journal ?? DiagnosticJournal()) : nil
        if let previewTasks {
            tasks = previewTasks
            return
        }
        diagnosticWorker?.load { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let settings):
                    let changed = self.diagnosticSettings.loopThreshold != settings.loopThreshold ||
                        self.diagnosticSettings.loopWindowMinutes != settings.loopWindowMinutes
                    self.diagnosticSettings = settings
                    if changed { self.loopDetectors.removeAll(); self.refresh() }
                case .failure(let error): self.journalError = error.localizedDescription
                }
            }
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
                isActive: true, progress: 50, progressKind: .exact,
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

    static func journalPreview() -> TaskStore {
        let store = preview()
        let key = String(repeating: "a", count: 64)
        let now = Date()
        store.journalEvents = [
            DiagnosticEvent(version: 1, time: now.addingTimeInterval(-30), source: .codex, task: key, type: .taskObserved, id: UUID()),
            DiagnosticEvent(version: 1, time: now.addingTimeInterval(-10), source: .codex, task: key, type: .toolStarted, id: UUID()),
            DiagnosticEvent(version: 1, time: now, source: .claude, task: nil, type: .sourceUnavailable, id: UUID())
        ]
        store.journalTaskNames = [key: "Создать индикатор прогресса задач"]
        store.showsSettings = true
        store.showsJournal = true
        return store
    }

    static func loopPreview(unavailableSources: [TaskProvider] = []) -> TaskStore {
        let store = preview(unavailableSources: unavailableSources)
        if !store.tasks.isEmpty { store.tasks[0].loopWarning = LoopWarning(threshold: 5, windowMinutes: 10) }
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
        let previousTasks = tasks
        let previousUnavailable = unavailableSources
        var unavailable: [TaskProvider] = []
        var terminalIDs: Set<String> = []
        var interruptedIDs: Set<String> = []
        var codexToolEvents: [String: [CodexToolEvent]] = [:]
        do {
            let exists = FileManager.default.fileExists(atPath: codexReader.codexHome.path)
            if !exists && sawCodexHome { throw CocoaError(.fileReadNoSuchFile) }
            if exists { sawCodexHome = true }
            let snapshot = try codexReader.readSnapshot(observedSince: monitoringStartedAt, previouslyObserved: Set(previousCodex.map(\.id)))
            terminalIDs.formUnion(snapshot.terminalIDs)
            interruptedIDs.formUnion(snapshot.interruptedIDs)
            codexToolEvents = snapshot.toolEvents
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
        } catch {
            unavailable.append(.codex)
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
        }
        do {
            let connected: Bool
            if claudeReader.usesExplicitFile { connected = true }
            else { connected = try ClaudeIntegration.connectionState() }
            if !connected {
                previousClaude = []
                sawClaudeEvents = false
            } else {
                let exists = FileManager.default.fileExists(atPath: claudeReader.eventFile.path)
                if !exists && sawClaudeEvents { throw CocoaError(.fileReadNoSuchFile) }
                if exists {
                    sawClaudeEvents = true
                    let snapshot = try claudeReader.readSnapshot(observedSince: monitoringStartedAt)
                    terminalIDs.formUnion(snapshot.terminalIDs)
                    interruptedIDs.formUnion(snapshot.interruptedIDs)
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
                }
            }
        } catch {
            unavailable.append(.claude)
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
        }
        unavailableSources = unavailable
        var combined = (previousCodex + previousClaude)
            .filter { $0.isActive || $0.isUnconfirmed }
            .sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        for id in Array(loopDetectors.keys) {
            guard var detector = loopDetectors[id] else { continue }
            detector.configure(threshold: diagnosticSettings.loopThreshold, windowMinutes: diagnosticSettings.loopWindowMinutes)
            detector.refresh(now: now)
            loopDetectors[id] = detector
        }
        let knownTasks = previousTasks + combined
        var toolInputs: [DiagnosticInput] = []
        for (id, events) in codexToolEvents {
            guard knownTasks.contains(where: { $0.provider == .codex && $0.id == id }) else { continue }
            var detector = loopDetectors[id] ?? LoopDetector(threshold: diagnosticSettings.loopThreshold, windowMinutes: diagnosticSettings.loopWindowMinutes)
            for event in events {
                if let type = detector.consume(event, now: now) {
                    toolInputs.append(DiagnosticInput(source: .codex, taskID: id, type: type, time: event.time,
                                                      reference: event.kind.rawValue + "-" + event.id))
                }
            }
            detector.refresh(now: now)
            loopDetectors[id] = detector
        }
        for id in terminalIDs {
            if var detector = loopDetectors[id] { detector.finishTurn(); loopDetectors[id] = detector }
        }
        for index in combined.indices where combined[index].provider == .codex && combined[index].isActive {
            combined[index].loopWarning = loopDetectors[combined[index].id]?.warning
        }
        let trackedIDs = Set(combined.filter { $0.provider == .codex }.map(\.id))
        if loopDetectors.count > 256 {
            for id in Array(loopDetectors.keys) where !trackedIDs.contains(id) && loopDetectors.count > 256 {
                loopDetectors.removeValue(forKey: id)
            }
        }
        tasks = combined
        if compactIndex >= max(combined.count, 1) { compactIndex = 0 }
        if selectedProvider == .codex, !providers.contains(.codex) { selectedProvider = .all }
        if selectedProvider == .claude, !providers.contains(.claude) { selectedProvider = .all }
        recordChanges(previousTasks: previousTasks, previousUnavailable: previousUnavailable,
                      terminalIDs: terminalIDs, interruptedIDs: interruptedIDs, toolInputs: toolInputs)
    }

    func setDiagnosticSettings(_ settings: DiagnosticSettings) {
        guard settings.isValid else { return }
        let previous = diagnosticSettings
        diagnosticSettings = settings
        guard let diagnosticWorker else { return }
        diagnosticWorker.save(settings) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.updateJournal([], showEvents: self.showsJournal)
                case .failure(let error):
                    if self.diagnosticSettings == settings { self.diagnosticSettings = previous }
                    self.journalError = error.localizedDescription
                }
            }
        }
    }

    func openJournal() {
        showsJournal = true
        updateJournal([], showEvents: true)
    }

    func clearJournal() {
        guard let diagnosticWorker else { journalEvents = []; return }
        diagnosticWorker.clear { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.journalEvents = []; self.journalTaskNames = [:]; self.journalError = ""
                case .failure(let error): self.journalError = error.localizedDescription
                }
            }
        }
    }

    func dismissLoop(for taskID: String) {
        guard var detector = loopDetectors[taskID] else {
            if diagnosticWorker == nil, let index = tasks.firstIndex(where: { $0.id == taskID }) { tasks[index].loopWarning = nil }
            return
        }
        detector.dismiss()
        loopDetectors[taskID] = detector
        if let index = tasks.firstIndex(where: { $0.id == taskID }) { tasks[index].loopWarning = nil }
    }

    private func journalID(for task: MonitoredTask) -> String? {
        let id = task.provider == .claude && task.id.hasPrefix("claude:") ? String(task.id.dropFirst(7)) : task.id
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
        }) else { return nil }
        return id
    }

    private func journalReferences() -> [DiagnosticTaskReference] {
        tasks.compactMap { task in
            guard let id = journalID(for: task) else { return nil }
            return DiagnosticTaskReference(source: task.provider, id: id, title: task.title)
        }
    }

    private func updateJournal(_ inputs: [DiagnosticInput], showEvents: Bool) {
        guard let diagnosticWorker else { return }
        let references = showEvents ? journalReferences() : nil
        diagnosticWorker.update(inputs, references: references) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let view):
                    self.journalError = ""
                    if let view { self.journalEvents = view.events; self.journalTaskNames = view.taskNames }
                case .failure(let error): self.journalError = error.localizedDescription
                }
            }
        }
    }

    private func recordChanges(previousTasks: [MonitoredTask], previousUnavailable: [TaskProvider],
                               terminalIDs: Set<String>, interruptedIDs: Set<String>, toolInputs: [DiagnosticInput]) {
        guard diagnosticWorker != nil else { return }
        let now = Date()
        let oldByID = Dictionary(previousTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(tasks.map(\.id))
        var inputs = toolInputs
        for task in tasks {
            guard let id = journalID(for: task) else { continue }
            let previous = oldByID[task.id]
            if previous == nil || previous?.isActive != task.isActive || previous?.isUnconfirmed != task.isUnconfirmed {
                inputs.append(DiagnosticInput(source: task.provider, taskID: id,
                                              type: task.isUnconfirmed ? .taskUnconfirmed : .taskObserved, time: now))
            }
        }
        for task in previousTasks where !currentIDs.contains(task.id) && terminalIDs.contains(task.id) {
            guard let id = journalID(for: task) else { continue }
            inputs.append(DiagnosticInput(source: task.provider, taskID: id,
                                          type: interruptedIDs.contains(task.id) ? .taskInterrupted : .taskCompleted, time: now))
        }
        for provider in TaskProvider.allCases {
            let wasUnavailable = previousUnavailable.contains(provider)
            let isUnavailable = unavailableSources.contains(provider)
            if wasUnavailable != isUnavailable {
                inputs.append(DiagnosticInput(source: provider, taskID: nil,
                                              type: isUnavailable ? .sourceUnavailable : .sourceRecovered, time: now))
            }
        }
        guard !inputs.isEmpty || now >= nextJournalMaintenance else { return }
        nextJournalMaintenance = now.addingTimeInterval(300)
        updateJournal(inputs, showEvents: showsJournal)
    }

    func setClaudeConnected(_ connected: Bool) {
        do {
            try ClaudeIntegration.setConnected(connected)
            sourceMessage = connected ? "Подключено. Перезапустите Claude Code." : "Отключено"
            refresh()
        } catch {
            sourceMessage = error.localizedDescription
        }
    }
}
