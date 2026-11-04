import AppKit
import SwiftUI

@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) -> Int32 {
        let previousAppearance = UserDefaults.standard.object(forKey: "appearanceMode")
        defer {
            AppLanguage.previewOverride = nil
            if let previousAppearance {
                UserDefaults.standard.set(previousAppearance, forKey: "appearanceMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "appearanceMode")
            }
        }
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try render(name: "expanded-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "expanded-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "settings-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory)
            try render(name: "settings-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory)
            try render(name: "about-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory, about: true)
            try render(name: "about-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory, about: true)
            try render(name: "update-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, update: true)
            try render(name: "update-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, update: true)
            try render(name: "journal-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "journal-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "loop-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "loop-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true)
            try render(name: "claude-loop-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude)
            try render(name: "claude-loop-error-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude, loopError: true)
            try render(name: "claude-loop-error-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory, loopWarning: true, loopProvider: .claude, loopError: true)
            try render(name: "loop-source-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.claude], loopWarning: true)
            try render(name: "source-unavailable-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try renderHint(name: "hint-dark", mode: .dark, outputDirectory: outputDirectory)
            try renderHint(name: "hint-light", mode: .light, outputDirectory: outputDirectory)
            for language in [AppLanguage.ru, .en] {
                AppLanguage.previewOverride = language
                for mode in [AppearanceMode.dark, .light] {
                    for compact in [false, true] {
                        for unconfirmed in [false, true] {
                            let name = "plan-\(language.rawValue)-\(mode.rawValue)-\(compact ? "compact" : "expanded")-\(unconfirmed ? "unconfirmed" : "confirmed")"
                            try render(name: name, mode: mode, compact: compact, settings: false, outputDirectory: outputDirectory, planUnconfirmed: unconfirmed)
                        }
                    }
                    try render(name: "settings-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory)
                    try render(name: "settings-end-\(language.rawValue)-\(mode.rawValue)", mode: mode, compact: false, settings: true, outputDirectory: outputDirectory, settingsEnd: true)
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Snapshot error: \(error)\n".utf8))
            return 1
        }
    }

    private static func renderHint(name: String, mode: AppearanceMode, outputDirectory: URL) throws {
        let field = TruncatingTextField(labelWithString: "")
        field.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        let panel = field.makeHintPanel(text: "Проверяю нативную сборку, локальные источники и создание установочного образа для macOS")
        guard let content = panel.contentView else { throw SnapshotError.bitmap }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw SnapshotError.bitmap }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.png }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private static func render(name: String, mode: AppearanceMode, compact: Bool, settings: Bool, outputDirectory: URL, unavailableSources: [TaskProvider] = [], journal: Bool = false, loopWarning: Bool = false, loopProvider: TaskProvider = .codex, loopError: Bool = false, about: Bool = false, update: Bool = false, planUnconfirmed: Bool = false, settingsEnd: Bool = false) throws {
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        let store = journal ? TaskStore.journalPreview() : (loopWarning ? TaskStore.loopPreview(unavailableSources: unavailableSources, provider: loopProvider, showsError: loopError) : TaskStore.preview(unavailableSources: unavailableSources, planUnconfirmed: planUnconfirmed))
        store.isCompact = compact
        store.showsSettings = settings || journal
        store.showsJournal = journal
        store.showsAbout = about
        if update { store.setPreviewUpdate() }
        let compactHeight: CGFloat = 182 + (unavailableSources.isEmpty ? 0 : 24) + (loopWarning ? 64 : 0) + (planUnconfirmed ? 22 : 0)
        let size = compact ? NSSize(width: 372, height: compactHeight) : NSSize(width: 560, height: 700)
        let scheme: ColorScheme = mode == .dark ? .dark : .light
        let view = RootView()
            .environmentObject(store)
            .environment(\.colorScheme, scheme)
            .environment(\.settingsPreviewEnd, settingsEnd)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        var previewWindow: NSWindow?
        if settingsEnd {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.orderFrontRegardless()
            previewWindow = window
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        defer { previewWindow?.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SnapshotError.bitmap }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.png }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private enum SnapshotError: Error { case bitmap, png }
}
