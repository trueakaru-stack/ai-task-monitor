import Foundation

// Convert sanitized in-memory states into the existing task-card model.
enum ExternalProviderTaskMapper {
    static func tasks(_ states: [ExternalProviderTask]) -> [MonitoredTask] {
        states.compactMap { state in
            guard let provider = TaskProvider(rawValue: state.provider),
                  [.kimi, .deepseek, .hermes, .opencode].contains(provider),
                  ["active", "waiting", "unknown"].contains(state.status) else { return nil }
            if provider == .deepseek && state.deepSeekUnassigned {
                let raw = MonitoredTask(id: "deepseek:" + state.session, provider: .deepseek, title: "",
                    activity: "", isActive: false, progress: nil, progressKind: .none,
                    steps: [], updatedAt: state.updatedAt, isUnconfirmed: true, planConfirmed: false)
                return ExternalProfileVisibility.neutralDeepSeek(raw)
            }
            let steps = state.steps.enumerated().compactMap { index, step -> TaskStep? in
                guard let status = StepStatus(rawValue: step.status) else { return nil }
                return TaskStep(id: "\(provider.rawValue):\(state.session):step:\(index)", title: step.title, status: status)
            }
            guard steps.count == state.steps.count else { return nil }
            let progress = ([TaskProvider.opencode, .deepseek].contains(provider) && !state.planConfirmed)
                ? nil : MonitoredTask.progress(for: steps)
            let activity: String
            if state.status == "unknown" {
                activity = tr("Статус не подтверждён", "Status unconfirmed")
            } else if state.status == "waiting" {
                activity = tr("Ожидает подтверждения", "Waiting for confirmation")
            } else if state.longRunning {
                activity = tr("Долго выполняется · связь с агентом есть", "Running for a long time · agent reachable")
            } else {
                switch state.activity {
                case "command": activity = tr("Выполняет команду", "Running a command")
                case "read": activity = tr("Читает файл", "Reading a file")
                case "edit": activity = tr("Изменяет файл", "Editing a file")
                case "search": activity = tr("Выполняет поиск", "Searching")
                case "other": activity = tr("Выполняет действие", "Performing an action")
                default: activity = tr("Выполняется", "Working")
                }
            }
            let startKey = state.startKey.isEmpty ? "" : "\(provider.rawValue):\(state.session):\(state.startKey)"
            return MonitoredTask(id: "\(provider.rawValue):\(state.session)", provider: provider,
                title: tr("Задача \(provider.displayName)", "\(provider.displayName) task"), activity: activity,
                isActive: state.status == "active", progress: progress, progressKind: progress == nil ? .none : .exact,
                steps: steps, updatedAt: state.updatedAt, isUnconfirmed: state.status == "unknown",
                isWaiting: state.status == "waiting", startedAt: state.startedAt, startKey: startKey,
                planConfirmed: state.planConfirmed)
        }
    }
}
