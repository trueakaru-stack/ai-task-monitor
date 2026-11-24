import AppKit
import SwiftUI

struct TaskCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let task: MonitoredTask
    let showProvider: Bool

    private var hidesUnconfirmedPlanStatus: Bool {
        !task.planConfirmed || task.isUnconfirmed
    }

    private var hidesUnconfirmedProgress: Bool {
        if task.isUnconfirmed { return true }
        guard !task.planConfirmed else { return false }
        let basis = task.progressBasis ?? (task.steps.isEmpty ? .task : .steps)
        return task.provider == .claude || basis == .steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showProvider {
                Text(task.provider.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if task.codexAgentCountAtTitle {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        TruncatingText(text: task.title, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
                            .frame(maxWidth: measuredTaskLabelWidth(task.title, font: .systemFont(ofSize: 16, weight: .semibold)), minHeight: 20, alignment: .leading)
                        CodexAgentDisclosureButton(task: task, compact: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TruncatingText(text: task.title, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
                        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                }
                if let label = task.progressLabel, !hidesUnconfirmedProgress {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if !task.displayedActivity.isEmpty {
                ActivityStatusRow(text: task.displayedActivity, isActive: task.isActive, fontSize: 12)
                    .padding(.top, 4)
            }
            if let status = task.codexAgentStatusLabel {
                Text(status).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                    .padding(.top, 4)
            }
            if let agents = task.codexAgents, !agents.isEmpty {
                CodexAgentList(task: task, agents: agents, compact: false)
            }
            if task.loopWarning != nil {
                LoopWarningView(task: task, compact: false).padding(.top, 8)
            }
            if let progress = task.progress, task.progressKind != .none, !hidesUnconfirmedProgress {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MonitorTheme.track).frame(height: 3)
                        Capsule().fill(Color.accentColor).frame(width: proxy.size.width * CGFloat(progress) / 100, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.top, 16)
            }
            if !task.steps.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(task.steps) { step in
                            HStack(spacing: 9) {
                                if task.provider == .claude && hidesUnconfirmedPlanStatus {
                                    // An empty pending circle is itself a status claim.
                                    Color.clear.frame(width: 14, height: 16).accessibilityHidden(true)
                                } else {
                                    StepMark(status: hidesUnconfirmedPlanStatus ? .pending : step.status)
                                }
                                if task.activeAgentPlanStepIndex != nil, step.status == .active,
                                   task.codexAgentCountLabel(includingStatus: false) != nil {
                                    HStack(spacing: 0) {
                                        TruncatingText(text: step.title, font: .systemFont(ofSize: 12), color: .labelColor)
                                            .frame(maxWidth: measuredTaskLabelWidth(step.title, font: .systemFont(ofSize: 12)), minHeight: 16, alignment: .leading)
                                        CodexAgentDisclosureButton(task: task, compact: false, fontSize: 12)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    TruncatingText(text: step.title, font: .systemFont(ofSize: 12), color: !hidesUnconfirmedPlanStatus && step.status == .active ? .labelColor : .secondaryLabelColor)
                                        .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                                }
                            }
                        }
                    }
                    .background(OverlayScrollerProbe().frame(width: 0, height: 0))
                }
                .frame(height: 116)
                .padding(.top, 16)
                Text("\(task.planStatusNote ?? tr("План задачи", "Task plan")) · \(task.stepCountLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(task.planStatusNote == nil ? MonitorTheme.muted :
                                     (colorScheme == .light ? MonitorTheme.primary : MonitorTheme.secondary))
                    .padding(.top, 14)
            }
        }
        .padding(16)
        .background(Squircle().fill(MonitorTheme.raised))
        .overlay(Squircle().stroke(MonitorTheme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(task.provider.displayName), \(task.title)")
    }
}

struct CodexAgentDisclosureButton: View {
    @EnvironmentObject private var store: TaskStore
    let task: MonitoredTask
    let compact: Bool
    var fontSize: CGFloat = 16

    var body: some View {
        if let label = task.codexAgentCountLabel(includingStatus: false) {
            Button { store.toggleCodexGroup(task.id) } label: {
                HStack(spacing: 4) {
                    Text(" " + label).font(.system(size: fontSize, weight: .semibold)).lineLimit(1)
                    Image(systemName: store.isCodexGroupExpanded(task.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(PointingHandCursor())
            .accessibilityLabel(store.isCodexGroupExpanded(task.id)
                ? tr("Скрыть помощников задачи: \(task.title)", "Hide task assistants: \(task.title)")
                : tr("Показать помощников задачи: \(task.title)", "Show task assistants: \(task.title)"))
            .accessibilityValue(label)
        }
    }
}

struct CodexAgentList: View {
    @EnvironmentObject private var store: TaskStore
    let task: MonitoredTask
    let agents: [CodexAgentDetail]
    let compact: Bool

    var body: some View {
        if store.isCodexGroupExpanded(task.id) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(agents) { agent in
                        VStack(alignment: .leading, spacing: 2) {
                            TruncatingText(text: agent.title, font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
                                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                            if agent.isUnconfirmed {
                                Text(tr("Статус не подтверждён", "Status unconfirmed"))
                                    .font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                            }
                            if !agent.activity.isEmpty && agent.activity != "Статус не подтверждён" && agent.activity != "Status unconfirmed" {
                                let text = agent.isUnconfirmed ? tr("Последнее: ", "Last: ") + agent.activity : agent.activity
                                ActivityStatusRow(text: text, isActive: agent.isActive, fontSize: compact ? 11.5 : 12)
                            }
                            if let warning = agent.loopWarning {
                                LoopWarningView(task: MonitoredTask(id: agent.id, provider: .codex, title: agent.title,
                                    activity: agent.activity, isActive: agent.isActive, progress: nil, progressKind: .none,
                                    steps: [], updatedAt: .distantPast, loopWarning: warning), compact: compact)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OverlayScrollerProbe(alwaysVisible: true).frame(width: 0, height: 0))
            }
            .frame(height: min(CGFloat(agents.count) * 60, 180))
            .padding(.top, 12)
        }
    }
}

struct LoopWarningView: View {
    @EnvironmentObject private var store: TaskStore
    let task: MonitoredTask
    let compact: Bool

    var body: some View {
        if let warning = task.loopWarning {
            HStack(alignment: .top, spacing: 8) {
                Text(warning.description)
                    .font(.system(size: compact ? 11.5 : 12))
                    .foregroundStyle(MonitorTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(tr("Скрыть", "Hide")) { store.dismissLoop(for: task.id) }
                    .controlSize(.large)
                    .accessibilityLabel(tr("Скрыть предупреждение о возможном цикле для задачи: \(task.title)", "Hide possible loop warning for task: \(task.title)"))
            }
        }
    }
}

private struct StepMark: View {
    let status: StepStatus

    var body: some View {
        ZStack {
            if status == .done {
                StepCheckmark()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(width: 11, height: 9)
            } else if status == .active {
                Circle().fill(Color.accentColor).frame(width: 14, height: 14)
            } else {
                Circle().stroke(MonitorTheme.muted, lineWidth: 1).frame(width: 14, height: 14)
            }
        }
        .frame(width: 14, height: 16)
        .accessibilityHidden(true)
    }
}

private struct StepCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 9.5, rect.height / 6.5)
        let x = rect.minX + (rect.width - 9.5 * scale) / 2
        let y = rect.minY + (rect.height - 6.5 * scale) / 2
        var path = Path()
        path.move(to: CGPoint(x: x, y: y + 3.5 * scale))
        path.addLine(to: CGPoint(x: x + 3.2 * scale, y: y + 6.5 * scale))
        path.addLine(to: CGPoint(x: x + 9.5 * scale, y: y))
        return path
    }
}
