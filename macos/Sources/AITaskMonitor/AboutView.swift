import AppKit
import SwiftUI

enum FeedbackDraft {
    static let email = "truea.k.a.ru@gmail.com"

    static var url: URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = email
        parts.queryItems = [URLQueryItem(name: "subject", value: tr("Отзыв или предложение об AI Task Monitor", "AI Task Monitor feedback or suggestion"))]
        return parts.url
    }

    static var address: AttributedString {
        var text = AttributedString(email)
        text.link = url
        return text
    }

    @discardableResult
    static func copyAddress(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(email, forType: .string)
    }
}

struct AboutView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.showsAbout = false } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(tr("Назад к настройкам", "Back to settings"))
            .accessibilityLabel(tr("Назад к настройкам", "Back to settings"))
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(tr("О приложении", "About")).font(.system(size: 22, weight: .semibold)).padding(.bottom, 6)
                    Text(tr("AI task monitor · версия \(AppVersion.display)", "AI task monitor · version \(AppVersion.display)")).font(.system(size: 13, weight: .semibold))
                    description(tr("AI Task Monitor показывает задачи и доступные сведения об их ходе. Локальные источники: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code и Hermes Agent. Для Codex также доступны облачные задачи с неподтверждённым статусом.", "AI Task Monitor shows tasks and available progress information. Local sources: Codex, Claude Code, OpenCode, DeepSeek Harness, Kimi Code and Hermes Agent. Codex cloud tasks are also available with unconfirmed status."))
                    description(tr("При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему macOS. Если источник недоступен, приложение сообщит об этом.", "When multiple sources are available, use the tabs to switch between them. The compact window stays on top and lets you switch between up to three tasks. Choose a theme or follow macOS. The app reports unavailable sources."))
                    description(tr("Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов.", "When a task publishes a plan, the app shows completed, current and upcoming steps. Up to five steps are visible at once; scroll to see the rest. Without a plan, only the current action is shown."))
                    description(tr("Если источник сообщает общий прогресс задачи, точный процент показывается числом, а приблизительный — со знаком ≈. Если известен только план, показывается текущий этап или число завершённых этапов.", "When a source reports overall task progress, an exact percentage is shown as a number and an estimate is marked ≈. If only a plan is available, the current step or completed step count is shown."))
                    description(tr("Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал.", "The diagnostic journal stays on this device. In Settings you can choose its retention period and size, view events or clear the journal."))
                    description(tr("Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу.", "The app may warn about a possible loop when one command repeatedly fails. This is a warning only and does not stop the task."))
                    description(tr("Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора.", "Task data is processed locally. Claude Code uses local hooks after connection. The monitor does not require sign-in, tokens or administrator rights."))
                    description(tr("При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.", "The app checks GitHub for updates at startup and daily without sending task data. Feedback opens in your email app and is sent only if you choose to send it."))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayScrollerProbe().frame(width: 0, height: 0))
            }
        }
    }

    private func description(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(colorScheme == .light ? MonitorTheme.primary : MonitorTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
