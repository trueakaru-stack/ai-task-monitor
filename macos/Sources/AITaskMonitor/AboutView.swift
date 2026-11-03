import SwiftUI

enum FeedbackDraft {
    static var url: URL? {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = "truea.k.a.ru@gmail.com"
        parts.queryItems = [URLQueryItem(name: "subject", value: "Отзыв или предложение об AI Task Monitor")]
        return parts.url
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
            .help("Назад к настройкам")
            .accessibilityLabel("Назад к настройкам")
            .padding(.horizontal, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("О приложении").font(.system(size: 22, weight: .semibold)).padding(.bottom, 6)
                    Text("AI task monitor · версия 0.3.0 alpha").font(.system(size: 13, weight: .semibold))
                    description("AI Task Monitor показывает активные задачи и текущее действие. Сейчас поддерживаются Codex и Claude Code.")
                    description("При нескольких источниках можно переключать задачи по вкладкам. Компактное окно остаётся поверх других и показывает до трёх задач с переключением между ними. Тему можно выбрать вручную или использовать тему macOS. Если источник недоступен, приложение сообщит об этом.")
                    description("Если задача публикует план, приложение показывает выполненные, текущий и следующие этапы. В карточке одновременно видны до пяти этапов; остальные можно прокрутить. Без плана отображается текущее действие без списка этапов.")
                    description("Точный процент показывается числом, приблизительная оценка — со знаком ≈. Если процент рассчитан по плану, он отражает долю выполненных этапов, а не всей работы. Без надёжной оценки процент скрыт.")
                    description("Диагностический журнал хранится локально. В настройках можно выбрать срок и размер хранения, просмотреть события или очистить журнал.")
                    description("Приложение может предупредить о возможном цикле при повторных ошибках одной команды. Это предположение, оно не останавливает задачу.")
                    description("Данные задач обрабатываются локально. Для Claude Code после подключения используются локальные hooks. Самому монитору не нужны вход в аккаунт, токены или права администратора.")
                    description("При запуске и раз в сутки приложение проверяет новые версии на GitHub, не отправляя данные задач. Отзыв можно написать через почтовое приложение; сообщение отправляется только по вашему решению.")
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
