import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("languageMode") private var languageRaw = AppLanguage.system.rawValue
    @State private var confirmsJournalClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.showsSettings = false } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(tr("Назад", "Back"))
            .accessibilityLabel(tr("Назад к задачам", "Back to tasks"))
            .padding(.horizontal, 20)

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
                                Text("Claude Code").font(.system(size: 13, weight: .medium))
                                Text(sourceDescription).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 20)
                            Button(ClaudeIntegration.isConnected ? tr("Отключить", "Disconnect") : tr("Подключить", "Connect")) {
                                store.setClaudeConnected(!ClaudeIntegration.isConnected)
                            }
                            .disabled((!ClaudeIntegration.isClaudeInstalled && !ClaudeIntegration.isConnected && !claudePartiallyConnected) || (store.unavailableSources.contains(.claude) && !claudePartiallyConnected && !ClaudeIntegration.isConnected))
                        }
                        if !store.sourceMessage.isEmpty {
                            Text(store.sourceMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                        }
                    }
                    section(tr("Журнал", "Journal")) {
                        HStack {
                            Text(tr("Срок хранения", "Retention period")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Срок хранения", "Retention period"), selection: retentionDays) {
                                ForEach(1...7, id: \.self) { value in Text(dayLabel(value)).tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        HStack {
                            Text(tr("Максимальный размер", "Maximum size")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Максимальный размер", "Maximum size"), selection: maximumMB) {
                                ForEach(1...10, id: \.self) { value in Text("\(value) \(tr("МБ", "MB"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
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
                            .labelsHidden().pickerStyle(.menu).frame(width: 120).disabled(store.claudeRetentionPolicy == nil)
                        }
                        HStack {
                            Text(tr("Максимальный размер событий", "Maximum event size")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Максимальный размер событий", "Maximum event size"), selection: claudeMaximumMB) {
                                ForEach(1...100, id: \.self) { value in Text("\(value) \(tr("МБ", "MB"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120).disabled(store.claudeRetentionPolicy == nil)
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
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        HStack {
                            Text(tr("Период проверки", "Time window")).font(.system(size: 13))
                            Spacer()
                            Picker(tr("Период проверки", "Time window"), selection: loopWindowMinutes) {
                                ForEach(1...30, id: \.self) { value in Text("\(value) \(tr("мин", "min"))").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        if !store.claudeLoopError.isEmpty {
                            Text(store.claudeLoopError).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Button(tr("О приложении", "About")) { store.showsAbout = true }
                        section(tr("Отзывы и предложения", "Feedback and suggestions")) {
                            Text(FeedbackDraft.address)
                                .textSelection(.enabled)
                                .tint(.accentColor)
                                .accessibilityLabel(tr("Адрес для отзывов и предложений: \(FeedbackDraft.email)", "Feedback email address: \(FeedbackDraft.email)"))
                        }
                    }
                    .font(.system(size: 13)).buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .onChange(of: languageRaw) { _ in store.refresh() }
    }

    private var sourceDescription: String {
        if claudePartiallyConnected { return tr("Claude Code подключён частично. Нажмите «Подключить», чтобы восстановить недостающие hooks.", "Claude Code is partially connected. Select Connect to restore missing hooks.") }
        if !ClaudeIntegration.isClaudeInstalled && !ClaudeIntegration.isConnected {
            if ClaudeIntegration.installationState() == .unconfirmed { return tr("Установку Claude Code не удалось подтвердить. Проверьте доступность команды Claude Code.", "Claude Code installation could not be confirmed. Check that its command is available.") }
            return tr("Claude Code не найден. Установите его, затем вернитесь в настройки.", "Claude Code was not found. Install it, then return to Settings.")
        }
        if store.unavailableSources.contains(.claude) { return tr("Нет данных от Claude Code. Проверьте доступ к настройкам и журналу источника.", "No data from Claude Code. Check access to its settings and event log.") }
        return tr("Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Code; задачи будут появляться автоматически.", "The app adds local hooks to Claude Code settings. No administrator rights, tokens or sign-in are needed. Restart Claude Code after connecting; tasks will appear automatically.")
    }

    private var claudePartiallyConnected: Bool {
        (try? ClaudeIntegration.connectionState()) == .partial
    }

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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }
}
