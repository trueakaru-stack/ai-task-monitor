import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

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
                            .disabled(!ClaudeIntegration.isClaudeInstalled)
                        }
                        if !store.sourceMessage.isEmpty {
                            Text(store.sourceMessage).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
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
        return "Приложение добавит локальные hooks в настройки Claude Code. Права администратора, токены и вход в аккаунт не нужны. После подключения перезапустите Claude Code; задачи будут появляться автоматически."
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }
}
