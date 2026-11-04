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
    @Published private(set) var openCodeMessage = ""
    @Published private(set) var openCodeSetupInProgress = false
    @Published private(set) var unavailableSources: [TaskProvider] = []
    @Published var showsJournal = false
    @Published private(set) var diagnosticSettings = DiagnosticSettings()
    @Published private(set) var journalEvents: [DiagnosticEvent] = []
    @Published private(set) var journalTaskNames: [String: String] = [:]
    @Published private(set) var journalError = ""
    @Published private(set) var claudeLoopError = ""
    @Published private(set) var claudeRetentionPolicy: ClaudeRetentionPolicy? = ClaudeRetentionPolicy.load()
    @Published private(set) var claudeRetentionFailed = false
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var dismissedUpdateVersion = ""
    @Published var updateOpenError = false

    private let codexReader: CodexTaskReader
    private let claudeReader: ClaudeTaskReader
    private let diagnosticWorker: DiagnosticWorker?
    private let claudeLoopProfile: URL?
    private let claudeRetentionWorker: ClaudeRetentionWorker?
    private let externalProvidersEnabled: Bool
    private let externalConnections: [TaskProvider: () throws -> ExternalProviderConnectionState]
    private let makeExternalRuntime: () throws -> ExternalProviderRuntime
    private var nextClaudeRetention = Date.distantPast
    private let updateChecksEnabled: Bool
    private let monitoringStartedAt = Date()
    private var previousCodex: [MonitoredTask] = []
    private var previousClaude: [MonitoredTask] = []
    private var previousExternal: [MonitoredTask] = []
    private var externalRuntime: ExternalProviderRuntime?
    private var seenExternalConnections: Set<TaskProvider> = []
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

    func setOpenCodeConnected(_ connect: Bool) {
        guard !openCodeSetupInProgress else { return }
        openCodeSetupInProgress = true
        openCodeMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try OpenCodeIntegration.setConnected(connect) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.openCodeSetupInProgress = false
                switch result {
                case .success:
                    self.refresh()
                case .failure:
                    self.openCodeMessage = tr("Не удалось изменить подключение OpenCode. Проверьте установку и совместимость версии.", "Could not change the OpenCode connection. Check its installation and version compatibility.")
                }
            }
        }
    }

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil, journal: DiagnosticJournal? = nil, claudeLoopProfile: URL? = nil, enableUpdateChecks: Bool = false, enableClaudeRetention: Bool = false, enableExternalProviders: Bool = false, openCodeConnection: @escaping () throws -> OpenCodeIntegration.State = { try OpenCodeIntegration.state() }, additionalExternalConnections: [TaskProvider: () throws -> ExternalProviderConnectionState] = [:], makeExternalRuntime: @escaping () throws -> ExternalProviderRuntime = { try ExternalProviderRuntime(channel: ExternalProviderChannel()) }) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.claudeLoopProfile = claudeLoopProfile
        self.externalProvidersEnabled = enableExternalProviders && previewTasks == nil
        var connections = additionalExternalConnections.filter { [.kimi, .deepseek, .hermes].contains($0.key) }
        connections[.opencode] = openCodeConnection
        self.externalConnections = connections
        self.makeExternalRuntime = makeExternalRuntime
        self.claudeRetentionWorker = enableClaudeRetention && previewTasks == nil ? ClaudeRetentionWorker() : nil
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
        maintainClaudeRetention()
        checkForUpdates()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.checkForUpdates(); self?.maintainClaudeRetention() }
        }
    }

    deinit {
        claudeRetentionWorker?.invalidate()
        timer?.invalidate()
        releaseRequest?.cancel()
        claudeLoopChannel?.stop()
        externalRuntime?.stop()
    }

    func setClaudeRetention(days: Int? = nil, maximumMB: Int? = nil) {
        guard let current = claudeRetentionPolicy else { return }
        let next = ClaudeRetentionPolicy(days: days ?? current.days, maximumMB: maximumMB ?? current.maximumMB)
        guard (1...30).contains(next.days), (1...100).contains(next.maximumMB) else { return }
        if days != nil { UserDefaults.standard.set(next.days, forKey: "claudeRetentionDays") }
        if maximumMB != nil { UserDefaults.standard.set(next.maximumMB, forKey: "claudeMaximumMB") }
        claudeRetentionPolicy = next
        claudeRetentionFailed = false
        nextClaudeRetention = .distantPast
        maintainClaudeRetention()
    }

    private func maintainClaudeRetention(now: Date = Date()) {
        guard let worker = claudeRetentionWorker else { return }
        guard let policy = ClaudeRetentionPolicy.load() else {
            if claudeRetentionPolicy != nil { worker.invalidate() }
            claudeRetentionPolicy = nil
            return
        }
        if claudeRetentionPolicy != policy { claudeRetentionPolicy = policy; nextClaudeRetention = .distantPast }
        guard now >= nextClaudeRetention else { return }
        nextClaudeRetention = now.addingTimeInterval(300)
        worker.schedule(policy: policy, directory: AppPaths.supportDirectory, backups: AppPaths.claudeSettings.deletingLastPathComponent()) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudeRetentionFailed = !success
                if !success { self.nextClaudeRetention = Date().addingTimeInterval(30) }
            }
        }
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

    static func preview(unavailableSources: [TaskProvider] = [], planUnconfirmed: Bool = false) -> TaskStore {
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
            var uncertain = task
            if task.provider == .codex && planUnconfirmed { uncertain.planConfirmed = false }
            if unavailableSources.contains(task.provider) {
                uncertain.isActive = false
                uncertain.isUnconfirmed = true
                uncertain.activity = tr("Статус не подтверждён", "Status unconfirmed")
            }
            return uncertain
        }
        return store
    }

    static func manySourcesPreview() -> TaskStore {
        let now = Date()
        let examples = TaskProvider.allCases.enumerated().map { index, provider in
            MonitoredTask(id: "preview-\(provider.rawValue)", provider: provider,
                title: "\(provider.displayName) · \(tr("задача", "task"))",
                activity: tr("Выполняет действие", "Performing an action"), isActive: true,
                progress: nil, progressKind: .none, steps: [], updatedAt: now.addingTimeInterval(-Double(index)))
        }
        return TaskStore(previewTasks: examples)
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
        if showsError { store.claudeLoopError = tr("Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение.", "Claude Code loop warnings are unavailable. Check access or restart the app.") }
        return store
    }

    var providers: Set<TaskProvider> { Set(tasks.map(\.provider)) }
    var visibleProviderFilters: [ProviderFilter] {
        ProviderFilter.allCases.filter { filter in filter == .all || filter.provider.map { providers.contains($0) } == true }
    }
    var unavailableMessage: String {
        guard !unavailableSources.isEmpty else { return "" }
        return tr("Нет данных от ", "No data from ") + unavailableSources.map(\.displayName).joined(separator: ", ")
    }
    var filteredTasks: [MonitoredTask] {
        guard let provider = selectedProvider.provider else { return tasks }
        return tasks.filter { $0.provider == provider }
    }

    func count(for filter: ProviderFilter) -> Int {
        guard let provider = filter.provider else { return tasks.filter(\.isActive).count }
        return tasks.filter { $0.isActive && $0.provider == provider }.count
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
            let connection: ClaudeIntegration.ConnectionState
            if claudeReader.usesExplicitFile { connection = .connected }
            else { connection = try ClaudeIntegration.connectionState() }
            if connection == .disconnected {
                previousClaude = []
                sawClaudeEvents = false
            } else {
                let complete = connection == .connected
                claudeConnected = complete && (!claudeReader.usesExplicitFile || claudeLoopProfile != nil)
                if !complete { unavailable.append(.claude) }
                let exists = FileManager.default.fileExists(atPath: claudeReader.eventFile.path)
                if !exists && sawClaudeEvents { throw CocoaError(.fileReadNoSuchFile) }
                if exists {
                    sawClaudeEvents = true
                    let snapshot = try claudeReader.readSnapshot(observedSince: monitoringStartedAt)
                    terminalIDs.formUnion(snapshot.terminalIDs)
                    interruptedIDs.formUnion(snapshot.interruptedIDs)
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: snapshot.tasks, terminalIDs: snapshot.terminalIDs)
                }
                if !complete {
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
                }
            }
        } catch {
            claudeConnected = false
            if !unavailable.contains(.claude) { unavailable.append(.claude) }
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
        }
        if externalProvidersEnabled { refreshExternalProviders(unavailable: &unavailable) }
        unavailableSources = unavailable
        var combined = (previousCodex + previousClaude + previousExternal)
            .filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
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
        if let provider = selectedProvider.provider, !providers.contains(provider) { selectedProvider = .all }
        recordChanges(previousTasks: previousTasks, previousUnavailable: previousUnavailable,
                      terminalIDs: terminalIDs, interruptedIDs: interruptedIDs, toolInputs: toolInputs)
    }

    private func refreshExternalProviders(unavailable: inout [TaskProvider]) {
        var allowed: Set<TaskProvider> = []
        var uncertain: Set<TaskProvider> = []
        for provider in TaskProvider.allCases {
            guard let connection = externalConnections[provider] else { continue }
            do {
                switch try connection() {
                case .connected:
                    seenExternalConnections.insert(provider)
                    allowed.insert(provider)
                case .partial:
                    unavailable.append(provider)
                    uncertain.insert(provider)
                case .disconnected:
                    seenExternalConnections.remove(provider)
                }
            } catch {
                if seenExternalConnections.contains(provider) {
                    unavailable.append(provider)
                    uncertain.insert(provider)
                }
            }
        }
        let retained = unconfirmedExternalTasks(for: uncertain)
        guard !allowed.isEmpty else {
            externalRuntime?.stop()
            externalRuntime = nil
            previousExternal = retained
            return
        }
        do {
            if externalRuntime == nil { externalRuntime = try makeExternalRuntime() }
            previousExternal = (externalRuntime?.snapshot(allowed: allowed) ?? []) + retained
        } catch {
            for provider in TaskProvider.allCases where allowed.contains(provider) && !unavailable.contains(provider) {
                unavailable.append(provider)
            }
            previousExternal = unconfirmedExternalTasks(for: uncertain.union(allowed))
            externalRuntime?.stop()
            externalRuntime = nil
        }
    }

    private func unconfirmedExternalTasks(for providers: Set<TaskProvider>) -> [MonitoredTask] {
        previousExternal.filter { providers.contains($0.provider) }.map { task in
            var copy = task
            copy.isActive = false
            copy.isWaiting = false
            copy.isUnconfirmed = true
            copy.activity = tr("Статус не подтверждён", "Status unconfirmed")
            copy.planConfirmed = false
            return copy
        }
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
                claudeLoopError = tr("Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение.", "Claude Code loop warnings are unavailable. Check access or restart the app.")
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
            sourceMessage = connected ? tr("Подключено. Перезапустите Claude Code.", "Connected. Restart Claude Code.") : tr("Отключено", "Disconnected")
            refresh()
        } catch {
            sourceMessage = error.localizedDescription
        }
    }
}
