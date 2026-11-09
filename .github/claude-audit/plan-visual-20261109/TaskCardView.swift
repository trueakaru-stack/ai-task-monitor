import AppKit
import SwiftUI

struct TaskCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let task: MonitoredTask
    let showProvider: Bool

    private var hidesClaudePlanStatus: Bool {
        task.provider == .claude && (!task.planConfirmed || task.isUnconfirmed)
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
                TruncatingText(text: task.title, font: .systemFont(ofSize: 16, weight: .semibold), color: .labelColor)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                if let label = task.progressLabel, !hidesClaudePlanStatus {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if !task.activity.isEmpty {
                ActivityStatusRow(text: task.activity, isActive: task.isActive, fontSize: 12)
                    .padding(.top, 4)
            }
            if task.loopWarning != nil {
                LoopWarningView(task: task, compact: false).padding(.top, 8)
            }
            if let progress = task.progress, task.progressKind != .none, !hidesClaudePlanStatus {
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
                                StepMark(status: hidesClaudePlanStatus ? .pending : step.status)
                                TruncatingText(text: step.title, font: .systemFont(ofSize: 12), color: !hidesClaudePlanStatus && step.status == .active ? .labelColor : .secondaryLabelColor)
                                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
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
                                     (task.provider == .claude && colorScheme == .light ? MonitorTheme.primary : MonitorTheme.secondary))
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
