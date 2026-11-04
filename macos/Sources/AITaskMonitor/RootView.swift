import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: TaskStore
    @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("languageMode") private var languageRaw = AppLanguage.system.rawValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if store.isCompact { compactContent }
            else if store.showsJournal { JournalView() }
            else if store.showsAbout { AboutView() }
            else if store.showsSettings { SettingsView() }
            else { tasksContent }
        }
        .frame(width: store.isCompact ? 372 : 560, height: store.isCompact ? compactHeight : 700)
        .background(MonitorTheme.surface)
        .overlay {
            if let update = store.visibleUpdate { UpdateDialog(update: update) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(MonitorTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 22, y: 8)
        .background(WindowConfigurator(isCompact: store.isCompact, compactHeight: compactHeight))
        .preferredColorScheme(preferredScheme)
        .environment(\.locale, Locale(identifier: AppLanguage.resolve(AppLanguage(rawValue: languageRaw) ?? .system, preferredLanguages: Locale.preferredLanguages).rawValue))
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("AI task monitor")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            TitleAction(symbol: "minus", label: tr("Свернуть", "Minimize")) { NSApp.keyWindow?.miniaturize(nil) }
            TitleAction(symbol: store.isCompact ? "chevron.up" : "chevron.down", label: store.isCompact ? tr("Развернуть", "Expand") : tr("Компактный вид", "Compact view")) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { store.isCompact.toggle(); store.showsSettings = false; store.showsJournal = false; store.showsAbout = false }
            }
            TitleAction(symbol: "xmark", label: tr("Закрыть", "Close")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.isCompact.toggle() }
    }

    private var tasksContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Ход выполнения", "Progress"))
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 8)
            if store.providers.count > 1 { providerTabs.padding(.top, 16) }
            if !store.unavailableMessage.isEmpty {
                Text(store.unavailableMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(MonitorTheme.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
            }
            if store.filteredTasks.isEmpty {
                Spacer()
                if store.unavailableMessage.isEmpty {
                    VStack(spacing: 8) {
                        Text(tr("Активных задач нет", "No active tasks")).font(.system(size: 15, weight: .medium))
                        Text(tr("Окно обновится автоматически", "Updates automatically")).font(.system(size: 12)).foregroundStyle(MonitorTheme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.filteredTasks) { task in TaskCardView(task: task, showProvider: store.providers.count > 1) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(OverlayScrollerProbe().frame(width: 0, height: 0))
                }
            }
            Button {
                store.showsSettings = true
            } label: {
                Label(tr("Настройки", "Settings"), systemImage: "gearshape")
                    .font(.system(size: 12.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MonitorTheme.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .accessibilityHint(tr("Открыть настройки приложения", "Open app settings"))
        }
    }

    private var providerTabs: some View {
        Group {
            if store.providers.count <= 2 {
                HStack(spacing: 4) {
                    ForEach(store.visibleProviderFilters) { filter in providerTab(filter, fillsWidth: true) }
                }
                .padding(4)
                .background(Squircle(radius: 14).fill(MonitorTheme.track.opacity(0.5)))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(store.visibleProviderFilters) { filter in
                                providerTab(filter, fillsWidth: false).id(filter)
                            }
                        }
                        .padding(4)
                    }
                    .background(Squircle(radius: 14).fill(MonitorTheme.track.opacity(0.5)))
                    .clipShape(Squircle(radius: 14))
                    .onChange(of: store.selectedProvider) { selection in proxy.scrollTo(selection) }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func providerTab(_ filter: ProviderFilter, fillsWidth: Bool) -> some View {
        Button {
            store.selectedProvider = filter
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(filter.title).font(.system(size: 13, weight: .semibold))
                Text("\(store.count(for: filter))").font(.system(size: 11.5, weight: .semibold)).baselineOffset(4)
            }
            .padding(.horizontal, fillsWidth ? 0 : 13)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 34)
            .background(store.selectedProvider == filter ? Squircle(radius: 10).fill(MonitorTheme.raised) : nil)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(store.selectedProvider == filter ? .isSelected : [])
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.tasks.isEmpty {
                Text(store.unavailableMessage.isEmpty ? tr("Активных задач нет", "No active tasks") : store.unavailableMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MonitorTheme.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                let index = min(store.compactIndex, store.tasks.count - 1)
                let task = store.tasks[index]
                if store.providers.count > 1 {
                    Text(task.provider.displayName).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.accentColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TruncatingText(text: task.title, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
                        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                    if let label = task.progressLabel { Text(label).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
                }
                if !task.activity.isEmpty {
                    ActivityStatusRow(text: task.activity, isActive: task.isActive, fontSize: 11.5)
                }
                if !task.steps.isEmpty && !task.planConfirmed {
                    Text(tr("План не подтверждён", "Plan unconfirmed")).font(.system(size: 11.5)).foregroundStyle(MonitorTheme.secondary)
                }
                if task.loopWarning != nil { LoopWarningView(task: task, compact: true) }
                if !store.unavailableMessage.isEmpty {
                    Text(store.unavailableMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MonitorTheme.secondary)
                        .lineLimit(2)
                }
                if store.tasks.count > 1 {
                    HStack(spacing: 7) {
                        ForEach(Array(store.tasks.prefix(3).indices), id: \.self) { item in
                            Button { store.compactIndex = item } label: {
                                Circle().fill(item == index ? Color.accentColor : MonitorTheme.muted).frame(width: 6, height: 6)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tr("Задача \(item + 1)", "Task \(item + 1)"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private var preferredScheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceRaw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var compactHeight: CGFloat {
        let base: CGFloat = store.tasks.count > 1 ? 182 : 156
        let sourceExtra: CGFloat = !store.tasks.isEmpty && !store.unavailableMessage.isEmpty ? 24 : 0
        let selected = store.tasks.isEmpty ? nil : store.tasks[min(store.compactIndex, store.tasks.count - 1)]
        let loopExtra: CGFloat = selected?.loopWarning == nil ? 0 : 64
        let planExtra: CGFloat = selected.map { !$0.steps.isEmpty && !$0.planConfirmed } == true ? 22 : 0
        return base + sourceExtra + loopExtra + planExtra
    }
}

private struct TitleAction: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let isCompact: Bool
    let compactHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.formUnion([.fullSizeContentView, .resizable])
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        let size = isCompact ? NSSize(width: 372, height: compactHeight) : NSSize(width: 560, height: 700)
        if window.frame.size != size { window.setContentSize(size) }
        window.minSize = isCompact ? size : NSSize(width: 500, height: 500)
        window.maxSize = isCompact ? size : NSSize(width: 900, height: 1_000)
    }
}
