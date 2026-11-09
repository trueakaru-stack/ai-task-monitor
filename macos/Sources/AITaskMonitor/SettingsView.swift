import AppKit
import SwiftUI

private struct SettingsPreviewEndKey: EnvironmentKey { static let defaultValue = false }
private struct SettingsPreviewSourcesKey: EnvironmentKey { static let defaultValue = false }
enum SettingsPreviewClaude: Equatable { case unconfirmed, connected }
enum SettingsPreviewCloud: Equatable { case disconnected, connected, error, partial }
enum SettingsPreviewKimi: Equatable { case disconnected, connected, disabled, error }
enum SettingsPreviewHermes: String, Equatable { case absent, prepared, enabled, error, unavailable }
private struct SettingsPreviewClaudeKey: EnvironmentKey { static let defaultValue: SettingsPreviewClaude? = nil }
private struct SettingsPreviewCloudKey: EnvironmentKey { static let defaultValue: SettingsPreviewCloud? = nil }
private struct SettingsPreviewKimiKey: EnvironmentKey { static let defaultValue: SettingsPreviewKimi? = nil }
private struct SettingsPreviewHermesKey: EnvironmentKey { static let defaultValue: SettingsPreviewHermes? = nil }

private struct SettingsMenuWidth: ViewModifier {
    let width: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible).frame(width: width)
        } else {
            content.frame(width: 120)
        }
        #else
        content.frame(width: 120)
        #endif
    }
}

private struct SourceProfileMenuWidth: ViewModifier {
    let width: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible).frame(maxWidth: width)
        } else {
            content.frame(maxWidth: .infinity)
        }
        #else
        content.frame(maxWidth: .infinity)
        #endif
    }
}

private struct SourceProfileActionWidths: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct SourceProfileActionWidth: ViewModifier {
    let source: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear.preference(key: SourceProfileActionWidths.self, value: [source: proxy.size.width])
        })
    }
}

extension EnvironmentValues {
    var settingsPreviewEnd: Bool {
        get { self[SettingsPreviewEndKey.self] }
        set { self[SettingsPreviewEndKey.self] = newValue }
    }
    var settingsPreviewSources: Bool {
        get { self[SettingsPreviewSourcesKey.self] }
        set { self[SettingsPreviewSourcesKey.self] = newValue }
    }
    var settingsPreviewClaude: SettingsPreviewClaude? {
        get { self[SettingsPreviewClaudeKey.self] }
        set { self[SettingsPreviewClaudeKey.self] = newValue }
    }
    var settingsPreviewCloud: SettingsPreviewCloud? {
        get { self[SettingsPreviewCloudKey.self] }
        set { self[SettingsPreviewCloudKey.self] = newValue }
    }
    var settingsPreviewKimi: SettingsPreviewKimi? {
        get { self[SettingsPreviewKimiKey.self] }
        set { self[SettingsPreviewKimiKey.self] = newValue }
    }
    var settingsPreviewHermes: SettingsPreviewHermes? {
        get { self[SettingsPreviewHermesKey.self] }
        set { self[SettingsPreviewHermesKey.self] = newValue }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("languageMode") private var languageRaw = AppLanguage.system.rawValue
    @State private var confirmsJournalClear = false
    @State private var feedbackCopyError = false
    @State private var kimiCopyError = false
    @State private var settingsMenuWidth: CGFloat = 120
    @State private var sourceProfileMenuWidth: CGFloat = 120
    @State private var sourceProfileActionWidths: [String: CGFloat] = [:]
    @Environment(\.settingsPreviewEnd) private var settingsPreviewEnd
    @Environment(\.settingsPreviewSources) private var settingsPreviewSources
    @Environment(\.settingsPreviewClaude) private var settingsPreviewClaude
    @Environment(\.settingsPreviewCloud) private var settingsPreviewCloud
    @Environment(\.settingsPreviewKimi) private var settingsPreviewKimi
    @Environment(\.settingsPreviewHermes) private var settingsPreviewHermes

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.showsSettings = false } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(tr("Назад", "Back"))
            .accessibilityLabel(tr("Назад к задачам", "Back to tasks"))
            .padding(.horizontal, 20)

            ScrollViewReader { scrollProxy in
             ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text(tr("Настройки", "Settings")).font(.system(size: 22, weight: .semibold))
                    section(tr("Внешний вид", "Appearance")) {
                        Picker(tr("Тема", "Theme"), selection: $appearanceRaw) {
                            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section(tr("Язык", "Language")) {
                        Picker(tr("Язык", "Language"), selection: $languageRaw) {
                            ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section(tr("Источники", "Sources")) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Codex Cloud").font(.system(size: 13, weight: .medium))
                                Text(tr("Использует установленный Codex, его вход в аккаунт и интернет. Статус облачных задач может быть неподтверждённым.", "Uses the installed Codex, its signed-in account and the internet. Cloud task status may be unconfirmed."))
                                    .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                if cloudFailed {
                                    Text(tr("Не удалось получить облачные задачи. Проверьте установку Codex, вход и интернет.", "Could not retrieve cloud tasks. Check the Codex installation, sign-in and internet connection."))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                } else if cloudPartial {
                                    Text(tr("Показаны не все облачные задачи.", "Not all cloud tasks are shown."))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 20)
                            Button(cloudEnabled ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) {
                                if settingsPreviewCloud == nil { store.setCodexCloudEnabled(!cloudEnabled) }
                            }
                            .accessibilityLabel((cloudEnabled ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) + " Codex Cloud")
                        }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Claude Code").font(.system(size: 13, weight: .medium))
                                Text(sourceDescription).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 20)
                            Button(claudeConnection == .connected ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) {
                                if settingsPreviewClaude == nil { store.setClaudeConnected(claudeConnection != .connected) }
                            }
                            .disabled(!ClaudeIntegration.canChangeConnection(installation: claudeInstallation, connection: claudeConnection, sourceUnavailable: store.unavailableSources.contains(.claude)))
                        }
                        if !store.sourceMessage.isEmpty {
                            Text(store.sourceMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                        }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("OpenCode").font(.system(size: 13, weight: .medium))
                                Text(tr("Приложение добавит локальный плагин OpenCode. Поддерживаются совместимые версии 1 начиная с 1.18.29 и версия 2. После подключения перезапустите OpenCode.", "The app adds a local OpenCode plugin. Compatible versions 1.18.29 and later within version 1, and version 2, are supported. Restart OpenCode after connecting."))
                                    .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                if openCodeState == .connected {
                                    Text(tr("После запуска монитора полностью перезапустите OpenCode и нажмите «Агент перезапущен». Статусы пока остаются неподтверждёнными. Если кнопка недоступна, переподключите источник.", "After starting the monitor, fully restart OpenCode and select ‘Agent restarted’. Statuses remain unconfirmed for now. If the button is unavailable, reconnect the source."))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                    if store.externalV2Failed {
                                        Text(tr("Канал недоступен. Перезапустите монитор и агент.", "Channel unavailable. Restart the monitor and the agent."))
                                            .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                if openCodeState == nil {
                                    Text(tr("Не удалось прочитать подключение OpenCode", "Could not read the OpenCode connection"))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                } else if !openCodePresent && openCodeState == .disconnected {
                                    Text(tr("Установка не подтверждена", "Installation unconfirmed"))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                }
                            }
                            Spacer(minLength: 20)
                            VStack(alignment: .trailing, spacing: 5) {
                                Button(openCodeState == .connected || openCodeState == .partial ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) {
                                    store.setOpenCodeConnected(openCodeState == .disconnected)
                                }
                                .disabled(openCodeState == nil || store.openCodeSetupInProgress || (!openCodePresent && openCodeState == .disconnected))
                                if openCodeState == .connected {
                                    Button(tr("Агент перезапущен", "Agent restarted")) { store.acknowledgeOpenCodeRestart() }
                                        .disabled(!store.openCodeRestartAvailable)
                                }
                            }
                        }
                        if !store.openCodeMessage.isEmpty {
                            Text(store.openCodeMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Kimi Code").font(.system(size: 13, weight: .medium))
                                Text(tr("Для локальных задач Kimi Code CLI 2.5.0, установленного через npm: скопируйте путь, откройте в Kimi меню /plugins и установите плагин через Custom. Затем выполните /reload или откройте новую сессию. Статус задач не подтверждён; завершённые задачи могут оставаться в списке. Отключение выполняется в меню Kimi.", "For local tasks in Kimi Code CLI 2.5.0 installed via npm: copy the path, open /plugins in Kimi and install the plugin through Custom. Then run /reload or open a new session. Task status is unconfirmed; finished tasks may remain listed. Disable the plugin in Kimi."))
                                    .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                Text(kimiStatusMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                if kimiCopyError {
                                    Text(tr("Не удалось скопировать путь.", "Could not copy the path."))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                }
                            }
                            Spacer(minLength: 20)
                            Button(tr("Скопировать путь", "Copy path")) {
                                guard settingsPreviewKimi == nil, let directory = KimiIntegration.pluginDirectory() else { return }
                                NSPasteboard.general.clearContents()
                                kimiCopyError = !NSPasteboard.general.setString(directory.path, forType: .string)
                            }
                            .disabled(settingsPreviewKimi == .error || (settingsPreviewKimi == nil && !store.kimiCanCopyPath))
                            .accessibilityLabel(tr("Скопировать путь Kimi Code", "Copy Kimi Code path"))
                        }
                        .id("settings-kimi")
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("DeepSeek Harness").font(.system(size: 13, weight: .medium))
                                    Text(tr("Подключение проверено с DeepSeek Harness 0.2.1-rc.5 и pnpm 11.25.0. Приложение добавит локальный плагин в выбранный профиль. После подключения перезапустите DeepSeek Harness.", "Connection has been tested with DeepSeek Harness 0.2.1-rc.5 and pnpm 11.25.0. The app adds a local plugin to the selected profile. Restart DeepSeek Harness after connecting."))
                                        .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                    if store.deepSeekSelectedProfile?.state == "connected" {
                                        Text(tr("После запуска монитора полностью перезапустите выбранный профиль и нажмите «Агент перезапущен». Если кнопка недоступна, переподключите профиль.", "After starting the monitor, fully restart the selected profile and select ‘Agent restarted’. If the button is unavailable, reconnect the profile."))
                                            .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                        if store.externalV2Failed {
                                            Text(tr("Канал недоступен. Перезапустите монитор и агент.", "Channel unavailable. Restart the monitor and the agent."))
                                                .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Text(store.deepSeekStatusMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                }
                                Spacer(minLength: 20)
                                VStack(alignment: .trailing, spacing: 5) {
                                    Button(["connected", "partial"].contains(store.deepSeekSelectedProfile?.state ?? "") ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) {
                                        store.setDeepSeekConnected(store.deepSeekSelectedProfile?.state == "disconnected")
                                    }
                                    .modifier(SourceProfileActionWidth(source: "deepSeek"))
                                    .disabled(!store.deepSeekCanChange && !(settingsPreviewSources && store.deepSeekSelectedProfile?.state != "error"))
                                    if store.deepSeekSelectedProfile?.state == "connected" {
                                        Button(tr("Агент перезапущен", "Agent restarted")) { store.acknowledgeDeepSeekRestart() }
                                            .disabled(!store.deepSeekRestartAvailable)
                                    }
                                }
                            }
                            sourceProfileRow {
                                Picker(tr("Профиль", "Profile"), selection: $store.selectedDeepSeekProfile) {
                                    Text(tr("Выберите профиль", "Select a profile")).tag("")
                                    ForEach(store.deepSeekProfiles) { profile in Text(profile.name).tag(profile.name) }
                                }
                                .disabled(store.deepSeekProfiles.isEmpty || store.deepSeekSetupInProgress)
                                .accessibilityLabel(tr("Профиль DeepSeek Harness", "DeepSeek Harness profile"))
                            }
                        }
                        if !store.deepSeekMessage.isEmpty {
                            Text(store.deepSeekMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Hermes Agent").font(.system(size: 13, weight: .medium))
                                    Text(tr("Проверено с исходной установкой Hermes Agent v0.22.7. Выберите профиль и подготовьте плагин. Полностью закройте Hermes и его фоновые службы, затем выполните команду включения в терминале. Перед запуском менеджера команда локально проверяет файлы .env, которые могут содержать ключи; сама проверка не сохраняет, не выводит и не передаёт их. После запуска монитора или повторного подключения источника дождитесь статуса «Плагин включён в локальных настройках», затем запустите или перезапустите Hermes. Прежние задачи не показываются. Для отключения снова закройте Hermes и его фоновые службы и выполните команду отключения.", "Tested with a source installation of Hermes Agent v0.22.7. Select a profile and prepare the plugin. Fully close Hermes and its background services, then run the enable command in Terminal. Before starting the manager, the command checks local .env files that may contain keys; the check itself does not save, display or transmit them. After starting the monitor or reconnecting the source, wait for ‘Plugin enabled in local settings’, then start or restart Hermes. Previous tasks are not shown. To disable, close Hermes and its background services again, then run the disable command."))
                                        .font(.system(size: 11.5)).foregroundStyle(colorScheme == .light ? MonitorTheme.primary : MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                    Text(store.hermesStatusMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 20)
                                Button(tr("Подготовить", "Prepare")) {
                                    if settingsPreviewHermes == nil { store.prepareHermes() }
                                }
                                .modifier(SourceProfileActionWidth(source: "hermes"))
                                .disabled(!store.hermesCanPrepare)
                                .accessibilityLabel(tr("Подготовить плагин Hermes Agent", "Prepare Hermes Agent plugin"))
                            }
                            sourceProfileRow {
                                Picker(tr("Профиль", "Profile"), selection: $store.selectedHermesProfile) {
                                    Text(tr("Выберите профиль", "Select a profile")).tag("")
                                    ForEach(store.hermesProfiles) { profile in
                                        Text(profile.id == "root" ? tr("По умолчанию", "Default") : profile.name).tag(profile.id)
                                    }
                                }
                                .disabled(store.hermesProfiles.isEmpty || store.hermesSetupInProgress || store.hermesScanInProgress)
                                .accessibilityLabel(tr("Профиль Hermes Agent", "Hermes Agent profile"))
                            }
                            if let enable = store.hermesEnableCommand, let disable = store.hermesDisableCommand {
                                HStack(spacing: 0) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(tr("Включение:", "Enable:"))
                                            .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                        Text(enable).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        Text(tr("Отключение:", "Disable:"))
                                            .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                        Text(disable).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer().frame(width: (sourceProfileActionWidths["hermes"] ?? 0) + 20)
                                }
                            }
                        }
                        .id("settings-hermes")
                        if !store.hermesMessage.isEmpty {
                            Text(store.hermesMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .id("settings-sources")
                    section(tr("Журнал", "Journal")) {
                        HStack {
                            Text(tr("Срок хранения", "Retention period")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Срок хранения", "Retention period"), selection: retentionDays) {
                                ForEach(1...7, id: \.self) { value in Text(dayLabel(value)).tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth))
                        }
                        HStack {
                            Text(tr("Максимальный размер", "Maximum size")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Максимальный размер", "Maximum size"), selection: maximumMB) {
                                ForEach(1...10, id: \.self) { value in Text("\(value) \(tr("МБ", "MB"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth))
                        }
                        HStack {
                            Button(tr("Открыть журнал", "Open journal")) { store.openJournal() }
                            if !confirmsJournalClear {
                                Button(tr("Очистить", "Clear")) { confirmsJournalClear = true }
                            }
                        }
                        if confirmsJournalClear {
                            Text(tr("Очистить диагностический журнал?", "Clear the diagnostic journal?"))
                                .font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
                            HStack {
                                Button(tr("Очистить журнал", "Clear journal"), role: .destructive) { store.clearJournal(); confirmsJournalClear = false }
                                Button(tr("Отмена", "Cancel")) { confirmsJournalClear = false }
                            }
                        }
                        if !store.journalError.isEmpty {
                            Text(store.journalError).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section(tr("Хранение Claude Code", "Claude Code storage")) {
                        HStack {
                            Text(tr("Срок хранения событий", "Event retention period")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Срок хранения событий", "Event retention period"), selection: claudeRetentionDays) {
                                ForEach(1...30, id: \.self) { value in Text(dayLabel(value)).tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth)).disabled(store.claudeRetentionPolicy == nil)
                        }
                        HStack {
                            Text(tr("Максимальный размер событий", "Maximum event size")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Максимальный размер событий", "Maximum event size"), selection: claudeMaximumMB) {
                                ForEach(1...100, id: \.self) { value in Text("\(value) \(tr("МБ", "MB"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth)).disabled(store.claudeRetentionPolicy == nil)
                        }
                        Text(tr("События очищаются автоматически. Резервные копии настроек хранятся 30 дней; последняя сохраняется.", "Events are cleaned automatically. Settings backups are kept for 30 days; the most recent is retained."))
                            .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        if store.claudeRetentionPolicy == nil || store.claudeRetentionFailed {
                            Text(store.claudeRetentionPolicy == nil ? tr("Настройки хранения Claude Code повреждены", "Claude Code storage settings are invalid") : tr("Не удалось очистить данные Claude Code", "Could not clean Claude Code data"))
                                .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section(tr("Возможный цикл", "Possible loop")) {
                        HStack {
                            Text(tr("Количество повторов", "Repeat count")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Количество повторов", "Repeat count"), selection: loopThreshold) {
                                ForEach(3...10, id: \.self) { value in Text("\(value)").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth))
                        }
                        HStack {
                            Text(tr("Период проверки", "Time window")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Период проверки", "Time window"), selection: loopWindowMinutes) {
                                ForEach(1...30, id: \.self) { value in Text("\(value) \(tr("мин", "min"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).modifier(SettingsMenuWidth(width: settingsMenuWidth))
                        }
                        if !store.claudeLoopError.isEmpty {
                            Text(store.claudeLoopError).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Button(tr("О приложении", "About")) { store.showsAbout = true }
                        section(tr("Отзывы и предложения", "Feedback and suggestions")) {
                            // Centering the 17 pt symbol in 28 pt preserves the original 16 pt gap.
                            HStack(spacing: 10.5) {
                                Text(FeedbackDraft.address)
                                    .textSelection(.enabled)
                                    .tint(.accentColor)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel(tr("Адрес для отзывов и предложений: \(FeedbackDraft.email)", "Feedback email address: \(FeedbackDraft.email)"))
                                Button { feedbackCopyError = !FeedbackDraft.copyAddress() } label: {
                                    Image(systemName: "doc.on.doc")
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                        .foregroundStyle(MonitorTheme.secondary)
                                }
                                .accessibilityLabel(tr("Скопировать адрес", "Copy email address"))
                                Spacer(minLength: 0)
                            }
                            if feedbackCopyError {
                                Text(tr("Не удалось скопировать адрес. Выделите его и скопируйте вручную.", "Could not copy the address. Select and copy it manually."))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(MonitorTheme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.system(size: 13)).buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(OverlayScrollerProbe().frame(width: 0, height: 0))
                .id("feedback-end")
             }
             .onAppear {
                 if settingsPreviewEnd || settingsPreviewSources || settingsPreviewKimi != nil || settingsPreviewHermes != nil {
                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                         if settingsPreviewEnd { scrollProxy.scrollTo("feedback-end", anchor: .bottom) }
                         else if settingsPreviewHermes != nil { scrollProxy.scrollTo("settings-hermes", anchor: .top) }
                         else if settingsPreviewKimi != nil { scrollProxy.scrollTo("settings-kimi", anchor: .top) }
                         else { scrollProxy.scrollTo("settings-sources", anchor: .top) }
                     }
                 }
             }
            }
        }
        .controlSize(.large)
        .background(alignment: .topLeading) {
            HStack(spacing: 0) {
                Button(tr("Подключить", "Connect")) { }
                    .modifier(SourceProfileActionWidth(source: "deepSeekConnectMeasurement"))
                Button(tr("Отключить", "Disconnect")) { }
                    .modifier(SourceProfileActionWidth(source: "deepSeekDisconnectMeasurement"))
            }
            .fixedSize()
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .controlSize(.large)
        }
        .onAppear { refreshSettingsMenuWidth(); refreshSourceProfileMenuWidth() }
        .onPreferenceChange(SourceProfileActionWidths.self) { sourceProfileActionWidths = $0 }
        .onChange(of: store.deepSeekProfiles.map(\.name)) { _ in refreshSourceProfileMenuWidth() }
        .onChange(of: store.hermesProfiles.map { $0.id + "|" + $0.name }) { _ in refreshSourceProfileMenuWidth() }
        .onChange(of: languageRaw) { _ in
            refreshSettingsMenuWidth()
            refreshSourceProfileMenuWidth()
            store.refresh()
        }
    }

    private func sourceProfileRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(tr("Профиль", "Profile")).font(.system(size: 13))
            Spacer().frame(width: 8)
            content()
                .labelsHidden()
                .modifier(SourceProfileMenuWidth(width: sourceProfileMenuWidth))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: (sourceProfileActionWidths.values.min() ?? 0) + 20)
        }
    }

    private func refreshSourceProfileMenuWidth() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let placeholder = tr("Выберите профиль", "Select a profile")
            let deepSeek = [placeholder] + store.deepSeekProfiles.map(\.name)
            let hermes = [placeholder] + store.hermesProfiles.map { $0.id == "root" ? tr("По умолчанию", "Default") : $0.name }
            let widest = [deepSeek, hermes].map { titles -> CGFloat in
                let control = NSPopUpButton(frame: .zero, pullsDown: false)
                control.controlSize = .large
                control.addItems(withTitles: titles)
                return control.fittingSize.width
            }.max() ?? 0
            if widest.isFinite && widest > 0 { sourceProfileMenuWidth = widest }
        }
        #endif
    }

    private var sourceDescription: String {
        Self.claudeSourceDescription(connection: claudeConnection, installation: claudeInstallation,
                                     sourceUnavailable: store.unavailableSources.contains(.claude))
    }

    static func claudeSourceDescription(connection: ClaudeIntegration.ConnectionState?,
                                        installation: ClaudeIntegration.InstallationState,
                                        sourceUnavailable: Bool) -> String {
        let requirement = tr(
            "Перед подключением или отключением закройте Claude Code, Claude Desktop и другие программы, которые меняют настройки Claude. Обновите все используемые копии Claude Code, в том числе в Claude Desktop, до версии 2.1.101 или новее. Приложение не проверяет закрытие программ и версии автоматически.",
            "Before connecting or disconnecting, close Claude Code, Claude Desktop, and any other apps that modify Claude settings. Update all copies of Claude Code you use, including those in Claude Desktop, to version 2.1.101 or later. The app does not automatically check whether apps are closed or versions are up to date."
        )
        let details: String
        if connection == nil {
            details = tr("Не удалось прочитать настройки Claude Code.", "Could not read Claude Code settings.")
        } else if connection == .partial {
            details = tr("Claude Code подключён частично. Нажмите «Подключить», чтобы восстановить недостающие hooks.", "Claude Code is partially connected. Select Connect to restore missing hooks.")
        } else if connection == .disconnected && installation != .available {
            if installation == .unconfirmed {
                details = tr("Команда Claude Code не найдена. Для локальных сессий нажмите «Подключить» и перезапустите Claude Desktop или Claude Code.", "The Claude Code command was not found. For local sessions, select Connect and restart Claude Desktop or Claude Code.")
            } else {
                details = tr("Claude Code не найден. Установите его, затем вернитесь в настройки.", "Claude Code was not found. Install it, then return to Settings.")
            }
        } else if sourceUnavailable {
            details = tr("Нет данных от Claude Code. Проверьте доступ к настройкам и журналу источника.", "No data from Claude Code. Check access to its settings and event log.")
        } else {
            details = tr("Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Desktop или Claude Code. Пока отслеживаются только локальные сессии.", "The app adds local hooks to Claude Code settings. No administrator rights, tokens or sign-in are needed. Restart Claude Desktop or Claude Code after connecting. Only local sessions are monitored for now.")
        }
        return requirement + " " + details
    }

    private var cloudEnabled: Bool {
        guard let preview = settingsPreviewCloud else { return store.codexCloudEnabled }
        return preview != .disconnected
    }

    private var cloudFailed: Bool { settingsPreviewCloud == nil ? store.codexCloudFailed : settingsPreviewCloud == .error }
    private var cloudPartial: Bool { settingsPreviewCloud == nil ? store.codexCloudPartial : settingsPreviewCloud == .partial }

    private var kimiStatusMessage: String {
        switch settingsPreviewKimi {
        case .disconnected: return tr("Плагин не установлен", "Plugin not installed")
        case .connected: return tr("Плагин включён", "Plugin enabled")
        case .disabled: return tr("Плагин отключён", "Plugin disabled")
        case .error: return tr("Не удалось проверить плагин Kimi Code.", "Could not check the Kimi Code plugin.")
        case nil: return store.kimiStatusMessage
        }
    }

    private var claudeInstallation: ClaudeIntegration.InstallationState {
        settingsPreviewClaude == nil ? ClaudeIntegration.installationState() : .unconfirmed
    }

    private var claudeConnection: ClaudeIntegration.ConnectionState? {
        if settingsPreviewClaude == .unconfirmed { return .disconnected }
        if settingsPreviewClaude == .connected { return .connected }
        return try? ClaudeIntegration.connectionState()
    }

    private var openCodeState: OpenCodeIntegration.State? { try? OpenCodeIntegration.state() }
    private var openCodePresent: Bool { OpenCodeIntegration.hasPotentialInstallation() }

    private var retentionDays: Binding<Int> {
        Binding(get: { store.diagnosticSettings.retentionDays }, set: { value in
            var settings = store.diagnosticSettings
            settings.retentionDays = value
            store.setDiagnosticSettings(settings)
        })
    }

    private var maximumMB: Binding<Int> {
        Binding(get: { store.diagnosticSettings.maximumMB }, set: { value in
            var settings = store.diagnosticSettings
            settings.maximumMB = value
            store.setDiagnosticSettings(settings)
        })
    }

    private var loopThreshold: Binding<Int> {
        Binding(get: { store.diagnosticSettings.loopThreshold }, set: { value in
            var settings = store.diagnosticSettings
            settings.loopThreshold = value
            store.setDiagnosticSettings(settings)
        })
    }

    private var claudeRetentionDays: Binding<Int> {
        Binding(get: { store.claudeRetentionPolicy?.days ?? 7 }, set: { store.setClaudeRetention(days: $0) })
    }

    private var claudeMaximumMB: Binding<Int> {
        Binding(get: { store.claudeRetentionPolicy?.maximumMB ?? 10 }, set: { store.setClaudeRetention(maximumMB: $0) })
    }

    private var loopWindowMinutes: Binding<Int> {
        Binding(get: { store.diagnosticSettings.loopWindowMinutes }, set: { value in
            var settings = store.diagnosticSettings
            settings.loopWindowMinutes = value
            store.setDiagnosticSettings(settings)
        })
    }

    private func dayLabel(_ value: Int) -> String {
        if AppLanguage.current == .en { return "\(value) " + (value == 1 ? "day" : "days") }
        let last = value % 10, lastTwo = value % 100
        return "\(value) " + ((11...14).contains(lastTwo) ? "дней" : last == 1 ? "день" : (2...4).contains(last) ? "дня" : "дней")
    }

    private func refreshSettingsMenuWidth() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let groups: [[String]] = [
                (1...7).map(dayLabel),
                (1...10).map { "\($0) \(tr("МБ", "MB"))" },
                (1...30).map(dayLabel),
                (1...100).map { "\($0) \(tr("МБ", "MB"))" },
                (3...10).map { "\($0)" },
                (1...30).map { "\($0) \(tr("мин", "min"))" }
            ]
            let widest = groups.map { titles in
                let control = NSPopUpButton(frame: .zero, pullsDown: false)
                control.controlSize = .large
                control.addItems(withTitles: titles)
                return control.fittingSize.width
            }.max() ?? 0
            settingsMenuWidth = widest.isFinite && widest > 0 ? widest : 120
        }
        #endif
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }
}
