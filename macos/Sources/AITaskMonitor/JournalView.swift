import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var selectedTask = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { store.showsJournal = false } label: {
                Image(systemName: "arrow.left").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Назад")
            .accessibilityLabel("Назад к настройкам")
            .padding(.horizontal, 20)

            Text("Журнал")
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)

            Picker("Задача", selection: $selectedTask) {
                Text("Все задачи").tag("")
                ForEach(taskOptions) { option in Text(option.title).tag(option.id) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 20)
            .padding(.top, 16)

            if !store.journalError.isEmpty {
                Text(store.journalError)
                    .font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
                    .padding(.horizontal, 20).padding(.top, 12)
            }

            if visibleEvents.isEmpty {
                Spacer()
                Text("Событий пока нет")
                    .font(.system(size: 13)).foregroundStyle(MonitorTheme.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleEvents) { event in
                            HStack(alignment: .top, spacing: 12) {
                                Text(Self.timeFormatter.string(from: event.time))
                                    .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                                    .frame(width: 94, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.type.title).font(.system(size: 12.5))
                                    Text(event.source.displayName).font(.system(size: 11)).foregroundStyle(MonitorTheme.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 9)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
        .onChange(of: store.journalEvents) { _ in
            if !selectedTask.isEmpty && !taskOptions.contains(where: { $0.id == selectedTask }) { selectedTask = "" }
        }
    }

    private var visibleEvents: [DiagnosticEvent] {
        store.journalEvents.reversed().filter { selectedTask.isEmpty || $0.task == selectedTask }
    }

    private var taskOptions: [TaskOption] {
        var seen: Set<String> = []
        var options: [TaskOption] = []
        for event in store.journalEvents.reversed() {
            guard let key = event.task, seen.insert(key).inserted else { continue }
            let title = store.journalTaskNames[key] ?? "\(event.source.displayName) · задача \(options.count + 1)"
            options.append(TaskOption(id: key, title: title))
        }
        return options
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm:ss"
        return formatter
    }()

    private struct TaskOption: Identifiable {
        let id: String
        let title: String
    }
}
