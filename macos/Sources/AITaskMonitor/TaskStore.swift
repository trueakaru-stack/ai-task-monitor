import Combine
import Foundation

private struct CodexBackgroundRead {
    let homeExists: Bool
    let homeStable: Bool
    let homeObservation: CodexHomeObservation
    let firstResult: Result<CodexTaskSnapshot, Error>
    let result: Result<CodexTaskSnapshot, Error>
    let revalidated: Bool
    let agrees: Bool
    let selectionGeneration: UInt64
    let language: AppLanguage
    let startedAtUptime: TimeInterval
    let finishedAtUptime: TimeInterval
}

private struct ClaudeBackgroundRead {
    let result: ClaudeSourceRead
    let selectionGeneration: UInt64
}

private struct CodexHomeObservation: Equatable {
    let exists: Bool
    let path: String?
    let device: UInt64?
    let inode: UInt64?
    let created: Date?

    var hasIdentity: Bool { !exists || (path != nil && device != nil && inode != nil) }

    static func read(_ home: URL) -> CodexHomeObservation {
        let manager = FileManager.default
        guard manager.fileExists(atPath: home.path) else {
            return CodexHomeObservation(exists: false, path: nil, device: nil, inode: nil, created: nil)
        }
        let resolved = home.resolvingSymlinksInPath().standardizedFileURL
        guard let attrs = try? manager.attributesOfItem(atPath: resolved.path),
              attrs[.type] as? FileAttributeType == .typeDirectory,
              let device = (attrs[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return CodexHomeObservation(exists: true, path: nil, device: nil, inode: nil, created: nil)
        }
        return CodexHomeObservation(exists: true, path: resolved.path, device: device, inode: inode,
                                    created: attrs[.creationDate] as? Date)
    }
}

// A discarded ending must not be converted back into a confirmed running
// turn just because the stateful reader no longer emits that ending.
struct CodexTerminalGuard {
    static let maximumPendingIDs = 1_024
    static let maximumTurnsPerID = 8
    static let maximumIdentityBytes = 256

    struct Pending: Hashable {
        let file: CodexFileIdentity?
        let startKey: String
    }

    struct Reconciled {
        let tasks: [MonitoredTask]
        let terminalIDs: Set<String>
        let isPartial: Bool
    }

    private(set) var pending: [String: Set<Pending>] = [:]
    private(set) var overflowed = false

    mutating func remember(_ ids: Set<String>, previous: [MonitoredTask]) {
        guard !overflowed else { return }
        for task in previous where ids.contains(task.id) {
            guard task.id.utf8.prefix(Self.maximumIdentityBytes + 1).count <= Self.maximumIdentityBytes,
                  task.startKey.utf8.prefix(Self.maximumIdentityBytes + 1).count <= Self.maximumIdentityBytes else {
                overflowed = true
                return
            }
            let candidate = Pending(file: task.lastActivityFileIdentity, startKey: task.startKey)
            if pending[task.id] == nil && pending.count >= Self.maximumPendingIDs {
                overflowed = true
                return
            }
            if let existing = pending[task.id], !existing.contains(candidate), existing.count >= Self.maximumTurnsPerID {
                overflowed = true
                return
            }
            pending[task.id, default: []].insert(candidate)
        }
    }

    mutating func reconcile(_ snapshot: CodexTaskSnapshot, previous: [MonitoredTask]) -> Reconciled {
        if overflowed {
            return Reconciled(tasks: snapshot.tasks.map {
                TaskSnapshotMerger.merge(previous: [$0], current: [], terminalIDs: [])[0]
            }, terminalIDs: [], isPartial: true)
        }
        let previousByID = Dictionary(grouping: previous, by: \.id)
        var acceptedTerminals = snapshot.terminalIDs
        for id in snapshot.terminalIDs {
            let old = previousByID[id] ?? []
            if old.isEmpty && pending[id] == nil { continue }
            let evidence = snapshot.terminalEvidence[id]
            let samePrevious = old.count == 1 && old[0].lastActivityFileIdentity != nil &&
                !old[0].startKey.isEmpty && evidence?.file == old[0].lastActivityFileIdentity &&
                evidence?.startKey == old[0].startKey
            let samePending = (pending[id] ?? []).allSatisfy {
                $0.file != nil && !$0.startKey.isEmpty && evidence?.file == $0.file && evidence?.startKey == $0.startKey
            }
            if samePrevious && samePending {
                pending.removeValue(forKey: id)
            } else {
                acceptedTerminals.remove(id)
                remember([id], previous: old)
            }
        }

        if overflowed {
            return Reconciled(tasks: snapshot.tasks.map {
                TaskSnapshotMerger.merge(previous: [$0], current: [], terminalIDs: [])[0]
            }, terminalIDs: [], isPartial: true)
        }

        // A different start key on the same inode may come from rewritten
        // history. It does not establish that this start followed the ending.
        let safeTasks = snapshot.tasks.map { task in
            guard pending[task.id] != nil else { return task }
            return TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        }
        return Reconciled(tasks: safeTasks, terminalIDs: acceptedTerminals,
                          isPartial: !pending.isEmpty || acceptedTerminals != snapshot.terminalIDs)
    }
}

@MainActor
final class TaskStore: ObservableObject {
    private static let sourcePollInterval: TimeInterval = 2
    // Keep titles already displayed when an uncertain replacement snapshot
    // lacks them. This is in-memory only and does not persist private text.
    static func preserveUncertainClaudeTitles(previous: [MonitoredTask], current: [MonitoredTask], affected: Set<String>? = nil) -> (tasks: [MonitoredTask], overflow: Bool) {
        let old = Dictionary(previous.filter { $0.provider == .claude }.map { ($0.id, $0) },
                             uniquingKeysWith: { first, _ in first })
        var overflow = false
        let tasks = current.map { task in
            guard task.provider == .claude, affected == nil || affected!.contains(task.id),
                  (!task.planConfirmed || task.isUnconfirmed), let prior = old[task.id] else { return task }
            let currentTitles = Set(task.steps.map(\.title))
            var kept: [TaskStep] = []
            var seen = currentTitles
            for step in prior.steps where seen.insert(step.title).inserted {
                guard kept.count < 4096 else { overflow = true; continue }
                kept.append(TaskStep(id: "~aitm-history-\(kept.count)", title: step.title, status: .pending))
            }
            var merged = task
            merged.steps = kept + task.steps
            return merged
        }
        return (tasks, overflow)
    }

    static func clearClaudePlanConfirmations(_ items: [MonitoredTask], affected: Set<String>? = nil) -> [MonitoredTask] {
        items.map { item in
            guard item.provider == .claude, affected == nil || affected!.contains(item.id) else { return item }
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

    private var compactSnapshotGeneration: UInt64 = 0
    private var compactManualSelectionGeneration: UInt64 = 0
    @Published private(set) var tasks: [MonitoredTask] = [] {
        didSet {
            if CodexTaskGrouping.compactSnapshotChanged(oldValue, tasks, confirmedChildren: compactCodexChildren) {
                compactSnapshotGeneration &+= 1
            }
        }
    }
    @Published var selectedProvider: ProviderFilter = .all
    @Published var showsSettings = false
    @Published var showsAbout = false
    @Published var isCompact = false
    @Published var compactIndex = 0
    @Published private(set) var expandedCodexGroupIDs: Set<String> = []
    @Published var sourceMessage = ""
    @Published private(set) var openCodeMessage = ""
    @Published private(set) var openCodeSetupInProgress = false
    @Published private(set) var externalV2Failed = false
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
    @Published private(set) var codexPartiallyUnavailable = false
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
    private let codexReadQueue = DispatchQueue(label: "ai-task-monitor.codex-source", qos: .utility)
    private var codexReadInFlight = false
    private var codexReadPending = false
    private var codexReadDelayed = false
    private var codexReadStartedAt: TimeInterval?
    private var codexReadGeneration: UInt64 = 0
    private var codexHasCompletedRead = false
    private var codexTerminalGuard = CodexTerminalGuard()
    private var codexAgentRetention = CodexAgentRetention()
    private var codexAgentGroups: [CodexAgentRetention.Group] = []
    private var codexAgentRootBindings: [String: UUID] = [:]
    private var codexAgentFallbackRoots: [String: MonitoredTask] = [:]
    private var codexAgentCardBindings: [String: CodexRetainedAgentCard] = [:] {
        didSet { if oldValue != codexAgentCardBindings { compactSnapshotGeneration &+= 1 } }
    }
    private var lastCodexHome: CodexHomeObservation?
    private var codexSourceUnavailable = false
    private var codexSourcePartial = false
    private let claudeSourceWorker: ClaudeSourceWorker
    private let updateClaudeConnection: (Bool) throws -> Void
    private var claudeReadInFlight = false
    private var claudeReadPending = false
    private var claudeReadDelayed = false
    private var claudeReadStartedAt: TimeInterval?
    private var claudeReadGeneration: UInt64 = 0
    private var claudeHasCompletedRead = false
    private var claudeSourceUnavailable = false
    private let diagnosticWorker: DiagnosticWorker?
    private let claudeRetentionWorker: ClaudeRetentionWorker?
    private let externalProvidersEnabled: Bool
    private let externalV2Enabled: Bool
    private let externalConnections: [TaskProvider: () throws -> ExternalProviderConnectionState]
    private let makeExternalRuntime: () throws -> ExternalProviderRuntime
    private let makeExternalV2Runtime: () throws -> ExternalProviderV2Runtime
    private let discoverDeepSeekContext: () -> DeepSeekIntegration.Context?
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
    private var diagnosticTasks: [MonitoredTask] = []
    private var codexParentEvidence: [String: String] = [:]
    private var codexParentConflicts: Set<String> = []
    private var codexParentTitles: [String: String] = [:]
    private var codexParentsForDisplay: [String: String] = [:]
    private var codexRootsForDisplay: Set<String> = []
    private var confirmedCodexChildrenForCompact: [String: CodexFileIdentity] = [:] {
        didSet { if oldValue != confirmedCodexChildrenForCompact { compactSnapshotGeneration &+= 1 } }
    }

    private var compactCodexChildren: [String: CodexFileIdentity] {
        var result = confirmedCodexChildrenForCompact
        for (id, binding) in codexAgentCardBindings {
            if let other = result[id], other != binding.file { result.removeValue(forKey: id) }
            else { result[id] = binding.file }
        }
        return result
    }
    private var previousClaude: [MonitoredTask] = []
    private var claudeRetainedTitlesOverflow = false
    private var previousExternal: [MonitoredTask] = []
    private let maximumExternalCards = 512
    // Reconnection does not prove that a rejected event's task has ended.
    private var externalCapacityUnattributed: Set<TaskProvider> = []
    private var externalCapacityScopes: [TaskProvider: Set<String>] = [:]
    private var partialExternalSources: Set<TaskProvider> = []
    private let maximumExternalScopeWarnings = 256
    private var externalRuntime: ExternalProviderRuntime?
    private var externalV2Runtime: ExternalProviderV2Runtime?
    private var parkedExternalProviderState: ExternalProviderStateStore?
    private var seenExternalConnections: Set<TaskProvider> = []
    private var kimiScope: String?
    private var kimiSeenScope: String?
    private var kimiRetiredScopes: Set<String> = []
    private var kimiScanInProgress = false
    private var nextKimiScan = Date.distantPast
    private var deepSeekContext: DeepSeekIntegration.Context?
    private var deepSeekHistory = ProviderScopeHistory()
    private var deepSeekScanError: String?
    private var nextDeepSeekScan = Date.distantPast
    private var hermesContext: HermesIntegration.Context?
    private var hermesHistory = ProviderScopeHistory()
    private var hermesScanError: String?
    private var nextHermesScan = Date.distantPast
    private var taskFocus = TaskFocusTracker()
    private var sawCodexHome = false
    private var nextJournalMaintenance = Date.distantPast
    private var loopDetectors: [String: LoopDetector] = [:]
    private var claudeLoopDetectors: [String: ClaudeLoopTracker] = [:]
    private var timer: Timer?

    private func codexGroupKey(_ id: String) -> String {
        let lower = id.lowercased()
        for prefix in ["codex-group:", "codex-retained:"] where lower.hasPrefix(prefix) {
            return String(lower.dropFirst(prefix.count))
        }
        return lower
    }

    func isCodexGroupExpanded(_ id: String) -> Bool {
        expandedCodexGroupIDs.contains(codexGroupKey(id))
    }

    func toggleCodexGroup(_ id: String) {
        let key = codexGroupKey(id)
        if expandedCodexGroupIDs.contains(key) {
            expandedCodexGroupIDs.remove(key)
        } else {
            if expandedCodexGroupIDs.count >= 512, let old = expandedCodexGroupIDs.sorted().first {
                expandedCodexGroupIDs.remove(old)
            }
            expandedCodexGroupIDs.insert(key)
        }
    }

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

    var openCodeRestartAvailable: Bool {
        externalV2Runtime?.canAcknowledge(ExternalProviderV2Scope(provider: "opencode", scope: "global")) == true
    }

    var deepSeekRestartAvailable: Bool {
        guard deepSeekScanError == nil, let profile = deepSeekSelectedProfile, profile.state == "connected",
              let scope = profile.scope, deepSeekAllowedScopes.contains(scope),
              !deepSeekHistory.ambiguous(deepSeekProfiles).contains(scope) else { return false }
        return externalV2Runtime?.canAcknowledge(ExternalProviderV2Scope(provider: "deepseek", scope: scope)) == true
    }

    func acknowledgeOpenCodeRestart() {
        guard openCodeRestartAvailable,
              externalV2Runtime?.acknowledge(ExternalProviderV2Scope(provider: "opencode", scope: "global")) == true else {
            openCodeMessage = tr("Не удалось отметить перезапуск. Статусы остаются неподтверждёнными.", "Could not record the restart. Statuses remain unconfirmed.")
            return
        }
        openCodeMessage = tr("Перезапуск отмечен. Статусы OpenCode пока не подтверждены.", "Restart recorded. OpenCode statuses remain unconfirmed.")
        refresh()
    }

    func acknowledgeDeepSeekRestart() {
        guard deepSeekRestartAvailable, let scope = deepSeekSelectedProfile?.scope,
              externalV2Runtime?.acknowledge(ExternalProviderV2Scope(provider: "deepseek", scope: scope)) == true else {
            deepSeekMessage = tr("Не удалось отметить перезапуск. Статусы остаются неподтверждёнными.", "Could not record the restart. Statuses remain unconfirmed.")
            return
        }
        deepSeekMessage = tr("Перезапуск выбранного профиля отмечен.", "Restart recorded for the selected profile.")
        refresh()
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
                    if !connect {
                        self.deepSeekHistory.markDisconnected(profile)
                        self.deepSeekProfiles = self.deepSeekProfiles.map { item in
                            guard Data(item.name.utf8) == Data(profile.utf8) else { return item }
                            return DeepSeekProfile(name: item.name, state: "disconnected", scope: nil, error: nil)
                        }
                    }
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
                    if connection.state == "connected" {
                        // Retain only scopes with an already visible card. A
                        // replacement scope does not prove that task finished.
                        let visible = Set(self.previousExternal.compactMap { task in
                            task.provider == .kimi ? Self.externalScope(task) : nil
                        })
                        self.kimiRetiredScopes.formIntersection(visible)
                        if self.kimiState == "connected", let old = self.kimiScope,
                           old != connection.scope, visible.contains(old) {
                            self.kimiRetiredScopes.insert(old)
                        }
                        if let current = connection.scope { self.kimiRetiredScopes.remove(current) }
                    } else {
                        self.kimiRetiredScopes.removeAll()
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
        guard kimiScanned && kimiState == "connected" else { return .disconnected }
        return kimiRetiredScopes.isEmpty ? .connected : .connectedDegraded
    }

    private func scheduleDeepSeekScan() {
        guard externalProvidersEnabled, !deepSeekSetupInProgress, !deepSeekScanInProgress,
              Date() >= nextDeepSeekScan else { return }
        deepSeekScanInProgress = true
        let discover = discoverDeepSeekContext
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let context = discover()
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
                    guard self.deepSeekHistory.update(profiles) else {
                        self.deepSeekHistory.markInvalidRoster()
                        self.deepSeekScanError = "invalid-response"
                        self.refresh()
                        return
                    }
                    self.deepSeekScanError = nil
                    self.deepSeekProfiles = profiles
                    if !profiles.contains(where: { $0.name == self.selectedDeepSeekProfile }) { self.selectedDeepSeekProfile = "" }
                case .failure(let error):
                    let code = (error as? DeepSeekIntegrationError)?.code ?? "operation-failed"
                    if code == "invalid-response" { self.deepSeekHistory.markInvalidRoster() }
                    else { self.deepSeekHistory.markScanFailed() }
                    self.deepSeekScanError = code
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

    static func ambiguousDeepSeekScopes(_ profiles: [DeepSeekProfile], seenScopes: [String: String] = [:]) -> Set<String> {
        var seen: Set<String> = [], ambiguous: Set<String> = []
        for profile in profiles where profile.state == "connected" {
            guard let scope = profile.scope, DeepSeekIntegration.validScope(scope) else { continue }
            if !seen.insert(scope).inserted { ambiguous.insert(scope) }
        }
        for (name, scope) in seenScopes where DeepSeekIntegration.validScope(scope) {
            let matches = profiles.filter { $0.name == name }
            if matches.count != 1 || matches[0].state != "connected" || matches[0].scope != scope {
                if !seen.insert(scope).inserted { ambiguous.insert(scope) }
            }
        }
        return ambiguous
    }

    private var deepSeekAllowedScopes: Set<String> {
        deepSeekHistory.allowed(deepSeekProfiles, scanFailed: deepSeekScanError != nil)
    }

    private var deepSeekUncertainScopes: Set<String> {
        // A structurally invalid roster may conceal conflicting ownership.
        if deepSeekScanError == "invalid-response" { return [] }
        return deepSeekHistory.uncertain(deepSeekProfiles, scanFailed: deepSeekScanError != nil)
    }

    private var deepSeekDisabledScopes: Set<String> {
        Set(deepSeekHistory.disabled.compactMap { deepSeekHistory.seen[$0] })
    }

    private func deepSeekConnectionState() throws -> ExternalProviderConnectionState {
        if deepSeekScanError != nil {
            if deepSeekHistory.seen.isEmpty { return .disconnected }
            throw DeepSeekIntegrationError(code: "operation-failed")
        }
        if !deepSeekAllowedScopes.isEmpty { return deepSeekUncertainScopes.isEmpty ? .connected : .connectedDegraded }
        if deepSeekHistory.historyLost && deepSeekProfiles.contains(where: { ["partial", "error"].contains($0.state) }) {
            return .partial
        }
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
                    guard self.hermesHistory.update(Self.hermesHistoryProfiles(profiles)) else {
                        self.hermesHistory.markInvalidRoster()
                        self.hermesScanError = "invalid-response"
                        self.refresh()
                        return
                    }
                    self.hermesScanError = nil
                    self.hermesProfiles = profiles
                    if !profiles.contains(where: { $0.id == self.selectedHermesProfile }) { self.selectedHermesProfile = "" }
                case .success:
                    self.hermesHistory.markInvalidRoster()
                    self.hermesScanError = "invalid-response"
                case .failure(let error):
                    let code = (error as? HermesIntegrationError)?.code ?? "operation-failed"
                    if code == "invalid-response" { self.hermesHistory.markInvalidRoster() }
                    else { self.hermesHistory.markScanFailed() }
                    self.hermesScanError = code
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
    private static func hermesHistoryProfiles(_ profiles: [HermesProfile]) -> [DeepSeekProfile] {
        profiles.map { profile in
            let connected = profile.state == "prepared" && profile.enabled == true
            let state = connected ? "connected" : (profile.state == "error" ? "error" : "disconnected")
            let evidence = profile.state == "prepared" ? profile.scope : nil
            return DeepSeekProfile(name: profile.id, state: state, scope: evidence, error: profile.error)
        }
    }
    private var hermesAllowedScopes: Set<String> {
        hermesHistory.allowed(Self.hermesHistoryProfiles(hermesProfiles), scanFailed: hermesScanError != nil)
    }
    private var hermesUncertainScopes: Set<String> {
        if hermesScanError == "invalid-response" { return [] }
        return hermesHistory.uncertain(Self.hermesHistoryProfiles(hermesProfiles), scanFailed: hermesScanError != nil)
    }
    private func hermesConnectionState() throws -> ExternalProviderConnectionState {
        if hermesScanError != nil {
            if hermesHistory.seen.isEmpty { return .disconnected }
            throw HermesIntegrationError(code: "operation-failed")
        }
        if !hermesAllowedScopes.isEmpty { return hermesUncertainScopes.isEmpty ? .connected : .connectedDegraded }
        return hermesUncertainScopes.isEmpty ? .disconnected : .partial
    }

    init(codexReader: CodexTaskReader = CodexTaskReader(), claudeReader: ClaudeTaskReader = ClaudeTaskReader(), previewTasks: [MonitoredTask]? = nil, journal: DiagnosticJournal? = nil, claudeLoopProfile: URL? = nil, inspectClaudeConnection: (() throws -> ClaudeIntegration.ConnectionState)? = nil, updateClaudeConnection: @escaping (Bool) throws -> Void = { try ClaudeIntegration.setConnected($0) }, enableUpdateChecks: Bool = false, enableClaudeRetention: Bool = false, enableExternalProviders: Bool = false, openCodeConnection: @escaping () throws -> OpenCodeIntegration.State = { try OpenCodeIntegration.state() }, additionalExternalConnections: [TaskProvider: () throws -> ExternalProviderConnectionState] = [:], makeExternalRuntime: @escaping () throws -> ExternalProviderRuntime = { try ExternalProviderRuntime(channel: ExternalProviderChannel()) }, makeExternalV2Runtime: @escaping () throws -> ExternalProviderV2Runtime = { try ExternalProviderV2Runtime() }, discoverDeepSeekContext: @escaping () -> DeepSeekIntegration.Context? = { DeepSeekIntegration.discover() }, inspectKimiConnection: @escaping () throws -> KimiConnection = {
        guard let context = KimiIntegration.discover() else { throw KimiIntegrationError(code: "installation-unconfirmed") }
        return try KimiIntegration.inspect(context)
    }, kimiScanInterval: TimeInterval = 15,
       discoverHermesContext: @escaping () -> HermesIntegration.Context? = { HermesIntegration.discover() },
       inspectHermesProfiles: @escaping (HermesIntegration.Context) throws -> [HermesProfile] = { try HermesIntegration.profiles($0) },
       prepareHermesProfile: @escaping (HermesProfile, HermesIntegration.Context) throws -> Void = { try HermesIntegration.prepare($0, context: $1) },
       hermesScanInterval: TimeInterval = 15, enableExternalV2: Bool = false,
       enableCodexCloud: Bool = false, codexCloudDefaults: UserDefaults = .standard, codexCloudInterval: TimeInterval = 30, makeCodexCloudClient: @escaping () -> CodexCloudClient? = { CodexCloudClient.discover().map { CodexCloudClient(executable: $0) } },
       updateDefaults: UserDefaults = .standard, updateClock: ReleaseRetryClock? = nil,
       updateFileStore: ReleaseScheduleFileStore? = nil,
       makeReleaseRequest: @escaping ReleaseRequestFactory = { ReleaseRequest(completion: $0) }) {
        self.codexReader = codexReader
        let needsClaudeChannel = !claudeReader.usesExplicitFile || claudeLoopProfile != nil
        let sourceProfile = needsClaudeChannel ? (claudeLoopProfile ?? AppPaths.supportDirectory) : nil
        let usesExplicitClaudeFile = claudeReader.usesExplicitFile
        self.updateClaudeConnection = updateClaudeConnection
        self.claudeSourceWorker = ClaudeSourceWorker(reader: claudeReader, channelProfile: sourceProfile,
                                                     requiresChannel: needsClaudeChannel, connection: {
            if let inspectClaudeConnection { return try inspectClaudeConnection() }
            if usesExplicitClaudeFile { return .connected }
            return try ClaudeIntegration.connectionState()
        })
        self.externalProvidersEnabled = enableExternalProviders && previewTasks == nil
        self.externalV2Enabled = enableExternalV2 && enableExternalProviders && previewTasks == nil
        var connections = additionalExternalConnections.filter { [.kimi, .deepseek, .hermes].contains($0.key) }
        connections[.opencode] = openCodeConnection
        self.externalConnections = connections
        self.makeExternalRuntime = makeExternalRuntime
        self.makeExternalV2Runtime = makeExternalV2Runtime
        self.discoverDeepSeekContext = discoverDeepSeekContext
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.sourcePollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodicRefresh(); self?.checkForUpdates(); self?.maintainClaudeRetention() }
        }
    }

    deinit {
        claudeRetentionWorker?.invalidate()
        timer?.invalidate()
        claudeSourceWorker.shutdownForOwnerDeinit()
        externalRuntime?.stop()
        externalV2Runtime?.stop()
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

    func setPreviewCodexPartial() {
        codexPartiallyUnavailable = true
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
    private var compactTaskIndices: [Int] {
        CodexTaskGrouping.compactVisibleIndices(tasks, confirmedChildren: compactCodexChildren)
    }
    var compactTasks: [MonitoredTask] { compactTaskIndices.map { tasks[$0] } }
    var compactDots: [CompactTaskDot] {
        let visible = Array(compactTasks.prefix(3))
        let counts = Dictionary(grouping: visible, by: { $0.compactSelectionKey }).mapValues(\.count)
        var occurrences: [CompactTaskSelectionKey: Int] = [:]
        return visible.enumerated().map { index, task in
            let key = task.compactSelectionKey
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return CompactTaskDot(task: task, occurrence: occurrence, visibleIndex: index,
                                  generation: (counts[key] ?? 0) > 1 ? compactSnapshotGeneration : nil)
        }
    }
    var compactSelectedIndex: Int {
        guard let index = compactTaskIndices.firstIndex(of: compactIndex), index < 3 else { return 0 }
        return index
    }
    var compactProviders: Set<TaskProvider> { Set(compactTasks.map(\.provider)) }

    func selectCompactTask(dot: CompactTaskDot) {
        let visible = Array(compactTaskIndices.prefix(3))
        if let generation = dot.generation {
            guard generation == compactSnapshotGeneration,
                  visible.indices.contains(dot.visibleIndex),
                  tasks[visible[dot.visibleIndex]].compactSelectionKey == dot.task.compactSelectionKey else { return }
            compactIndex = visible[dot.visibleIndex]
            compactManualSelectionGeneration &+= 1
            return
        }
        let matches = visible.filter { tasks[$0].compactSelectionKey == dot.task.compactSelectionKey }
        guard matches.count == 1, let index = matches.first else { return }
        compactIndex = index
        compactManualSelectionGeneration &+= 1
    }

    var visibleProviderFilters: [ProviderFilter] {
        ProviderFilter.allCases.filter { filter in filter == .all || filter.provider.map { providers.contains($0) } == true }
    }
    var unavailableMessage: String { sourceUnavailableMessage(includeCodexPartial: true) }
    var compactUnavailableMessage: String { sourceUnavailableMessage(includeCodexPartial: false) }

    var compactEmptyMessage: String {
        let warning = compactUnavailableMessage
        if !warning.isEmpty { return warning }
        if (codexReadInFlight && !codexHasCompletedRead) || (claudeReadInFlight && !claudeHasCompletedRead) {
            return tr("Нет отображаемых задач", "No tasks to display")
        }
        if !tasks.isEmpty && compactTasks.isEmpty {
            return tr("Список задач Codex может быть неполным", "The Codex task list may be incomplete")
        }
        if codexPartiallyUnavailable && !unavailableSources.contains(.codex) {
            return tr("Нет отображаемых задач", "No tasks to display")
        }
        return tr("Активных задач нет", "No active tasks")
    }

    var expandedEmptyMessage: String {
        if (codexReadInFlight && !codexHasCompletedRead) || (claudeReadInFlight && !claudeHasCompletedRead) {
            return tr("Нет отображаемых задач", "No tasks to display")
        }
        return tr("Активных задач нет", "No active tasks")
    }

    private func sourceUnavailableMessage(includeCodexPartial: Bool) -> String {
        var messages: [String] = []
        let partial = unavailableSources.filter { partialExternalSources.contains($0) }
        let absent = unavailableSources.filter { !partialExternalSources.contains($0) }
        if !absent.isEmpty {
            messages.append(tr("Нет данных от ", "No data from ") + absent.map(\.displayName).joined(separator: ", "))
        }
        if !partial.isEmpty {
            let sources = partial.map(\.displayName).joined(separator: ", ")
            messages.append(tr("Часть данных ", "Some ") + sources + tr(" недоступна", " data is unavailable"))
        }
        if includeCodexPartial && codexPartiallyUnavailable && !unavailableSources.contains(.codex) {
            messages.append(tr("Часть данных Codex недоступна", "Some Codex data is unavailable"))
        }
        return messages.joined(separator: ". ")
    }
    private func tasks(for filter: ProviderFilter) -> [MonitoredTask] {
        guard let provider = filter.provider else { return tasks }
        return tasks.filter { $0.provider == provider }
    }

    var filteredTasks: [MonitoredTask] { tasks(for: selectedProvider) }

    func count(for filter: ProviderFilter) -> Int { tasks(for: filter).count }

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
        scheduleCodexRead(periodic: false)
        scheduleClaudeRead(periodic: false)
        refreshState(codexRead: nil)
    }

    private func periodicRefresh() {
        scheduleCodexRead(periodic: true)
        scheduleClaudeRead(periodic: true)
        refreshState(codexRead: nil)
    }

    private func scheduleClaudeRead(periodic: Bool = false) {
        if claudeReadInFlight {
            claudeReadPending = true
            if periodic, let start = claudeReadStartedAt,
               ProcessInfo.processInfo.systemUptime - start >= Self.sourcePollInterval,
               !claudeReadDelayed {
                claudeReadDelayed = true
                claudeSourceUnavailable = true
                previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
                previousClaude = Self.clearUnconfirmedClaudePlans(previousClaude)
            }
            return
        }
        claudeReadInFlight = true
        claudeReadDelayed = false
        claudeReadStartedAt = ProcessInfo.processInfo.systemUptime
        claudeReadGeneration &+= 1
        let generation = claudeReadGeneration
        let selectionGeneration = compactManualSelectionGeneration
        let accepted = claudeSourceWorker.tryRead(observedSince: monitoringStartedAt) { [weak self] result in
            guard let self, self.claudeReadGeneration == generation else { return }
            self.claudeReadInFlight = false
            self.claudeReadStartedAt = nil
            self.claudeReadDelayed = false
            let pending = self.claudeReadPending
            self.claudeReadPending = false
            self.refreshState(codexRead: nil, claudeRead: ClaudeBackgroundRead(result: result,
                                                                               selectionGeneration: selectionGeneration))
            let shouldRepeat = pending || self.claudeReadPending
            self.claudeReadPending = false
            if shouldRepeat { self.scheduleClaudeRead() }
        }
        if !accepted {
            claudeReadInFlight = false
            claudeReadStartedAt = nil
            claudeSourceUnavailable = true
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
            previousClaude = Self.clearUnconfirmedClaudePlans(previousClaude)
        }
    }

    // One reader owns its caches on one serial queue. A burst of refresh
    // requests only schedules one more pass after the current read finishes.
    private func scheduleCodexRead(periodic: Bool = false) {
        if codexReadInFlight {
            codexReadPending = true
            if periodic, let start = codexReadStartedAt,
               ProcessInfo.processInfo.systemUptime - start >= Self.sourcePollInterval,
               !codexReadDelayed {
                codexReadDelayed = true
                codexSourcePartial = true
                let oldTasks = previousCodex
                previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
                updateCodexAgentRetention(snapshot: nil, previous: oldTasks, replacedIDs: [], sourceUnavailable: true)
            }
            return
        }
        codexReadInFlight = true
        codexReadDelayed = false
        codexReadStartedAt = nil
        codexReadGeneration &+= 1
        let generation = codexReadGeneration
        let reader = codexReader
        let wasSeen = sawCodexHome
        let observedSince = monitoringStartedAt
        let previouslyObserved = Set(previousCodex.map(\.id))
        let selectionGeneration = compactManualSelectionGeneration
        let language = AppLanguage.current
        let pollInterval = Self.sourcePollInterval
        codexReadQueue.async { [weak self] in
            let startedAtUptime = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [weak self] in
                guard let self, self.codexReadInFlight, self.codexReadGeneration == generation else { return }
                self.codexReadStartedAt = startedAtUptime
            }
            let before = CodexHomeObservation.read(reader.codexHome)
            func readSnapshot() -> Result<CodexTaskSnapshot, Error> {
              AppLanguage.withSourceLanguage(language) {
                Result<CodexTaskSnapshot, Error> {
                    if !before.exists && wasSeen { throw CocoaError(.fileReadNoSuchFile) }
                    return try reader.readSnapshot(observedSince: observedSince, previouslyObserved: previouslyObserved)
                }
              }
            }
            let first = readSnapshot()
            var result = first
            var revalidated = false
            var agrees = false
            if case .success(let initial) = first,
               (ProcessInfo.processInfo.systemUptime - startedAtUptime >= pollInterval ||
                !initial.terminalIDs.isDisjoint(with: previouslyObserved)) {
                result = readSnapshot()
                revalidated = true
                if case .success(let later) = result { agrees = initial.agreesWith(later) }
            }
            let after = CodexHomeObservation.read(reader.codexHome)
            let finishedAtUptime = ProcessInfo.processInfo.systemUptime
            let read = CodexBackgroundRead(homeExists: before.exists || after.exists,
                                           homeStable: before.hasIdentity && after.hasIdentity && before == after,
                                           homeObservation: before,
                                           firstResult: first, result: result, revalidated: revalidated, agrees: agrees,
                                           selectionGeneration: selectionGeneration, language: language,
                                           startedAtUptime: startedAtUptime, finishedAtUptime: finishedAtUptime)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.codexReadGeneration == generation else { return }
                self.codexReadInFlight = false
                self.codexReadStartedAt = nil
                let delayed = self.codexReadDelayed
                self.codexReadDelayed = false
                let pending = self.codexReadPending
                self.codexReadPending = false
                self.refreshState(codexRead: read, codexReadWasDelayed: delayed)
                let shouldRepeat = pending || self.codexReadPending
                self.codexReadPending = false
                if shouldRepeat { self.scheduleCodexRead() }
            }
        }
    }

    private func refreshState(codexRead: CodexBackgroundRead?, claudeRead: ClaudeBackgroundRead? = nil,
                              codexReadWasDelayed: Bool = false) {
        let previousTasks = tasks
        let previousCompact = compactTasks
        let previousCompactIndex = previousCompact.isEmpty ? nil : compactSelectedIndex
        let selectedTask = previousCompactIndex.map { previousCompact[$0] }
        let previousUnavailable = unavailableSources
        var unavailable: [TaskProvider] = []
        var terminalIDs: Set<String> = []
        var interruptedIDs: Set<String> = []
        var neutralEndedIDs: Set<String> = []
        var codexToolEvents: [String: [CodexToolEvent]] = [:]
        if let codexRead {
          codexHasCompletedRead = true
          if codexRead.homeExists { sawCodexHome = true }
          if codexRead.homeStable && codexRead.homeObservation.exists {
            if let old = lastCodexHome, old != codexRead.homeObservation {
                codexAgentRetention = CodexAgentRetention()
                codexAgentGroups = []
                codexAgentRootBindings.removeAll()
                codexAgentCardBindings.removeAll()
                codexAgentFallbackRoots.removeAll()
                codexParentEvidence.removeAll()
                codexParentConflicts.removeAll()
                codexParentTitles.removeAll()
                clearCodexDisplayEvidence()
            }
            lastCodexHome = codexRead.homeObservation
          }
          let nowUptime = ProcessInfo.processInfo.systemUptime
          let slow = codexReadWasDelayed || codexRead.finishedAtUptime - codexRead.startedAtUptime >= Self.sourcePollInterval
          let late = nowUptime - codexRead.finishedAtUptime >= Self.sourcePollInterval
          let invalid = !codexRead.homeStable || codexRead.language != AppLanguage.current || late ||
              (codexRead.revalidated && !codexRead.agrees) || (slow && !codexRead.revalidated)
          if invalid {
            let oldTasks = previousCodex
            var replacedIDs: Set<String> = []
            if codexRead.language != AppLanguage.current { codexReadPending = true }
            if case .success(let first) = codexRead.firstResult {
                codexTerminalGuard.remember(first.terminalIDs, previous: previousCodex)
            }
            if case .success(let latest) = codexRead.result {
                codexTerminalGuard.remember(latest.terminalIDs, previous: previousCodex)
                if codexRead.homeStable && codexRead.language == AppLanguage.current {
                    let uncertain = TaskSnapshotMerger.merge(previous: latest.tasks, current: [], terminalIDs: [])
                    replacedIDs = Set(uncertain.map { $0.id.lowercased() })
                    previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: uncertain, terminalIDs: [])
                } else {
                    previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
                }
                codexSourceUnavailable = false
            } else {
                previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
                codexSourceUnavailable = true
            }
            codexSourcePartial = true
            clearCodexDisplayEvidence()
            updateCodexAgentRetention(snapshot: nil, previous: oldTasks, replacedIDs: replacedIDs, sourceUnavailable: true)
          } else {
           switch codexRead.result {
           case .success(let snapshot):
            let oldTasks = previousCodex
            let safe = codexTerminalGuard.reconcile(snapshot, previous: previousCodex)
            updateCodexParentEvidence(snapshot)
            codexSourceUnavailable = false
            codexSourcePartial = snapshot.isPartial || safe.isPartial
            terminalIDs.formUnion(safe.terminalIDs)
            interruptedIDs.formUnion(snapshot.interruptedIDs.intersection(safe.terminalIDs))
            for id in safe.terminalIDs { codexAgentFallbackRoots.removeValue(forKey: id.lowercased()) }
            codexToolEvents = codexTerminalGuard.overflowed ? [:] :
                snapshot.toolEvents.filter { codexTerminalGuard.pending[$0.key] == nil }
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: safe.tasks, terminalIDs: safe.terminalIDs)
            let verifiedFiles = codexTerminalGuard.overflowed ? [:] :
                snapshot.verifiedActivityFiles.filter { codexTerminalGuard.pending[$0.key] == nil }
            previousCodex = TaskSnapshotMerger.confirmCodexActivities(previousCodex, files: verifiedFiles)
            let replaced = Set(safe.tasks.map { $0.id.lowercased() }).union(safe.terminalIDs.map { $0.lowercased() })
            updateCodexAgentRetention(snapshot: snapshot, previous: oldTasks, replacedIDs: replaced,
                                      sourceUnavailable: codexTerminalGuard.overflowed)
           case .failure:
            let oldTasks = previousCodex
            codexSourceUnavailable = true
            codexSourcePartial = false
            clearCodexDisplayEvidence()
            previousCodex = TaskSnapshotMerger.merge(previous: previousCodex, current: [], terminalIDs: [])
            updateCodexAgentRetention(snapshot: nil, previous: oldTasks, replacedIDs: [], sourceUnavailable: true)
           }
          }
        }
        var expiredCodex = false
        let nowForCodex = Date()
        let beforeExpiration = previousCodex
        previousCodex = previousCodex.map { task in
            guard task.isActive && nowForCodex.timeIntervalSince(task.updatedAt) >= CodexTaskReader.maximumConfirmedAge else { return task }
            expiredCodex = true
            return TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
        }
        if expiredCodex {
            codexSourcePartial = true
            updateCodexAgentRetention(snapshot: nil, previous: beforeExpiration, replacedIDs: [], sourceUnavailable: true)
        }
        if codexSourceUnavailable { unavailable.append(.codex) }
        if let response = claudeRead?.result {
            claudeHasCompletedRead = true
            let eventTime = Date()
            applyClaudeEvents(response.before, now: eventTime)
            applyClaudeEvents(response.middle, now: eventTime)
            applyClaudeEvents(response.after, now: eventTime)
            applyClaudeEvents(response.final, now: eventTime)
            claudeLoopError = response.channelUnavailable && diagnosticWorker != nil
                ? tr("Предупреждение Claude Code недоступно. Проверьте доступ или перезапустите приложение.",
                     "Claude Code loop warnings are unavailable. Check access or restart the app.") : ""
            switch response.outcome {
            case .disconnected:
                previousClaude = []
                claudeRetainedTitlesOverflow = false
                claudeSourceUnavailable = false
            case .noEvents:
                claudeSourceUnavailable = response.connection != .connected
                if !previousClaude.isEmpty {
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
                }
            case .snapshot(let snapshot):
                let afterPhases = response.after.affectedSessions.union(response.final.affectedSessions)
                let afterLifecycle = response.after.lifecycleSessions.union(response.final.lifecycleSessions)
                let mappedAfter = Set(afterPhases.compactMap { claudeSessionKey($0).map { "claude:" + $0 } })
                let mappedLifecycle = Set(afterLifecycle.compactMap { claudeSessionKey($0).map { "claude:" + $0 } })
                let lifecycleUnknownAll = response.after.gap || response.final.gap || mappedLifecycle.count != afterLifecycle.count
                let uncertainAll = response.changesAffectAll || response.after.affectsAll || response.final.affectsAll ||
                    response.after.gap || response.final.gap ||
                    response.phasePoisoned || snapshot.sourceUncertain ||
                    mappedAfter.count != afterPhases.count || lifecycleUnknownAll
                let affected = response.changedSessionIDs.union(response.phaseUncertainSessions)
                    .union(snapshot.titleHistoryOverflowIDs).union(mappedAfter).union(mappedLifecycle)
                var current = Self.clearClaudePlanConfirmations(snapshot.tasks, affected: uncertainAll ? nil : affected)
                current = current.map { task in
                    guard lifecycleUnknownAll || mappedLifecycle.contains(task.id) else { return task }
                    return TaskSnapshotMerger.merge(previous: [task], current: [], terminalIDs: [])[0]
                }
                if uncertainAll || !affected.isEmpty {
                    let fromRead = Self.preserveUncertainClaudeTitles(previous: response.earlierTasks, current: current,
                                                                      affected: uncertainAll ? nil : affected)
                    let fromPrevious = Self.preserveUncertainClaudeTitles(previous: previousClaude, current: fromRead.tasks,
                                                                          affected: uncertainAll ? nil : affected)
                    claudeRetainedTitlesOverflow = claudeRetainedTitlesOverflow || fromRead.overflow || fromPrevious.overflow
                    current = fromPrevious.tasks
                }
                var ended = snapshot.terminalIDs
                var neutral = snapshot.neutralEndedIDs
                if uncertainAll || response.connection != .connected {
                    ended.removeAll(); neutral.removeAll()
                } else {
                    ended.subtract(affected); neutral.subtract(affected)
                }
                terminalIDs.formUnion(ended)
                interruptedIDs.formUnion(snapshot.interruptedIDs.intersection(ended))
                neutralEndedIDs.formUnion(neutral)
                previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: current,
                                                           terminalIDs: ended.union(neutral))
                claudeSourceUnavailable = response.connection != .connected || snapshot.sourceUncertain ||
                    !snapshot.titleHistoryOverflowIDs.isEmpty || claudeRetainedTitlesOverflow
                if response.connection != .connected {
                    previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
                }
            case .failed, .changed:
                claudeSourceUnavailable = true
                previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
            }
        }
        if claudeSourceUnavailable { unavailable.append(.claude) }
        // A retained card after a read error or lost source must not retain a
        // confirmed plan internally even when the UI also hides stale state.
        previousClaude = Self.clearUnconfirmedClaudePlans(previousClaude)
        if externalProvidersEnabled { scheduleKimiScan(); scheduleDeepSeekScan(); scheduleHermesScan(); refreshExternalProviders(unavailable: &unavailable) }
        scheduleCodexCloudScan()
        codexPartiallyUnavailable = codexSourcePartial
        unavailableSources = unavailable
        var combined = (previousCodex + previousClaude + previousExternal + codexCloudTasks)
            .filter { $0.isActive || $0.isUnconfirmed || $0.isWaiting }
            .sorted { $0.updatedAt > $1.updatedAt }
        let now = Date()
        for id in Array(loopDetectors.keys) {
            guard var detector = loopDetectors[id] else { continue }
            detector.configure(threshold: diagnosticSettings.loopThreshold, windowMinutes: diagnosticSettings.loopWindowMinutes)
            detector.refresh(now: now)
            loopDetectors[id] = detector
        }
        let knownTasks = diagnosticTasks + combined
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
        let previousDiagnosticTasks = diagnosticTasks
        diagnosticTasks = combined
        let isLocalCodex: (MonitoredTask) -> Bool = { $0.provider == .codex && UUID(uuidString: $0.id) != nil }
        let projection = CodexTaskGrouping.makeRetainedProjection(combined.filter(isLocalCodex),
                                                                  groups: codexAgentGroups, titles: codexParentTitles,
                                                                  retainedCards: codexAgentCardBindings,
                                                                  fallbackRoots: codexAgentFallbackRoots)
        combined = projection.tasks + combined.filter { !isLocalCodex($0) }
        let selectedID = selectedTask?.id
        var mappedSelection = selectedID.flatMap { projection.displayIDBySourceID[$0.lowercased()] }
        if let selectedTask, selectedTask.provider == .codex,
           let old = codexAgentFallbackRoots[selectedTask.id.lowercased()],
           selectedTask.lastActivityFileIdentity == old.lastActivityFileIdentity,
           selectedTask.startKey == old.startKey {
            let fallback = "codex-retained:" + selectedTask.id.lowercased()
            if !previousTasks.contains(where: { $0.id == fallback }) &&
                combined.contains(where: { $0.id == fallback }) {
                mappedSelection = fallback
            }
        }
        if mappedSelection == nil, let selectedID, selectedID.hasPrefix("codex-group:") {
            let root = String(selectedID.dropFirst("codex-group:".count))
            mappedSelection = combined.first(where: { $0.provider == .codex && $0.id.lowercased() == root })?.id
        }
        let selectable = Set(CodexTaskGrouping.compactVisibleIndices(combined, confirmedChildren: compactCodexChildren).map { combined[$0].compactSelectionKey })
        let focus = taskFocus.reconcile(current: combined, previous: previousTasks,
                                        selectedID: mappedSelection ?? selectedID, monitoringStartedAt: monitoringStartedAt,
                                        selectableKeys: selectable)
        combined = focus.tasks
        var chosen = focus.selectedID
        var manualRefreshKey: CompactTaskSelectionKey?
        if let mappedSelection, mappedSelection != selectedID,
           let position = combined.firstIndex(where: { $0.id == mappedSelection }) {
            // The compact carousel only exposes its first three cards. Carry
            // the user's selected child to its displayed group before pruning.
            taskFocus.prioritize(mappedSelection)
            if position >= 3 {
                let selectedTask = combined.remove(at: position)
                combined.insert(selectedTask, at: 0)
            }
            chosen = mappedSelection
        }
        let readSelectionGeneration = codexRead?.selectionGeneration ?? claudeRead?.selectionGeneration
        if let readSelectionGeneration, readSelectionGeneration != compactManualSelectionGeneration,
           let selectedTask,
           let position = CodexTaskGrouping.manualRefreshMatch(combined, previous: previousTasks, selected: selectedTask) {
                let visible = CodexTaskGrouping.compactVisibleIndices(combined, confirmedChildren: compactCodexChildren)
                if let compactPosition = visible.firstIndex(of: position) {
                    taskFocus.prioritize(selectedTask.id)
                    manualRefreshKey = combined[position].compactSelectionKey
                    if compactPosition >= 3 {
                        let manuallySelected = combined.remove(at: position)
                        combined.insert(manuallySelected, at: 0)
                    }
                    chosen = selectedTask.id
                }
        }
        let manualSourceIndex: Int?
        if let key = manualRefreshKey {
            let matches = CodexTaskGrouping.compactVisibleIndices(combined, confirmedChildren: compactCodexChildren)
                .prefix(3).filter { combined[$0].compactSelectionKey == key }
            manualSourceIndex = matches.count == 1 ? matches.first : nil
        } else {
            manualSourceIndex = nil
        }
        let selectedSourceIndex = manualSourceIndex ?? CodexTaskGrouping.compactSelectionSourceIndex(combined,
            confirmedChildren: compactCodexChildren, chosenID: chosen,
            previous: selectedTask, previousVisibleIndex: previousCompactIndex)
        tasks = combined
        compactIndex = selectedSourceIndex ?? 0
        if let provider = selectedProvider.provider, !providers.contains(provider) { selectedProvider = .all }
        recordChanges(previousTasks: previousDiagnosticTasks, previousUnavailable: previousUnavailable,
                      terminalIDs: terminalIDs, interruptedIDs: interruptedIDs, toolInputs: toolInputs)
    }

    private func clearCodexDisplayEvidence() {
        codexParentsForDisplay = [:]
        codexRootsForDisplay = []
        confirmedCodexChildrenForCompact = [:]
    }

    private func updateCodexAgentRetention(snapshot: CodexTaskSnapshot?, previous: [MonitoredTask],
                                           replacedIDs: Set<String>, sourceUnavailable: Bool) {
        let old = Dictionary(grouping: previous.filter { $0.provider == .codex }, by: { $0.id.lowercased() })
        let current = Dictionary(grouping: previousCodex.filter { $0.provider == .codex }, by: { $0.id.lowercased() })
        var carried: [String: UUID] = [:]
        for (id, token) in codexAgentRootBindings where !replacedIDs.contains(id) {
            guard let before = old[id], before.count == 1, let after = current[id], after.count == 1,
                  before[0].lastActivityFileIdentity == after[0].lastActivityFileIdentity,
                  before[0].startKey == after[0].startKey, after[0].isUnconfirmed,
                  !after[0].isActive && !after[0].isWaiting else { continue }
            carried[id] = token
        }
        let conflicts = codexParentConflicts.union(codexTerminalGuard.pending.keys.map { $0.lowercased() })
        let retained = codexAgentRetention.observe(tasks: previousCodex,
            identities: snapshot?.verifiedAgentIdentities ?? [:],
            sourcePartial: snapshot?.agentIdentityPartial ?? true,
            sourceUnavailable: sourceUnavailable,
            conflictedIDs: conflicts,
            retainedRootBindings: carried)
        for group in retained.groups where group.canAttach {
            guard let proof = snapshot?.verifiedAgentIdentities[group.rootID], proof == group.rootIdentity,
                  let root = current[group.rootID], root.count == 1,
                  root[0].lastActivityIdentityConfirmed == true,
                  root[0].lastActivityFileIdentity == proof.file else { continue }
            codexAgentFallbackRoots[group.rootID] = root[0]
        }
        var agentCards: [String: CodexRetainedAgentCard] = [:]
        for group in retained.groups {
            for member in group.members {
                let id = member.id
                guard let after = current[id], after.count == 1,
                      after[0].lastActivityFileIdentity == member.identity.file,
                      !after[0].startKey.isEmpty, after[0].startKey.utf8.count <= 512 else { continue }
                if member.current && after[0].lastActivityIdentityConfirmed == true {
                    agentCards[id] = CodexRetainedAgentCard(file: member.identity.file, startKey: after[0].startKey)
                } else if !replacedIDs.contains(id), let before = old[id], before.count == 1,
                          let prior = codexAgentCardBindings[id], prior.file == member.identity.file,
                          prior.startKey == before[0].startKey, prior.startKey == after[0].startKey,
                          before[0].lastActivityFileIdentity == prior.file,
                          after[0].isUnconfirmed && !after[0].isActive && !after[0].isWaiting {
                    agentCards[id] = prior
                }
            }
        }
        codexAgentCardBindings = agentCards
        codexAgentGroups = retained.groups
        let bindings: [(String, UUID)] = retained.groups.compactMap { group -> (String, UUID)? in
            guard group.canAttach, let token = group.rootBinding else { return nil }
            return (group.rootID, token)
        }
        codexAgentRootBindings = Dictionary(uniqueKeysWithValues: bindings)
    }

    private func updateCodexParentEvidence(_ snapshot: CodexTaskSnapshot) {
        codexRootsForDisplay = snapshot.confirmedSubagentRoots
        let currentTasksByID = Dictionary(grouping: snapshot.tasks, by: { $0.id.lowercased() })
        var confirmedChildren: [String: CodexFileIdentity] = [:]
        var conflictingFiles: Set<String> = []
        for (id, identity) in snapshot.verifiedAgentIdentities where !identity.isRoot && identity.parentID != nil {
            let key = id.lowercased()
            guard !conflictingFiles.contains(key), let matches = currentTasksByID[key], matches.count == 1,
                  matches[0].lastActivityIdentityConfirmed == true,
                  let file = matches[0].lastActivityFileIdentity, file == identity.file else { continue }
            if let previous = confirmedChildren[key], previous != file {
                confirmedChildren.removeValue(forKey: key)
                conflictingFiles.insert(key)
            } else {
                confirmedChildren[key] = file
            }
        }
        confirmedCodexChildrenForCompact = confirmedChildren
        var current: [String: String] = [:]
        for (child, parent) in snapshot.subagentParents {
            let key = child.lowercased(), value = parent.lowercased()
            guard !codexParentConflicts.contains(key) else { continue }
            if let old = codexParentEvidence[key], old != value {
                codexParentConflicts.insert(key)
                codexParentEvidence.removeValue(forKey: key)
                continue
            }
            guard codexParentEvidence[key] != nil || codexParentEvidence.count < 512 else { continue }
            codexParentEvidence[key] = value
            current[key] = value
        }
        for (id, title) in snapshot.subagentTitles {
            let key = id.lowercased()
            if codexParentTitles[key] != nil || codexParentTitles.count < 512 { codexParentTitles[key] = title }
        }
        codexParentsForDisplay = codexParentEvidence.filter { child, parent in
            !codexParentConflicts.contains(child) && current[child] == parent
        }
    }

    private static func externalScope(_ task: MonitoredTask) -> String? {
        guard [.deepseek, .kimi, .hermes].contains(task.provider) else { return nil }
        let prefix = task.provider == .deepseek && task.id.hasPrefix("deepseek-unassigned:")
            ? "deepseek-unassigned:" : task.provider.rawValue + ":"
        guard task.id.hasPrefix(prefix) else { return nil }
        return ExternalProfileVisibility.scopedSession(String(task.id.dropFirst(prefix.count)))
    }

    private func rememberCapacity(_ provider: TaskProvider, scope: String? = nil) {
        guard let scope else { externalCapacityUnattributed.insert(provider); return }
        if (externalCapacityScopes[provider] ?? []).contains(scope) { return }
        let count = externalCapacityScopes.values.reduce(0) { $0 + $1.count }
        if count < maximumExternalScopeWarnings {
            externalCapacityScopes[provider, default: []].insert(scope)
        } else {
            externalCapacityUnattributed.insert(provider)
        }
    }

    private func rememberCapacity(from runtime: ExternalProviderRuntime) {
        for provider in runtime.capacityUnattributedProviders { rememberCapacity(provider) }
        for (provider, scopes) in runtime.capacityLimitedScopes {
            for scope in scopes { rememberCapacity(provider, scope: scope) }
        }
    }

    private func refreshExternalProviders(unavailable: inout [TaskProvider]) {
        var allowed: Set<TaskProvider> = []
        var uncertain: Set<TaskProvider> = []
        var partiallyUnavailable: Set<TaskProvider> = []
        var failedRuntime: Set<TaskProvider> = []
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
                    partiallyUnavailable.insert(provider)
                case .partial:
                    unavailable.append(provider)
                    if provider == .deepseek && externalConnections[.deepseek] == nil &&
                        deepSeekProfiles.contains(where: { $0.state == "connected" }) {
                        // The receiver may collect only neutral evidence from
                        // ambiguous scopes while at least one profile is live.
                        allowed.insert(provider)
                        partiallyUnavailable.insert(provider)
                    } else {
                        uncertain.insert(provider)
                    }
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
        // Build ownership before every fallback, including failed or partial providers.
        var scopes: [TaskProvider: Set<String>] = [:]
        var uncertainScopes: [TaskProvider: Set<String>] = [:]
        var ambiguousScopes: [TaskProvider: Set<String>] = [:]
        if externalConnections[.deepseek] == nil {
            scopes[.deepseek] = deepSeekAllowedScopes
            uncertainScopes[.deepseek] = deepSeekUncertainScopes
            ambiguousScopes[.deepseek] = deepSeekHistory.ambiguous(deepSeekProfiles)
        }
        if externalConnections[.kimi] == nil {
            if kimiScanError == nil, kimiState == "connected", let scope = kimiScope { scopes[.kimi] = [scope] }
            var uncertainKimi = kimiRetiredScopes
            if kimiScanError != nil, let scope = kimiSeenScope { uncertainKimi.insert(scope) }
            if !uncertainKimi.isEmpty { uncertainScopes[.kimi] = uncertainKimi }
        }
        if externalConnections[.hermes] == nil {
            scopes[.hermes] = hermesAllowedScopes
            uncertainScopes[.hermes] = hermesUncertainScopes
            ambiguousScopes[.hermes] = hermesHistory.ambiguous(Self.hermesHistoryProfiles(hermesProfiles))
        }
        defer {
            for provider in TaskProvider.allCases where (allowed.contains(provider) || uncertain.contains(provider)) &&
                !unavailable.contains(provider) {
                let recorded = externalCapacityScopes[provider] ?? []
                let visible = (scopes[provider] ?? []).union(uncertainScopes[provider] ?? [])
                let missingMetadata = scopes[provider] == nil && uncertainScopes[provider] == nil
                if externalCapacityUnattributed.contains(provider) ||
                    !recorded.isDisjoint(with: visible) || (missingMetadata && !recorded.isEmpty) {
                    unavailable.append(provider)
                    if allowed.contains(provider) && !failedRuntime.contains(provider) {
                        partiallyUnavailable.insert(provider)
                    }
                }
            }
            partialExternalSources = partiallyUnavailable.subtracting(failedRuntime).intersection(Set(unavailable))
        }
        func filteredFallback(_ providers: Set<TaskProvider>, onlyUnconfirmed: Bool = false) -> [MonitoredTask] {
            let allowedDeepSeek = scopes[.deepseek] ?? []
            let ambiguousDeepSeek = ambiguousScopes[.deepseek] ?? []
            let candidates = unconfirmedExternalTasks(for: providers, onlyUnconfirmed: onlyUnconfirmed).compactMap { task -> MonitoredTask? in
                guard task.provider == .deepseek, task.id.hasPrefix("deepseek:"),
                      let scope = ExternalProfileVisibility.scopedSession(String(task.id.dropFirst("deepseek:".count))) else { return task }
                if ambiguousDeepSeek.contains(scope) ||
                    (deepSeekHistory.historyLost && !allowedDeepSeek.contains(scope) && !deepSeekDisabledScopes.contains(scope)) {
                    return ExternalProfileVisibility.neutralDeepSeek(task)
                }
                return task
            }
            return ExternalProfileVisibility.filter(candidates, allowed: providers,
                profileScopes: scopes, uncertainScopes: uncertainScopes, ambiguousScopes: ambiguousScopes,
                deepSeekDisabledScopes: deepSeekDisabledScopes)
        }
        let retained = filteredFallback(uncertain)
        // Hermes needs fresh observer evidence after a late monitor start.
        let previouslyUnconfirmed = filteredFallback(allowed.subtracting([.hermes]), onlyUnconfirmed: true)
        let partialProviders = Set(uncertainScopes.keys.filter { allowed.contains($0) && $0 != .hermes })
        let partialScopes = filteredFallback(partialProviders).filter { task in
            let prefix = task.provider == .deepseek && task.id.hasPrefix("deepseek-unassigned:")
                ? "deepseek-unassigned:" : task.provider.rawValue + ":"
            guard task.id.hasPrefix(prefix),
                  let scope = ExternalProfileVisibility.scopedSession(String(task.id.dropFirst(prefix.count))) else { return false }
            return (uncertainScopes[task.provider] ?? []).contains(scope)
        }
        guard !allowed.isEmpty else {
            if let runtime = externalRuntime {
                rememberCapacity(from: runtime)
                parkedExternalProviderState = runtime.parkState(markTransportGap: false, preservingKimi: uncertain.contains(.kimi))
                runtime.stop()
            } else {
                parkedExternalProviderState?.retainProviders(uncertain.contains(.kimi) ? ["kimi"] : [])
            }
            externalRuntime = nil
            externalV2Runtime?.stop()
            externalV2Runtime = nil
            previousExternal = retained
            return
        }
        do {
            if externalRuntime == nil {
                let runtime = try makeExternalRuntime()
                if let parked = parkedExternalProviderState { runtime.adoptState(parked); parkedExternalProviderState = nil }
                if externalV2Enabled { runtime.markV1Unconfirmed() }
                externalRuntime = runtime
            }
            guard let runtime = externalRuntime else { throw ExternalProviderRuntimeError.stopped }
            let current = runtime.snapshot(allowed: allowed, profileScopes: scopes,
                uncertainScopes: uncertainScopes, ambiguousScopes: ambiguousScopes,
                deepSeekHistoryLost: deepSeekHistory.historyLost, deepSeekDisabledScopes: deepSeekDisabledScopes,
                preservingKimi: uncertain.contains(.kimi))
            rememberCapacity(from: runtime)
            guard !runtime.transportUnavailable else { throw ExternalProviderRuntimeError.stopped }
            var combined: [String: MonitoredTask] = [:]
            var pendingNew: [MonitoredTask] = []
            var superseded: Set<String> = []
            let previousIDs = Set(previousExternal.map(\.id))
            func merge(_ task: MonitoredTask, preserving: Bool = false) {
                if combined[task.id] != nil {
                    combined[task.id] = task
                } else if preserving || previousIDs.contains(task.id) {
                    if combined.count < maximumExternalCards { combined[task.id] = task }
                    else { rememberCapacity(task.provider, scope: Self.externalScope(task)) }
                } else {
                    pendingNew.append(task)
                }
            }
            // Reserve space for visible evidence before accepting unseen tasks.
            for task in retained + previouslyUnconfirmed + partialScopes { merge(task, preserving: true) }
            for task in current { merge(task) }
            let v2Providers = allowed.intersection([.opencode, .deepseek])
            if externalV2Enabled && !v2Providers.isEmpty {
                do {
                    guard !externalV2Failed else { throw ExternalProviderRuntimeError.stopped }
                    if externalV2Runtime == nil { externalV2Runtime = try makeExternalV2Runtime() }
                    guard let v2 = externalV2Runtime, !v2.isStopped else { throw ExternalProviderRuntimeError.stopped }
                    var desired: Set<ExternalProviderV2Scope> = []
                    if allowed.contains(.opencode) { desired.insert(ExternalProviderV2Scope(provider: "opencode", scope: "global")) }
                    if allowed.contains(.deepseek) {
                        let usable = (scopes[.deepseek] ?? []).subtracting(ambiguousScopes[.deepseek] ?? [])
                        desired.formUnion(usable.map { ExternalProviderV2Scope(provider: "deepseek", scope: $0) })
                    }
                    try v2.setScopes(desired)
                    let observed = ExternalProfileVisibility.filter(v2.snapshot(), allowed: allowed,
                        profileScopes: scopes, uncertainScopes: [:], ambiguousScopes: ambiguousScopes,
                        deepSeekDisabledScopes: deepSeekDisabledScopes)
                    for id in v2.terminalIDs where id.hasPrefix("deepseek:") {
                        let session = String(id.dropFirst("deepseek:".count))
                        guard let scope = ExternalProfileVisibility.scopedSession(session),
                              (scopes[.deepseek] ?? []).contains(scope),
                              !(ambiguousScopes[.deepseek] ?? []).contains(scope) else { continue }
                        combined.removeValue(forKey: id)
                        superseded.insert(id)
                    }
                    for task in observed { merge(task) }
                    for scope in v2.capacityLimitedScopes {
                        if let provider = TaskProvider(rawValue: scope.provider) {
                            rememberCapacity(provider, scope: provider == .opencode ? nil : scope.scope)
                        }
                    }
                    for name in v2.capacityLimitedProviders {
                        if let provider = TaskProvider(rawValue: name) { rememberCapacity(provider) }
                    }
                } catch {
                    externalV2Failed = true
                    externalV2Runtime?.stop(); externalV2Runtime = nil
                    for provider in v2Providers where !unavailable.contains(provider) { unavailable.append(provider) }
                    partiallyUnavailable.formUnion(v2Providers)
                    for task in filteredFallback(v2Providers) where combined[task.id] == nil { merge(task, preserving: true) }
                }
            } else if externalV2Runtime != nil {
                externalV2Runtime?.stop(); externalV2Runtime = nil
            }
            for task in pendingNew where !superseded.contains(task.id) {
                if combined[task.id] != nil || combined.count < maximumExternalCards { combined[task.id] = task }
                else { rememberCapacity(task.provider, scope: Self.externalScope(task)) }
            }
            previousExternal = Array(combined.values)
        } catch {
            failedRuntime.formUnion(allowed)
            for provider in TaskProvider.allCases where allowed.contains(provider) && !unavailable.contains(provider) {
                unavailable.append(provider)
            }
            previousExternal = filteredFallback(uncertain.union(allowed))
            if let runtime = externalRuntime {
                rememberCapacity(from: runtime)
                parkedExternalProviderState = runtime.parkState(markTransportGap: true,
                    preservingKimi: allowed.contains(.kimi) || uncertain.contains(.kimi))
                runtime.stop()
            }
            externalRuntime = nil
            externalV2Runtime?.stop(); externalV2Runtime = nil
        }
    }

    var testCodexReadInFlight: Bool { codexReadInFlight }
    var testClaudeReadInFlight: Bool { claudeReadInFlight }
    var testClaudeChannel: ClaudeLoopChannel? { claudeSourceWorker.channelForTesting }
    var testClaudeWorker: ClaudeSourceWorker { claudeSourceWorker }

    #if DEBUG
    func testSeedCodexTasks(_ seed: [MonitoredTask]) {
        precondition(diagnosticWorker == nil && !externalProvidersEnabled && !codexReadInFlight)
        previousCodex = seed
        tasks = seed
    }

    func testSeedClaudeTasks(_ seed: [MonitoredTask]) {
        precondition(diagnosticWorker == nil && !externalProvidersEnabled && !claudeReadInFlight)
        previousClaude = seed
        tasks = seed
    }

    var testCodexReadDelayed: Bool { codexReadDelayed }
    var testCodexReadGeneration: UInt64 { codexReadGeneration }
    var testPendingCodexTerminalIDs: Set<String> { Set(codexTerminalGuard.pending.keys) }
    func testRetainedAgentCount(root: String) -> Int? {
        codexAgentGroups.first(where: { $0.rootID == root.lowercased() })?.knownCount
    }
    func testPeriodicRefresh() { periodicRefresh() }

    func testReplacePreviewTasks(_ updated: [MonitoredTask]) {
        precondition(diagnosticWorker == nil)
        tasks = updated
    }

    func testSetCompactSnapshot(_ snapshot: CodexTaskSnapshot) {
        precondition(diagnosticWorker == nil)
        updateCodexParentEvidence(snapshot)
    }

    func testClearCompactSnapshot() {
        precondition(diagnosticWorker == nil)
        clearCodexDisplayEvidence()
    }

    func testGroupingParent(_ child: String) -> String? { codexParentsForDisplay[child.lowercased()] }

    func testSetExternalAvailability(previous: [MonitoredTask], unavailable: [TaskProvider],
                                     partiallyUnavailable: Set<TaskProvider> = []) {
        precondition(!externalProvidersEnabled && diagnosticWorker == nil)
        previousExternal = previous
        tasks = previous
        unavailableSources = unavailable
        partialExternalSources = partiallyUnavailable
    }

    var testPartialExternalSources: Set<TaskProvider> { partialExternalSources }

    // Preview-only seam; tests must inject a synthetic runtime factory.
    func testExternalFallback(previous: [MonitoredTask], deepSeekRosters: [[DeepSeekProfile]],
                              hermesRosters: [[HermesProfile]] = [],
                              deepSeekFailure: Bool = false, hermesFailure: Bool = false,
                              deepSeekInvalid: Bool = false, hermesInvalid: Bool = false) -> ([MonitoredTask], [TaskProvider]) {
        precondition(!externalProvidersEnabled && diagnosticWorker == nil)
        previousExternal = previous
        for roster in deepSeekRosters {
            precondition(deepSeekHistory.update(roster))
            deepSeekProfiles = roster
        }
        for roster in hermesRosters {
            precondition(HermesIntegration.validProfiles(roster))
            precondition(hermesHistory.update(Self.hermesHistoryProfiles(roster)))
            hermesProfiles = roster
        }
        if !deepSeekRosters.isEmpty { seenExternalConnections.insert(.deepseek) }
        if !hermesRosters.isEmpty { seenExternalConnections.insert(.hermes) }
        if deepSeekInvalid { deepSeekHistory.markInvalidRoster() }
        if hermesInvalid { hermesHistory.markInvalidRoster() }
        deepSeekScanError = deepSeekInvalid ? "invalid-response" : (deepSeekFailure ? "synthetic" : nil)
        hermesScanError = hermesInvalid ? "invalid-response" : (hermesFailure ? "synthetic" : nil)
        var unavailable: [TaskProvider] = []
        refreshExternalProviders(unavailable: &unavailable)
        return (previousExternal, unavailable)
    }
    #endif

    private func unconfirmedExternalTasks(for providers: Set<TaskProvider>, onlyUnconfirmed: Bool = false) -> [MonitoredTask] {
        previousExternal.filter { providers.contains($0.provider) && (!onlyUnconfirmed || $0.isUnconfirmed) }.map { task in
            var copy = task
            copy.isActive = false
            copy.isWaiting = false
            copy.isUnconfirmed = true
            if copy.provider == .opencode || copy.provider == .deepseek { copy.progress = nil; copy.progressKind = .none }
            if copy.provider == .opencode { copy.steps = [] }
            copy.activity = tr("Статус не подтверждён", "Status unconfirmed")
            copy.planConfirmed = false
            return copy
        }
    }

    private func applyClaudeEvents(_ batch: ClaudeSourceEvents, now: Date) {
        if batch.gap { claudeLoopDetectors.removeAll() }
        if diagnosticWorker == nil { claudeLoopDetectors.removeAll() }
        for event in batch.ordinary {
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
            if diagnosticWorker == nil { clearVisibleLoopWarning(for: taskID) }
            return
        }
        detector.dismiss()
        loopDetectors[taskID] = detector
        clearVisibleLoopWarning(for: taskID)
    }

    private func clearVisibleLoopWarning(for taskID: String) {
        for index in tasks.indices {
            if tasks[index].id == taskID { tasks[index].loopWarning = nil }
            if let child = tasks[index].codexAgents?.firstIndex(where: { $0.id == taskID }) {
                tasks[index].codexAgents?[child].loopWarning = nil
            }
        }
    }

    private func journalID(for task: MonitoredTask) -> String? {
        let id = task.provider == .claude && task.id.hasPrefix("claude:") ? String(task.id.dropFirst(7)) : task.id
        guard !id.isEmpty, id.utf8.count <= 128, id.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 45 || $0.value == 95
        }) else { return nil }
        return id
    }

    private func journalReferences() -> [DiagnosticTaskReference] {
        diagnosticTasks.compactMap { task in
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
        let currentIDs = Set(diagnosticTasks.map(\.id))
        var inputs = toolInputs
        for task in diagnosticTasks {
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
            try updateClaudeConnection(connected)
            claudeSourceWorker.invalidate()
            claudeSourceUnavailable = true
            previousClaude = TaskSnapshotMerger.merge(previous: previousClaude, current: [], terminalIDs: [])
            previousClaude = Self.clearUnconfirmedClaudePlans(previousClaude)
            claudeLoopDetectors.removeAll()
            sourceMessage = connected ? tr("Подключено. Перезапустите Claude Code.", "Connected. Restart Claude Code.") : tr("Отключено", "Disconnected")
            refresh()
        } catch {
            sourceMessage = error.localizedDescription
        }
    }
}
