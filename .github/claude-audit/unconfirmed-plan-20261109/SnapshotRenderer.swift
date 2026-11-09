import AppKit
import SwiftUI

@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) -> Int32 {
        let previousAppearance = UserDefaults.standard.object(forKey: "appearanceMode")
        defer {
            AppLanguage.previewOverride = nil
            if let previousAppearance {
                UserDefaults.standard.set(previousAppearance, forKey: "appearanceMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "appearanceMode")
            }
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            if ProcessInfo.processInfo.environment["AITM_CLAUDE_PLAN_PREVIEW_ONLY"] == "1" {
                for language in [AppLanguage.ru, .en] {
                    AppLanguage.previewOverride = language
                    for mode in [AppearanceMode.dark, .light] {
                        for compact in [false, true] {
                            for provider in [TaskProvider.claude, .codex] {
                                for state in ["confirmed", "unconfirmed", "stale", "overall"] {
                                    let name = "\(provider.rawValue)-plan-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")-\(state)"
                                    try render(name: name, mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, planUnconfirmed: state == "unconfirmed" || state == "overall", claudePlanFixture: provider == .claude, codexPlanFixture: provider == .codex, taskUnconfirmed: state == "stale", overallProgress: state == "overall")
                                }
                            }
                            let lossName = "codex-source-loss-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")"
                            try render(name: lossName, mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
                        }
                    }
                }
                return 0
            }
            try render(name: "expanded-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "expanded-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "many-providers-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, manyProviders: true)
            try render(name: "many-providers-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, manyProviders: true)
            try render(name: "compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "settings-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory)
            try render(name: "settings-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory)
            try render(name: "about-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory, about: true)
            try render(name: "about-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory, about: true)
            try render(name: "update-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, update: true)
            try render(name: "update-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, update: true)
            try render(name: "journal-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "journal-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "loop-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "claude-loop-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-error-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude, loopError: true)
            try render(name: "claude-loop-error-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude, loopError: true)
            try render(name: "loop-source-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.claude], loopWarning: true)
            try render(name: "source-unavailable-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try renderHint(name: "hint-dark", mode: .dark, outputDirectory: outputDirectory)
            try renderHint(name: "hint-light", mode: .light, outputDirectory: outputDirectory)
            for language in [AppLanguage.ru, .en] {
                AppLanguage.previewOverride = language
                for mode in [AppearanceMode.dark, .light] {
                    for compact in [false, true] {
                        try render(name: "empty-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")", mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, emptyTasks: true)
                        for unconfirmed in [false, true] {
                            let name = "plan-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")-\(unconfirmed ? "unconfirmed" : "confirmed")"
                            try render(name: name, mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, planUnconfirmed: unconfirmed)
                        }
                    }
                    try render(name: "about-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, about: true)
                    try render(name: "journal-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
                    try render(name: "update-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: false, outputDirectory: outputDirectory, update: true)
                    try render(name: "settings-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory)
                    try render(name: "settings-end-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsEnd: true)
                    try render(name: "settings-sources-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true)
                    for cloud in [SettingsPreviewCloud.disconnected, .connected, .error, .partial] {
                        let label: String
                        switch cloud { case .disconnected: label = "disconnected"; case .connected: label = "connected"; case .error: label = "error"; case .partial: label = "partial" }
                        try render(name: "settings-cloud-\(label)-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, cloudPreview: cloud)
                    }
                    for kimi in [SettingsPreviewKimi.disconnected, .connected, .disabled, .error] {
                        let label: String
                        switch kimi { case .disconnected: label = "disconnected"; case .connected: label = "connected"; case .disabled: label = "disabled"; case .error: label = "error" }
                        try render(name: "settings-kimi-\(label)-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, kimiPreview: kimi)
                    }
                    for hermes in [SettingsPreviewHermes.absent, .prepared, .enabled, .error, .unavailable] {
                        try render(name: "settings-hermes-\(hermes.rawValue)-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, hermesPreview: hermes)
                    }
                    for compact in [false, true] {
                        try render(name: "cloud-task-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")", mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, cloudTask: true)
                        try render(name: "kimi-task-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")", mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, kimiTask: true)
                    }
                    try render(name: "settings-claude-unconfirmed-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, claudePreview: .unconfirmed)
                    try render(name: "settings-claude-connected-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, claudePreview: .connected)
                    try render(name: "settings-desktop-profile-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsSources: true, desktopProfile: true)
                    try render(name: "many-providers-\(language.rawValue)-\(mode.rawValue)-expanded", mode: mode, compact: false, settings: false, outputDirectory: outputDirectory, manyProviders: true)
                    try render(name: "many-providers-\(language.rawValue)-\(mode.rawValue)-compact", mode: mode, compact: true, settings: false, outputDirectory: outputDirectory, manyProviders: true)
                    try render(name: "many-providers-\(language.rawValue)-\(mode.rawValue)-bottom", mode: mode, compact: false, settings: false, outputDirectory: outputDirectory, manyProviders: true, tasksEnd: true)
                    try render(name: "many-providers-\(language.rawValue)-\(mode.rawValue)-tabs-end", mode: mode, compact: false, settings: false, outputDirectory: outputDirectory, manyProviders: true, tabsEnd: true)
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Snapshot error: \(error)\n".utf8))
            return 1
        }
    }

    private static func renderHint(name: String, mode: AppearanceMode, outputDirectory: URL) throws {
        let field = TruncatingTextField(labelWithString: "")
        field.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        let panel = field.makeHintPanel(text: "Проверяю нативную сборку, локальные источники и создание установочного образа для macOS")
        guard let content = panel.contentView else { throw SnapshotError.bitmap }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw SnapshotError.bitmap }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.png }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private static func render(name: String, mode: AppearanceMode, compact: Bool, settings: Bool, outputDirectory: URL, unavailableSources: [TaskProvider] = [], journal: Bool = false, loopWarning: Bool = false, loopProvider: TaskProvider = .codex, loopError: Bool = false, about: Bool = false, update: Bool = false, planUnconfirmed: Bool = false, settingsEnd: Bool = false, settingsSources: Bool = false, desktopProfile: Bool = false, claudePreview: SettingsPreviewClaude? = nil, cloudPreview: SettingsPreviewCloud? = nil, kimiPreview: SettingsPreviewKimi? = nil, hermesPreview: SettingsPreviewHermes? = nil, cloudTask: Bool = false, kimiTask: Bool = false, manyProviders: Bool = false, tasksEnd: Bool = false, tabsEnd: Bool = false, emptyTasks: Bool = false, claudePlanFixture: Bool = false, codexPlanFixture: Bool = false, taskUnconfirmed: Bool = false, overallProgress: Bool = false) throws {
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        let store: TaskStore
        if claudePlanFixture || codexPlanFixture {
            let fixture = MonitoredTask(
                id: claudePlanFixture ? "claude:synthetic" : "codex-synthetic", provider: claudePlanFixture ? .claude : .codex,
                title: claudePlanFixture ? tr("Задача Claude Code", "Claude Code task") : tr("Задача Codex", "Codex task"),
                activity: taskUnconfirmed ? tr("Статус не подтверждён", "Status unconfirmed") : tr("Выполняет действие", "Performing an action"),
                isActive: !taskUnconfirmed, progress: 33, progressKind: .exact,
                steps: [
                    TaskStep(id: "one", title: tr("Первый этап", "First step"), status: .done),
                    TaskStep(id: "two", title: tr("Второй этап", "Second step"), status: .active),
                    TaskStep(id: "three", title: tr("Третий этап", "Third step"), status: .pending)
                ], updatedAt: Date(), isUnconfirmed: taskUnconfirmed, planConfirmed: !planUnconfirmed,
                progressBasis: overallProgress ? .task : nil)
            store = TaskStore(previewTasks: [fixture])
        } else if emptyTasks {
            store = TaskStore(previewTasks: [])
        } else if kimiTask {
            let state = ExternalProviderStateStore()
            let json = #"{"version":1,"provider":"kimi","session":"synthetic","kind":"started"}"#
            guard let event = ExternalProviderEventParser.parse(Data(json.utf8)), state.apply(event, now: Date()) else { throw SnapshotError.bitmap }
            store = TaskStore(previewTasks: ExternalProviderTaskMapper.tasks(state.snapshot(now: Date())))
        } else if cloudTask {
            let item = CodexCloudReader.Task(id: "codex-cloud:synthetic", title: tr("Тестовая облачная задача", "Synthetic cloud task"), status: .pending, updatedAt: Date())
            store = TaskStore(previewTasks: [TaskStore.codexCloudMonitoredTask(item)])
        } else {
            store = manyProviders ? TaskStore.manySourcesPreview() : (journal ? TaskStore.journalPreview() : (loopWarning ? TaskStore.loopPreview(unavailableSources: unavailableSources, provider: loopProvider, showsError: loopError) : TaskStore.preview(unavailableSources: unavailableSources, planUnconfirmed: planUnconfirmed)))
        }
        if settingsSources { store.setPreviewDeepSeekProfiles(desktop: desktopProfile) }
        if let hermesPreview { store.setPreviewHermesProfile(hermesPreview.rawValue) }
        store.isCompact = compact
        store.showsSettings = settings || journal
        store.showsJournal = journal
        store.showsAbout = about
        if update { store.setPreviewUpdate() }
        let compactHeight: CGFloat = 182 + (unavailableSources.isEmpty ? 0 : 24) + (loopWarning ? 64 : 0) + ((planUnconfirmed || claudePlanFixture || codexPlanFixture) ? 22 : 0)
        let size = compact ? NSSize(width: 372, height: compactHeight) : NSSize(width: 560, height: 700)
        let scheme: ColorScheme = mode == .dark ? .dark : .light
        let view = RootView()
            .environmentObject(store)
            .environment(\.colorScheme, scheme)
            .environment(\.settingsPreviewEnd, settingsEnd)
            .environment(\.settingsPreviewSources, settingsSources)
            .environment(\.settingsPreviewClaude, claudePreview)
            .environment(\.settingsPreviewCloud, cloudPreview)
            .environment(\.settingsPreviewKimi, kimiPreview)
            .environment(\.settingsPreviewHermes, hermesPreview)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        let previewWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = hosting
        previewWindow.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        previewWindow.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        defer { previewWindow.close() }
        hosting.layoutSubtreeIfNeeded()
        if tasksEnd || tabsEnd {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(hosting)
            let scroll: NSScrollView?
            if tasksEnd {
                scroll = views.compactMap { $0 as? OverlayScrollerProbe.Probe }.first { $0.alwaysVisible }?.enclosingScrollView
            } else {
                scroll = views.compactMap { $0 as? NSScrollView }.first {
                    ($0.documentView?.bounds.width ?? 0) > $0.contentView.bounds.width + 1
                }
            }
            if let scroll, let document = scroll.documentView {
                let x = tabsEnd ? max(0, document.bounds.width - scroll.contentView.bounds.width) : 0
                let y = tasksEnd && document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
                scroll.contentView.scroll(to: NSPoint(x: x, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                hosting.layoutSubtreeIfNeeded()
                previewWindow.displayIfNeeded()
            } else {
                throw SnapshotError.bitmap
            }
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SnapshotError.bitmap }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.png }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private enum SnapshotError: Error { case bitmap, png }
}
