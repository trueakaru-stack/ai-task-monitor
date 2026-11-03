import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var confirmsJournalClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.showsSettings = false } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Назад")
            .accessibilityLabel("Назад к задачам")
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Настройки").font(.system(size: 22, weight: .semibold))
                    section("Внешний вид") {
                        Picker("Тема", selection: $appearanceRaw) {
                            ForEach(AppearanceMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                        }
                        .pickerStyle(.segmented)
                    }
                    section("Источники") {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Claude Code").font(.system(size: 13, weight: .medium))
                                Text(sourceDescription).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 20)
                            Button(ClaudeIntegration.isConnected ? "Отключить" : "Подключить") {
                                store.setClaudeConnected(!ClaudeIntegration.isConnected)
                            }
                            .disabled(!ClaudeIntegration.isClaudeInstalled || store.unavailableSources.contains(.claude))
                        }
                        if !store.sourceMessage.isEmpty {
                            Text(store.sourceMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                        }
                    }
                    section("Журнал") {
                        HStack {
                            Text("Срок хранения").font(.system(size: 13))
                            Spacer()
                            Picker("Срок хранения", selection: retentionDays) {
                                ForEach(1...7, id: \.self) { value in Text(dayLabel(value)).tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        HStack {
                            Text("Максимальный размер").font(.system(size: 13))
                            Spacer()
                            Picker("Максимальный размер", selection: maximumMB) {
                                ForEach(1...10, id: \.self) { value in Text("\(value) МБ").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        HStack {
                            Button("Открыть журнал") { store.openJournal() }
                            if !confirmsJournalClear {
                                Button("Очистить") { confirmsJournalClear = true }
                            }
                        }
                        if confirmsJournalClear {
                            Text("Очистить диагностический журнал?")
                                .font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
                            HStack {
                                Button("Очистить журнал", role: .destructive) { store.clearJournal(); confirmsJournalClear = false }
                                Button("Отмена") { confirmsJournalClear = false }
                            }
                        }
                        if !store.journalError.isEmpty {
                            Text(store.journalError).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Возможный цикл") {
                        HStack {
                            Text("Количество повторов").font(.system(size: 13))
                            Spacer()
                            Picker("Количество повторов", selection: loopThreshold) {
                                ForEach(3...10, id: \.self) { value in Text("\(value)").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        HStack {
                            Text("Период проверки").font(.system(size: 13))
                            Spacer()
                            Picker("Период проверки", selection: loopWindowMinutes) {
                                ForEach(1...30, id: \.self) { value in Text("\(value) мин").tag(value) }
                            }
                            .labelsHidden().pickerStyle(.menu).frame(width: 120)
                        }
                        if !store.claudeLoopError.isEmpty {
                            Text(store.claudeLoopError).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("О приложении") {
                        Text("AI Task Monitor показывает активные локальные задачи Codex и Claude Code, текущие действия и опубликованные этапы плана. Точный процент отображается только по известным этапам; приблизительная оценка отмечается знаком ≈; без надёжных данных процент скрыт.")
                            .font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Данные задач остаются на этом Mac. Приложение не требует прав администратора, токенов или входа в аккаунт.")
                            .font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Версия 0.3.0 alpha").font(.system(size: 11.5)).foregroundStyle(MonitorTheme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
    }

    private var sourceDescription: String {
        if !ClaudeIntegration.isClaudeInstalled { return "Claude Code не найден. Установите его, затем вернитесь в настройки." }
        if store.unavailableSources.contains(.claude) { return "Нет данных от Claude Code. Проверьте доступ к настройкам и журналу источника." }
        return "Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Code; задачи будут появляться автоматически."
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

    private var loopWindowMinutes: Binding<Int> {
        Binding(get: { store.diagnosticSettings.loopWindowMinutes }, set: { value in
            var settings = store.diagnosticSettings
            settings.loopWindowMinutes = value
            store.setDiagnosticSettings(settings)
        })
    }

    private func dayLabel(_ value: Int) -> String {
        "\(value) " + (value == 1 ? "день" : (2...4).contains(value) ? "дня" : "дней")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }
}
