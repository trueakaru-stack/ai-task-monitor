import Combine
import Foundation

@MainActor
final class TaskStore: ObservableObject {
    static func clearClaudePlanConfirmations(_ items: [MonitoredTask]) -> [MonitoredTask] {
        items.map { item in
            guard item.provider == .claude else { return item }
            var copy = item
            copy.planConfirmed = false
            copy.progress = nil
            copy.progressKind = .none
            return copy
        }
    }

    static func clearUnconfirmedClaudePlans(_ items: [MonitoredTask]) -> [MonitoredTask] {
        items.map { item in
            guard item.provider == .claude, item.isUnconfirmed else { return item }
            var uncertain = item
            uncertain.planConfirmed = false
            uncertain.progress = nil
            uncertain.progressKind = .none
            return uncertain
        }
    }

    @Published private(set) var tasks: [MonitoredTask] = []
    @Published var selectedProvider: ProviderFilter = .all
    @Published var showsSettings = false
    @Published var showsAbout = false
    @Published var isCompact = false
    @Published var compactIndex = 0
    @Published var sourceMessage = ""
    @Published private(set) var openCodeMessage = ""
    @Published private(set) var openCodeSetupInProgress = false
    @Published private(set) var deepSeekProfiles: [DeepSeekProfile] = []
    @Published var selectedDeepSeekProfile = ""
    @Published private(set) var deepSeekMessage = ""
    @Published private(set) var deepSeekSetupInProgress = false
    @Published private(set) var deepSeekScanInProgress = false
    @Published private(set) var deepSeekInstallationAvailable = false
    @Published private(set) var kimiState = "disconnected"
    @Published private(set) var kimiScanned = false
    @Published private(set) var kimiScanError: String?
    @Published private(set) var hermesProfiles: [HermesProfile] = []
    @Published var selectedHermesProfile = "" {
        didSet { if selectedHermesProfile != oldValue { hermesMessage = "" } }
    }
    @Published private(set) var hermesMessage = ""
    @Published private(set) var hermesSetupInProgress = false
    @Published private(set) var hermesScanInProgress = false
    @Published private(set) var hermesInstallationAvailable = false
    @Published private(set) var codexCloudEnabled = false
    @Published private(set) var codexCloudFailed = false
    @Published private(set) var codexCloudPartial = false
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
    private let inspectKimiConnection: () throws -> KimiConnection
    private let kimiScanInterval: TimeInterval
    private let discoverHermesContext: () -> HermesIntegration.Context?
    private let inspectHermesProfiles: (HermesIntegration.Context) throws -> [HermesProfile]
    private let prepareHermesProfile: (HermesProfile, HermesIntegration.Context) throws -> Void
    private let hermesScanInterval: TimeInterval
    private let codexCloudAllowed: Bool
    private let codexCloudDefaults: UserDefaults
    private let makeCodexCloudClient: () -> CodexCloudClient?
    private let codexCloudInterval: TimeInterval
    private var codexCloudClient: CodexCloudClient?
    private var codexCloudGeneration = 0
    private var nextCodexCloudScan = Date.distantPast
    private var previousCodexCloud: [CodexCloudReader.Task] = []
    private var nextClaudeRetention = Date.distantPast
    private var updateCoordinator: ReleaseUpdateCoordinator?
    private let monitoringStartedAt = Date()
    private var previousCodex: [MonitoredTask] = []
    private var previousClaude: [MonitoredTask] = []
    private var previousExternal: [MonitoredTask] = []
    private var externalRuntime: ExternalProviderRuntime?
    private var seenExternalConnections: Set<TaskProvider> = []
    private var kimiScope: String?
    private var kimiSeenScope: String?
    private var kimiScanInProgress = false
    private var nextKimiScan = Date.distantPast
    private var deepSeekContext: DeepSeekIntegration.Context?
    private var deepSeekSeenScopes: [String: String] = [:]
    private var deepSeekScanError: String?
    private var nextDeepSeekScan = Date.distantPast
    private var hermesContext: HermesIntegration.Context?
    private var hermesSeenScopes: [String: String] = [:]
    private var hermesScanError: String?
    private var nextHermesScan = Date.distantPast
    private var taskFocus = TaskFocusTracker()
    private var sawCodexHome = false
    private var sawClaudeEvents = false
    private var nextJournalMaintenance = Date.distantPast
    private var loopDetectors: [String: LoopDetector] = [:]
    private var claudeLoopChannel: ClaudeLoopChannel?
    private var claudePhaseEvidence = ClaudePhaseEvidence()
    private var claudeLoopDetectors: [String: ClaudeLoopTracker] = [:]
    private var timer: Timer?

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

    func setDeepSeekConnected(_ connect: Bool) {
        guard !deepSeekSetupInProgress, !deepSeekScanInProgress, let context = deepSeekContext,
              deepSeekProfiles.contains(where: { $0.name == selectedDeepSeekProfile }) else { return }
        let profile = selectedDeepSeekProfile
        deepSeekSetupInProgress = true
        deepSeekMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DeepSeekIntegration.setConnected(connect, profile: profile, context: context) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deepSeekSetupInProgress = false
                switch result {
                case .success:
                    if !connect { self.deepSeekSeenScopes.removeValue(forKey: profile) }
                case .failure(let error):
                    self.deepSeekMessage = self.deepSeekErrorMessage((error as? DeepSeekIntegrationError)?.code ?? "operation-failed")
                }
                self.nextDeepSeekScan = .distantPast
                self.refresh()
            }
        }
    }

    private func scheduleKimiScan() {
        guard externalProvidersEnabled, externalConnections[.kimi] == nil, !kimiScanInProgress,
              Date() >= nextKimiScan else { return }
        kimiScanInProgress = true
        let inspect = inspectKimiConnection
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try inspect() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.kimiScanInProgress = false
                self.nextKimiScan = Date().addingTimeInterval(self.kimiScanInterval)
                switch result {
                case .success(let connection):
                    guard ["connected", "disabled", "disconnected"].contains(connection.state),
                          (connection.state == "connected" ? DeepSeekIntegration.validScope(connection.scope) : connection.scope == nil) else {
                        self.kimiScanError = "invalid-response"
                        self.refresh()
                        return
                    }
                    self.kimiScanned = true
                    self.kimiScanError = nil
                    self.kimiState = connection.state
                    self.kimiScope = connection.scope
                    self.kimiSeenScope = connection.state == "connected" ? connection.scope : nil
                case .failure(let error):
                    self.kimiScanError = (error as? KimiIntegrationError)?.code ?? "operation-failed"
                }
                self.refresh()
            }
        }
    }

    var kimiStatusMessage: String {
        if let code = kimiScanError {
            return code == "installation-unconfirmed" ? tr("Установка не подтверждена", "Installation unconfirmed") : tr("Не удалось проверить плагин Kimi Code.", "Could not check the Kimi Code plugin.")
        }
        guard kimiScanned else { return tr("Проверка", "Checking") }
        switch kimiState {
        case "connected": return tr("Плагин включён", "Plugin enabled")
        case "disabled": return tr("Плагин отключён", "Plugin disabled")
        default: return tr("Плагин не установлен", "Plugin not installed")
        }
    }

    var kimiCanCopyPath: Bool { kimiScanned && kimiScanError == nil && KimiIntegration.pluginDirectory() != nil }

    private func kimiConnectionState() throws -> ExternalProviderConnectionState {
        if kimiScanError != nil {
            if kimiSeenScope == nil { return .disconnected }
            throw KimiIntegrationError(code: "operation-failed")
        }
        return kimiScanned && kimiState == "connected" ? .connected : .disconnected
    }

    private func scheduleDeepSeekScan() {
        guard externalProvidersEnabled, !deepSeekSetupInProgress, !deepSeekScanInProgress,
              Date() >= nextDeepSeekScan else { return }
        deepSeekScanInProgress = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = DeepSeekIntegration.discover()
            let result: Result<[DeepSeekProfile], Error>
            if let context { result = Result { try DeepSeekIntegration.profiles(context) } }
            else { result = .failure(DeepSeekIntegrationError(code: "installation-unconfirmed")) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deepSeekScanInProgress = false
                self.nextDeepSeekScan = Date().addingTimeInterval(15)
                self.deepSeekContext = context
                self.deepSeekInstallationAvailable = context != nil
                switch result {
                case .success(let profiles):
                    self.deepSeekScanError = nil
                    self.deepSeekProfiles = profiles
                    for item in profiles {
                        if item.state == "connected", let scope = item.scope { self.deepSeekSeenScopes[item.name] = scope }
                        else if item.state == "disconnected" { self.deepSeekSeenScopes.removeValue(forKey: item.name) }
                    }
                    if !profiles.contains(where: { $0.name == self.selectedDeepSeekProfile }) { self.selectedDeepSeekProfile = "" }
                case .failure(let error):
                    self.deepSeekScanError = (error as? DeepSeekIntegrationError)?.code ?? "operation-failed"
                }
                self.refresh()
            }
        }
    }

    private func deepSeekErrorMessage(_ code: String) -> String {
        if code.hasPrefix("bundle-conflict") {
            return tr("Подключение DeepSeek Harness неполное или его файлы изменены.", "The DeepSeek Harness connection is incomplete or its files were changed.")
        }
        switch code {
        case "unsupported-desktop":
            return tr("Профиль DeepSeek Desktop пока не поддерживается.", "The DeepSeek Desktop profile is not supported yet.")
        case "unverified-dsh", "unverified-pnpm":
            return tr("Версия DeepSeek Harness или pnpm не подтверждена.", "The DeepSeek Harness or pnpm version could not be verified.")
        case "linked-path", "bundle-conflict", "modified-bundle", "partial-connection":
            return tr("Подключение DeepSeek Harness неполное или его файлы изменены.", "The DeepSeek Harness connection is incomplete or its files were changed.")
        default:
            return tr("Не удалось изменить подключение DeepSeek Harness.", "Could not change the DeepSeek Harness connection.")
        }
    }

    var deepSeekSelectedProfile: DeepSeekProfile? { deepSeekProfiles.first { $0.name == selectedDeepSeekProfile } }
    var deepSeekCanChange: Bool {
        deepSeekScanError == nil && deepSeekContext != nil && !deepSeekSetupInProgress && !deepSeekScanInProgress &&
            deepSeekSelectedProfile != nil && deepSeekSelectedProfile?.state != "error"
    }
    var deepSeekStatusMessage: String {
        if let code = deepSeekScanError, code != "installation-unconfirmed" { return deepSeekErrorMessage(code) }
        if !deepSeekInstallationAvailable { return tr("Установка не подтверждена", "Installation unconfirmed") }
        guard let profile = deepSeekSelectedProfile else { return tr("Выберите профиль", "Select a profile") }
        switch profile.state {
        case "connected": return tr("Подключён", "Connected")
        case "partial": return tr("Подключён частично", "Partially connected")
        case "error": return deepSeekErrorMessage(profile.error ?? "operation-failed")
        default: return tr("Не подключён", "Not connected")
        }
    }

    private var deepSeekAllowedScopes: Set<String> {
        guard deepSeekScanError == nil else { return [] }
        return Set(deepSeekProfiles.compactMap { $0.state == "connected" ? $0.scope : nil })
    }

    private var deepSeekUncertainScopes: Set<String> {
        Set(deepSeekSeenScopes.compactMap { name, scope in
            let profile = deepSeekProfiles.first { $0.name == name }
            return deepSeekScanError != nil || profile == nil || profile?.state == "partial" || profile?.state == "error" ? scope : nil
        })
    }

    private func deepSeekConnectionState() throws -> ExternalProviderConnectionState {
        if deepSeekScanError != nil {
            if deepSeekSeenScopes.isEmpty { return .disconnected }
            throw DeepSeekIntegrationError(code: "operation-failed")
        }
        if !deepSeekAllowedScopes.isEmpty { return deepSeekUncertainScopes.isEmpty ? .connected : .connectedDegraded }
        return deepSeekUncertainScopes.isEmpty ? .disconnected : .partial
    }

    func prepareHermes() {
        guard !hermesSetupInProgress, !hermesScanInProgress, hermesScanError == nil,
              let context = hermesContext, let profile = hermesSelectedProfile,
              profile.state == "absent", HermesIntegration.command(profile, context: context, enable: true) != nil else { return }
        let prepare = prepareHermesProfile
        hermesSetupInProgress = true
        hermesMessage = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try prepare(profile, context) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hermesSetupInProgress = false
                if case .failure(let error) = result {
                    self.hermesMessage = self.hermesErrorMessage((error as? HermesIntegrationError)?.code ?? "operation-failed")
                }
                self.nextHermesScan = .distantPast
                self.refresh()
            }
        }
    }

    private func scheduleHermesScan() {
        guard externalProvidersEnabled, externalConnections[.hermes] == nil, !hermesSetupInProgress,
              !hermesScanInProgress, Date() >= nextHermesScan else { return }
        hermesScanInProgress = true
        let discover = discoverHermesContext, inspect = inspectHermesProfiles
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = discover()
            let result: Result<[HermesProfile], Error>
            if let context { result = Result { try inspect(context) } }
            else { result = .failure(HermesIntegrationError(code: "installation-unconfirmed")) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hermesScanInProgress = false
                self.nextHermesScan = Date().addingTimeInterval(self.hermesScanInterval)
                self.hermesContext = context
                self.hermesInstallationAvailable = context != nil
                switch result {
                case .success(let profiles) where HermesIntegration.validProfiles(profiles):
                    self.hermesScanError = nil
                    self.hermesProfiles = profiles
                    for item in profiles {
                        if item.state == "prepared", item.enabled == true, let scope = item.scope {
                            self.hermesSeenScopes[item.id] = scope
                        } else if item.state == "absent" || (item.state == "prepared" && item.enabled == false) {
                            self.hermesSeenScopes.removeValue(forKey: item.id)
                        }
                    }
                    if !profiles.contains(where: { $0.id == self.selectedHermesProfile }) { self.selectedHermesProfile = "" }
                case .success:
                    self.hermesScanError = "invalid-response"
                case .failure(let error):
                    self.hermesScanError = (error as? HermesIntegrationError)?.code ?? "operation-failed"
                }
                self.refresh()
            }
        }
    }

    private func hermesErrorMessage(_ code: String) -> String {
        switch code {
        case "unsupported-version":
            return tr("Версия Hermes не поддерживается.", "This Hermes version is not supported.")
        case "bundle-conflict", "bundle-busy", "bundle-update-required", "modified-bundle", "profile-unavailable":
            return tr("Плагин Hermes недоступен или его файлы изменены.", "The Hermes plugin is unavailable or its files were changed.")
        default:
            return tr("Не удалось проверить или подготовить плагин Hermes.", "Could not check or prepare the Hermes plugin.")
        }
    }

    var hermesSelectedProfile: HermesProfile? { hermesProfiles.first { $0.id == selectedHermesProfile } }
    var hermesCanPrepare: Bool {
        guard hermesScanError == nil, let context = hermesContext, let profile = hermesSelectedProfile else { return false }
        return !hermesSetupInProgress && !hermesScanInProgress && profile.state == "absent" &&
            HermesIntegration.command(profile, context: context, enable: true) != nil
    }
    var hermesStatusMessage: String {
        if let code = hermesScanError {
            return code == "installation-unconfirmed" ? tr("Установка не подтверждена", "Installation unconfirmed") : hermesErrorMessage(code)
        }
        guard hermesInstallationAvailable else { return tr("Проверка", "Checking") }
        guard let profile = hermesSelectedProfile else { return tr("Выберите профиль", "Select a profile") }
        switch profile.state {
        case "prepared":
            return profile.enabled == true
                ? tr("Плагин включён в локальных настройках", "Plugin enabled in local settings")
                : tr("Плагин подготовлен; включите его в Hermes", "Plugin prepared; enable it in Hermes")
        case "error": return hermesErrorMessage(profile.error ?? "operation-failed")
        default: return tr("Плагин не подготовлен", "Plugin not prepared")
        }
    }
    var hermesEnableCommand: String? {
        guard hermesScanError == nil, let context = hermesContext, let profile = hermesSelectedProfile,
              profile.state == "prepared" else { return nil }
        return HermesIntegration.command(profile, context: context, enable: true)
    }
    var hermesDisableCommand: String? {
        guard hermesScanError == nil, let context = hermesContext, let profile = hermesSelectedProfile,
              profile.state == "prepared" else { return nil }
        return HermesIntegration.command(profile, context: context, enable: false)
    }
    private var hermesAllowedScopes: Set<String> {
        guard hermesScanError == nil else { return [] }
        return Set(hermesProfiles.compactMap { $0.state == "prepared" && $0.enabled == true ? $0.scope : nil })
    }
    private var hermesUncertainScopes: Set<String> {
        Set(hermesSeenScopes.compactMap { id, scope in
            let profile = hermesProfiles.first { $0.id == id }
            return hermesScanError != nil || profile == nil || profile?.state == "error" ? scope : nil
        })
    }
    private func hermesConnectionState() throws -> ExternalProviderConnectionState {
        if hermesScanError != nil {
            if hermesSeenScopes.isEmpty { return .disconnected }
            throw HermesIntegrationError(code: "operation-failed")
        }
        if !hermesAllowedScopes.isEmpty { return hermesUncertainScopes.isEmpty ? .connected : .connectedDegraded }
        return hermesUncertainScopes.isEmpty ? .disconnected : .partial
    }

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil, journal: DiagnosticJournal? = nil, claudeLoopProfile: URL? = nil, enableUpdateChecks: Bool = false, enableClaudeRetention: Bool = false, enableExternalProviders: Bool = false, openCodeConnection: @escaping () throws -> OpenCodeIntegration.State = { try OpenCodeIntegration.state() }, additionalExternalConnections: [TaskProvider: () throws -> ExternalProviderConnectionState] = [:], makeExternalRuntime: @escaping () throws -> ExternalProviderRuntime = { try ExternalProviderRuntime(channel: ExternalProviderChannel()) }, inspectKimiConnection: @escaping () throws -> KimiConnection = {
        guard let context = KimiIntegration.discover() else { throw KimiIntegrationError(code: "installation-unconfirmed") }
        return try KimiIntegration.inspect(context)
    }, kimiScanInterval: TimeInterval = 15,
       discoverHermesContext: @escaping () -> HermesIntegration.Context? = { HermesIntegration.discover() },
       inspectHermesProfiles: @escaping (HermesIntegration.Context) throws -> [HermesProfile] = { try HermesIntegration.profiles($0) },
       prepareHermesProfile: @escaping (HermesProfile, HermesIntegration.Context) throws -> Void = { try HermesIntegration.prepare($0, context: $1) },
       hermesScanInterval: TimeInterval = 15,
       enableCodexCloud: Bool = false, codexCloudDefaults: UserDefaults = .standard, codexCloudInterval: TimeInterval = 30, makeCodexCloudClient: @escaping () -> CodexCloudClient? = { CodexCloudClient.discover().map { CodexCloudClient(executable: $0) } },
       updateDefaults: UserDefaults = .standard, updateClock: ReleaseRetryClock? = nil,
       updateFileStore: ReleaseScheduleFileStore? = nil,
       makeReleaseRequest: @escaping ReleaseRequestFactory = { ReleaseRequest(completion: $0) }) {
        self.codexReader = codexReader
        self.claudeReader = claudeReader
        self.claudeLoopProfile = claudeLoopProfile
        self.externalProvidersEnabled = enableExternalProviders && previewTasks == nil
        var connections = additionalExternalConnections.filter { [.kimi, .deepseek, .hermes].contains($0.key) }
        connections[.opencode] = openCodeConnection
        self.externalConnections = connections
        self.makeExternalRuntime = makeExternalRuntime
        self.inspectKimiConnection = inspectKimiConnection
        self.kimiScanInterval = max(0.1, kimiScanInterval)
        self.discoverHermesContext = discoverHermesContext
        self.inspectHermesProfiles = inspectHermesProfiles
        self.prepareHermesProfile = prepareHermesProfile
        self.hermesScanInterval = max(0.1, hermesScanInterval)
        self.codexCloudAllowed = enableCodexCloud && previewTasks == nil
        self.codexCloudDefaults = codexCloudDefaults
        self.makeCodexCloudClient = makeCodexCloudClient
        self.codexCloudInterval = codexCloudInterval
        self.codexCloudEnabled = enableCodexCloud && previewTasks == nil && codexCloudDefaults.bool(forKey: "codexCloudEnabled")
        self.claudeRetentionWorker = enableClaudeRetention && previewTasks == nil ? ClaudeRetentionWorker() : nil
        let checksEnabled = enableUpdateChecks && previewTasks == nil
        self.diagnosticWorker = previewTasks == nil ? DiagnosticWorker(journal: journal ?? DiagnosticJournal()) : nil
        if checksEnabled {
            let schedule = ReleaseRetrySchedule(defaults: updateDefaults, clock: updateClock ?? .system(),
                                                fileStore: updateFileStore ?? ReleaseScheduleFileStore(directory: AppPaths.supportDirectory))
            self.updateCoordinator = ReleaseUpdateCoordinator(schedule: schedule, makeRequest: makeReleaseRequest) { [weak self] update in
                self?.acceptReleaseUpdate(update)
            }
        }
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

    @discardableResult
    func acceptReleaseData(_ data: Data) -> Bool {
        let result = ReleaseSelector.inspect(data: data, currentVersion: AppVersion.current)
        acceptReleaseUpdate(result.update)
        return result.valid
    }

    func acceptReleaseUpdate(_ update: AvailableUpdate?) {
        if let update { availableUpdate = update }
    }

    func checkForUpdates() {
        updateCoordinator?.check()
    }

    func setPreviewUpdate() {
        availableUpdate = AvailableUpdate(version: "0.4.0-alpha", url: URL(string: "https://github.com/trueakaru-stack/ai-task-monitor/releases/download/v0.4.0-alpha/app.dmg")!)
    }

    func setPreviewDeepSeekProfiles(desktop: Bool = false) {
        deepSeekInstallationAvailable = true
        deepSeekProfiles = [DeepSeekProfile(name: "Profile One", state: "disconnected", scope: nil, error: nil),
                            DeepSeekProfile(name: "Profile Two", state: "connected", scope: String(repeating: "b", count: 32), error: nil),
                            DeepSeekProfile(name: "desktop", state: "error", scope: nil, error: "unsupported-desktop")]
        selectedDeepSeekProfile = desktop ? "desktop" : "Profile Two"
    }

    func setPreviewHermesProfile(_ state: String) {
        if state == "unavailable" {
            hermesInstallationAvailable = false
            hermesScanError = "installation-unconfirmed"
            hermesProfiles = []
            selectedHermesProfile = ""
            return
        }
        hermesInstallationAvailable = true
        let root = URL(fileURLWithPath: "/Users/example/.hermes", isDirectory: true)
        hermesContext = HermesIntegration.Context(python: root.appendingPathComponent("python3"), home: root,
                                                   project: root.appendingPathComponent("hermes-agent"), assets: root)
        let prepared = state == "prepared" || state == "enabled"
        hermesProfiles = [HermesProfile(id: "root", name: "default", state: prepared ? "prepared" : state,
                                        scope: prepared ? String(repeating: "a", count: 32) : nil,
                                        error: state == "error" ? "profile-unavailable" : nil,
                                        enabled: prepared ? state == "enabled" : nil)]
        selectedHermesProfile = "root"
    }

    static func preview(unavailableSources: [TaskProvider] = [], planUnconfirmed: Bool = false) -> TaskStore {
        let store = TaskStore(previewTasks: [
            MonitoredTask(
                id: "codex-preview", provider: .codex,
                title: tr("Создать индикатор прогресса задач", "Create a task progress indicator"),
                activity: tr("Проверяю нативную сборку и формирую установочный образ", "Checking the native build and preparing the installer"),
                isActive: true, progress: 50, progressKind: .exact,
                steps: [
                    TaskStep(title: tr("Собрать модель активных задач", "Build the active task model"), status: .done),
                    TaskStep(title: tr("Подключить локальные источники", "Connect local sources"), status: .done),
                    TaskStep(title: tr("Проверить интерфейс macOS", "Check the macOS interface"), status: .done),
                    TaskStep(title: tr("Собрать универсальное приложение", "Build the universal app"), status: .active),
                    TaskStep(title: tr("Опубликовать установочный образ", "Publish the installer image"), status: .pending),
                    TaskStep(title: tr("Проверить установку на чистом Mac", "Test installation on a clean Mac"), status: .pending)
                ], updatedAt: Date()
            ),
            MonitoredTask(
                id: "claude-preview", provider: .claude,
                title: tr("Задача Claude Code", "Claude Code task"),
                activity: tr("Выполняет проверку локальных lifecycle hooks и сохранения событий", "Checking local lifecycle hooks and event storage"),
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
        store.journalTaskNames = [key: tr("Создать индикатор прогресса задач", "Create a task progress indicator")]
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

    func setCodexCloudEnabled(_ enabled: Bool) {
        guard codexCloudAllowed else { return }
        codexCloudDefaults.set(enabled, forKey: "codexCloudEnabled")
        codexCloudGeneration += 1
        codexCloudClient?.cancel()
        codexCloudClient = nil
        previousCodexCloud = []
        codexCloudEnabled = enabled
        codexCloudFailed = false
        codexCloudPartial = false
        nextCodexCloudScan = .distantPast
        refresh()
    }

    private func scheduleCodexCloudScan() {
        guard codexCloudAllowed, codexCloudEnabled, codexCloudClient == nil, Date() >= nextCodexCloudScan else { return }
        guard let client = makeCodexCloudClient() else {
            codexCloudFailed = true
            nextCodexCloudScan = Date().addingTimeInterval(codexCloudInterval)
            return
        }
        codexCloudClient = client
        let generation = codexCloudGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try client.list() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.codexCloudEnabled, self.codexCloudGeneration == generation,
                      self.codexCloudClient === client else { return }
                self.codexCloudClient = nil
                self.nextCodexCloudScan = Date().addingTimeInterval(self.codexCloudInterval)
                switch result {
                case .success(let snapshot):
                    let seen = Set(snapshot.tasks.map(\.id))
                    let retained = snapshot.complete ? [] : self.previousCodexCloud.filter { !seen.contains($0.id) }
                    self.previousCodexCloud = snapshot.tasks.filter { $0.status != .terminal } + retained
                    self.codexCloudFailed = false
                    self.codexCloudPartial = !snapshot.complete
                case .failure:
                    self.codexCloudFailed = true
                }
                self.refresh()
            }
        }
    }

    private var codexCloudTasks: [MonitoredTask] {
        previousCodexCloud.map(Self.codexCloudMonitoredTask)
    }

    static func codexCloudMonitoredTask(_ item: CodexCloudReader.Task) -> MonitoredTask {
        let title = item.title ?? tr("Задача Codex", "Codex task")
        return MonitoredTask(id: item.id, provider: .codex,
                             title: tr("Облако: ", "Cloud: ") + title,
                             activity: tr("Статус не подтверждён", "Status unconfirmed"),
                             isActive: false, progress: nil, progressKind: .none, steps: [],
                             updatedAt: item.updatedAt ?? .distantPast, isUnconfirmed: true, planConfirmed: false)
    }

    func refresh() {
        let previousTasks = tasks
        let previousUnavailable = unavailableSources
        var unavailable: [TaskProvider] = []
        var terminalIDs: Set<String> = []
        var interruptedIDs: Set<String> = []
        var neutralEndedIDs: Set<String> = []
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
                // Drain phase evidence before matching the file snapshot. A
                // record whose frame is still in flight remains unconfirmed.
                syncClaudeLoop(connected: claudeConnected, now: Date())
                if !complete { unavailable.append(.claude) }
                let exists = FileManager.default.fileExists(atPath: claudeReader.eventFile.path)
                if !exists && sawClaudeEvents { throw CocoaError(.fileReadNoSuchFile) }
                if exists {
                    sawClaudeEvents = true
                    let snapshot = try claudeReader.readSnapshot(observedSince: monitoringStartedAt,
                                                                phaseEvidence: claudePhaseEvidence)
                    terminalIDs.formUnion(snapshot.terminalIDs)
                    interruptedIDs.formUnion(snapshot.interruptedIDs)
                    neutralEndedIDs.formUnion(snapshot.neutralEndedIDs)
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: snapshot.tasks,
                                                               terminalIDs: snapshot.terminalIDs.union(snapshot.neutralEndedIDs))
                    if snapshot.sourceUncertain {
                        claudeConnected = false
                        if !unavailable.contains(.claude) { unavailable.append(.claude) }
                    }
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
        // A retained card after a read error or lost source must not retain a
        // confirmed plan internally even when the UI also hides stale state.
        previousClaude = Self.clearUnconfirmedClaudePlans(previousClaude)
        if externalProvidersEnabled { scheduleKimiScan(); scheduleDeepSeekScan(); scheduleHermesScan(); refreshExternalProviders(unavailable: &unavailable) }
        scheduleCodexCloudScan()
        unavailableSources = unavailable
        var combined = (previousCodex + previousClaude + previousExternal + codexCloudTasks)
            .filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
            .sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        let phaseChangedAfterSnapshot = syncClaudeLoop(connected: claudeConnected, now: now)
        if phaseChangedAfterSnapshot || claudePhaseEvidence.poisoned {
            previousClaude = Self.clearClaudePlanConfirmations(previousClaude)
            combined = Self.clearClaudePlanConfirmations(combined)
        }
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
        for id in terminalIDs.union(neutralEndedIDs) {
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
            do {
                let state: ExternalProviderConnectionState
                if let connection = externalConnections[provider] { state = try connection() }
                else if provider == .deepseek { state = try deepSeekConnectionState() }
                else if provider == .kimi { state = try kimiConnectionState() }
                else if provider == .hermes { state = try hermesConnectionState() }
                else { continue }
                switch state {
                case .connected:
                    seenExternalConnections.insert(provider)
                    allowed.insert(provider)
                case .connectedDegraded:
                    seenExternalConnections.insert(provider)
                    allowed.insert(provider)
                    unavailable.append(provider)
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
            var scopes: [TaskProvider: Set<String>] = [:]
            var uncertainScopes: [TaskProvider: Set<String>] = [:]
            if allowed.contains(.deepseek), externalConnections[.deepseek] == nil {
                scopes[.deepseek] = deepSeekAllowedScopes
                uncertainScopes[.deepseek] = deepSeekUncertainScopes
            }
            if allowed.contains(.kimi), externalConnections[.kimi] == nil, let scope = kimiScope {
                scopes[.kimi] = [scope]
            }
            if allowed.contains(.hermes), externalConnections[.hermes] == nil {
                scopes[.hermes] = hermesAllowedScopes
                uncertainScopes[.hermes] = hermesUncertainScopes
            }
            previousExternal = (externalRuntime?.snapshot(allowed: allowed, profileScopes: scopes, uncertainScopes: uncertainScopes) ?? []) + retained
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

    @discardableResult
    private func syncClaudeLoop(connected: Bool, now: Date) -> Bool {
        guard connected else {
            let changed = claudeLoopChannel != nil
            if changed { claudePhaseEvidence.invalidate() }
            claudeLoopChannel?.stop()
            claudeLoopChannel = nil
            claudeLoopDetectors.removeAll()
            claudeLoopError = ""
            return changed
        }
        if claudeLoopChannel == nil {
            do {
                let channel = try ClaudeLoopChannel(profile: claudeLoopProfile ?? AppPaths.supportDirectory)
                claudeLoopChannel = channel
                if let key = channel.phaseKey() { claudePhaseEvidence.start(key: key) }
                else { claudePhaseEvidence.invalidate() }
            }
            catch {
                claudePhaseEvidence.invalidate()
                claudeLoopDetectors.removeAll()
                if diagnosticWorker != nil {
                    claudeLoopError = tr("Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение.", "Claude Code loop warnings are unavailable. Check access or restart the app.")
                }
                return true
            }
        }
        guard let channel = claudeLoopChannel else { return true }
        claudeLoopError = ""
        let batch = channel.drain()
        var phaseChanged = batch.gap
        if batch.gap { claudeLoopDetectors.removeAll(); claudePhaseEvidence.invalidate() }
        if diagnosticWorker == nil { claudeLoopDetectors.removeAll() }
        for event in batch.events {
            if event.kind == .phase {
                phaseChanged = true
                if let fingerprint = event.fingerprint {
                    claudePhaseEvidence.observe(session: event.sessionID, toolID: event.toolID, fingerprint: fingerprint)
                } else { claudePhaseEvidence.invalidate() }
                continue
            }
            guard diagnosticWorker != nil else { continue }
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
        return phaseChanged
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
