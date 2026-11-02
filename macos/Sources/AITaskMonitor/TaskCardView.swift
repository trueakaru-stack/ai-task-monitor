import AppKit
import SwiftUI

struct TaskCardView: View {
    let task: MonitoredTask
    let showProvider: Bool

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
                if let label = task.progressLabel {
                    Text(label)
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                }
            }
            if !task.activity.isEmpty {
                TruncatingText(text: task.activity, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
                    .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                    .padding(.top, 4)
            }
            if let progress = task.progress, task.progressKind != .none {
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
                                StepMark(status: step.status)
                                TruncatingText(text: step.title, font: .systemFont(ofSize: 12), color: step.status == .active ? .labelColor : .secondaryLabelColor)
                                    .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(height: 116)
                .padding(.top, 16)
                Text("План задачи · \(task.steps.count) этапов")
                    .font(.system(size: 11))
                    .foregroundStyle(MonitorTheme.muted)
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

private struct StepMark: View {
    let status: StepStatus

    var body: some View {
        ZStack {
            Circle()
                .stroke(status == .done ? Color.accentColor : MonitorTheme.muted, lineWidth: 1)
                .frame(width: 11, height: 11)
            if status == .done {
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            } else if status == .active {
                Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            }
        }
        .frame(width: 12, height: 16)
        .accessibilityHidden(true)
    }
}
