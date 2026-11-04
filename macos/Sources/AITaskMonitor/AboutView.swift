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
                    description(tr("AI Task Monitor показывает активные задачи и текущее действие. Сейчас поддерживаются Codex и Claude Code.", "AI Task Monitor shows active tasks and their current action. Codex and Claude Code are currently supported."))
                    description(tr("При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему macOS. Если источник недоступен, приложение сообщит об этом.", "When multiple sources are available, use the tabs to switch between them. The compact window stays on top and lets you switch between up to three tasks. Choose a theme or follow macOS. The app reports unavailable sources."))
                    description(tr("Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов.", "When a task publishes a plan, the app shows completed, current and upcoming steps. Up to five steps are visible at once; scroll to see the rest. Without a plan, only the current action is shown."))
                    description(tr("Точный процент показывается числом, приблизительная оценка — со знаком ≈. Если процент рассчитан по плану, он отражает долю выполненных этапов, а не всей работы. Без надёжной оценки процент скрыт.", "An exact percentage is shown as a number; an estimate is marked ≈. A plan percentage is the share of completed steps, not the entire task. No percentage is shown without a reliable value."))
                    description(tr("Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал.", "The diagnostic journal stays on this device. In Settings you can choose its retention period and size, view events or clear the journal."))
                    description(tr("Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу.", "The app may warn about a possible loop when one command repeatedly fails. This is a warning only and does not stop the task."))
                    description(tr("Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора.", "Task data is processed locally. Claude Code uses local hooks after connection. The monitor does not require sign-in, tokens or administrator rights."))
                    description(tr("При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.", "The app checks GitHub for updates at startup and daily without sending task data. Feedback opens in your email app and is sent only if you choose to send it."))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func description(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
