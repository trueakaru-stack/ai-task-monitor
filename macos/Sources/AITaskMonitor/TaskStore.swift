import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published var selectedProvider: ProviderFilter = .all
    @Published var showsSettings = false
    @Published var showsAbout = false
    @Published var isCompact = false
    @Published var compactIndex = 0
    @Published var sourceMessage = ""
    @Published private(set) var unavailableSources: [TaskProvider] = []
    @Published var showsJournal = false
    @Published private(set) var diagnosticSettings = DiagnosticSettings()
    @Published private(set) var journalEvents: [DiagnosticEvent] = []
    @Published private(set) var journalTaskNames: [String: String] = [:]
    @Published private(set) var journalError = ""
    @Published private(set) var claudeLoopError = ""
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var dismissedUpdateVersion = ""
    @Published var updateOpenError = false

    private let codexReader: CodexTaskReader
    private let claudeReader: ClaudeTaskReader
    private let diagnosticWorker: DiagnosticWorker?
    private let claudeLoopProfile: URL?
    private let updateChecksEnabled: Bool
    private let monitoringStartedAt = Date()
    private var previousCodex: [MonitoredTask] = []
    private var previousClaude: [MonitoredTask] = []
    private var taskFocus = TaskFocusTracker()
    private var sawCodexHome = false
    private var sawClaudeEvents = false
    private var nextJournalMaintenance = Date.distantPast
    private var loopDetectors: [String: LoopDetector] = [:]
    private var claudeLoopChannel: ClaudeLoopChannel?
    private var claudeLoopDetectors: [String: ClaudeLoopTracker] = [:]
    private var timer: Timer?
    private var lastUpdateCheck = Date.distantPast
    private var releaseRequest: ReleaseRequest?

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil, journal: DiagnosticJournal? = nil, claudeLoopProfile: URL? = nil, enableUpdateChecks: Bool = false) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.claudeLoopProfile = claudeLoopProfile
        self.updateChecksEnabled = enableUpdateChecks && previewTasks == nil
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
                    if changed { self.loopDetectors.removeAll(); self.claudeLoopDetectors.removeAll(); self.refresh() }
                case .failure(let error): self.journalError = error.localizedDescription
                }
            }
        }
        refresh()
        checkForUpdates()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.checkForUpdates() }
        }
    }

    deinit {
        timer?.invalidate()
        releaseRequest?.cancel()
        claudeLoopChannel?.stop()
    }

    var visibleUpdate: AvailableUpdate? {
        guard !isCompact, let availableUpdate, availableUpdate.version != dismissedUpdateVersion else { return nil }
        return availableUpdate
    }

    func dismissUpdate() {
        if let availableUpdate { dismissedUpdateVersion = availableUpdate.version }
        updateOpenError = false
    }

    func acceptReleaseData(_ data: Data) {
        if let update = ReleaseSelector.select(data: data, currentVersion: AppVersion.current) { availableUpdate = update }
    }

    func checkForUpdates(now: Date = Date()) {
        guard updateChecksEnabled, releaseRequest == nil, now.timeIntervalSince(lastUpdateCheck) >= 24 * 60 * 60 else { return }
        lastUpdateCheck = now
        let request = ReleaseRequest { [weak self] data in
            DispatchQueue.main.async {
                guard let self else { return }
                self.releaseRequest = nil
                if let data { self.acceptReleaseData(data) }
            }
        }
        releaseRequest = request
        request.start()
    }

    func setPreviewUpdate() {
        availableUpdate = AvailableUpdate(version: "0.4.0-alpha", url: URL(string: "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.4.0-alpha/app.dmg")!)
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

    static func loopPreview(unavailableSources: [TaskProvider] = [], provider: TaskProvider = .codex, showsError: Bool = false) -> TaskStore {
        let store = preview(unavailableSources: unavailableSources)
        if let index = store.tasks.firstIndex(where: { $0.provider == provider }) {
            store.tasks[index].loopWarning = LoopWarning(threshold: 5, windowMinutes: 10)
            store.compactIndex = index
        }
        if provider == .claude { store.selectedProvider = .claude }
        if showsError { store.claudeLoopError = "Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение." }
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
        var claudeConnected = false
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
                claudeConnected = !claudeReader.usesExplicitFile || claudeLoopProfile != nil
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
            claudeConnected = false
            unavailable.append(.claude)
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
        }
        unavailableSources = unavailable
        var combined = (previousCodex + previousClaude)
            .filter { $0.isActive || $0.isUnconfirmed }
            .sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        syncClaudeLoop(connected: claudeConnected, now: now)
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
            if id.hasPrefix("claude:") { claudeLoopDetectors.removeValue(forKey: String(id.dropFirst(7))) }
        }
        for index in combined.indices where combined[index].provider == .codex && combined[index].isActive {
            combined[index].loopWarning = loopDetectors[combined[index].id]?.warning
        }
        for index in combined.indices where combined[index].provider == .claude && combined[index].isActive {
            let id = combined[index].id
            let session = id.hasPrefix("claude:") ? String(id.dropFirst(7)) : id
            combined[index].loopWarning = claudeLoopDetectors[session]?.warning
        }
        let trackedIDs = Set(combined.filter { $0.provider == .codex }.map(\.id))
        if loopDetectors.count > 256 {
            for id in Array(loopDetectors.keys) where !trackedIDs.contains(id) && loopDetectors.count > 256 {
                loopDetectors.removeValue(forKey: id)
            }
        }
        let selectedID = previousTasks.indices.contains(compactIndex) ? previousTasks[compactIndex].id : nil
        let focus = taskFocus.reconcile(current: combined, previous: previousTasks, selectedID: selectedID, monitoringStartedAt: monitoringStartedAt)
        combined = focus.tasks
        tasks = combined
        compactIndex = focus.selectedID.flatMap { id in combined.firstIndex { $0.id == id } } ?? 0
        if selectedProvider == .codex, !providers.contains(.codex) { selectedProvider = .all }
        if selectedProvider == .claude, !providers.contains(.claude) { selectedProvider = .all }
        recordChanges(previousTasks: previousTasks, previousUnavailable: previousUnavailable,
                      terminalIDs: terminalIDs, interruptedIDs: interruptedIDs, toolInputs: toolInputs)
    }

    private func syncClaudeLoop(connected: Bool, now: Date) {
        guard connected, diagnosticWorker != nil else {
            claudeLoopChannel?.stop()
            claudeLoopChannel = nil
            claudeLoopDetectors.removeAll()
            claudeLoopError = ""
            return
        }
        if claudeLoopChannel == nil {
            do { claudeLoopChannel = try ClaudeLoopChannel(profile: claudeLoopProfile ?? AppPaths.supportDirectory) }
            catch {
                claudeLoopDetectors.removeAll()
                claudeLoopError = "Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение."
                return
            }
        }
        guard let channel = claudeLoopChannel else { return }
        claudeLoopError = ""
        let batch = channel.drain()
        if batch.gap { claudeLoopDetectors.removeAll() }
        for event in batch.events {
            if claudeLoopDetectors[event.sessionID] == nil {
                guard event.kind == .start else { continue }
                if claudeLoopDetectors.count >= 256,
                   let oldest = claudeLoopDetectors.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key {
                    claudeLoopDetectors.removeValue(forKey: oldest)
                }
                claudeLoopDetectors[event.sessionID] = ClaudeLoopTracker(threshold: diagnosticSettings.loopThreshold,
                                                                          windowMinutes: diagnosticSettings.loopWindowMinutes)
            }
            guard var detector = claudeLoopDetectors[event.sessionID] else { continue }
            detector.configure(threshold: diagnosticSettings.loopThreshold, windowMinutes: diagnosticSettings.loopWindowMinutes)
            detector.consume(event, now: now)
            if event.kind == .stop { claudeLoopDetectors.removeValue(forKey: event.sessionID) }
            else { claudeLoopDetectors[event.sessionID] = detector }
        }
        for id in Array(claudeLoopDetectors.keys) {
            guard var detector = claudeLoopDetectors[id] else { continue }
            detector.configure(threshold: diagnosticSettings.loopThreshold, windowMinutes: diagnosticSettings.loopWindowMinutes)
            detector.refresh(now: now)
            if detector.lastSeen < now.addingTimeInterval(-1800) { claudeLoopDetectors.removeValue(forKey: id) }
            else { claudeLoopDetectors[id] = detector }
        }
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
        if taskID.hasPrefix("claude:") {
            let session = String(taskID.dropFirst(7))
            guard var detector = claudeLoopDetectors[session] else { return }
            detector.dismiss()
            claudeLoopDetectors[session] = detector
            if let index = tasks.firstIndex(where: { $0.id == taskID }) { tasks[index].loopWarning = nil }
            return
        }
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
