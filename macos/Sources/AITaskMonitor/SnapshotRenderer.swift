import AppKit
import SwiftUI

@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) -> Int32 {
        let previousAppearance = UserDefaults.standard.object(forKey: "appearanceMode")
        defer {
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
            try render(name: "journal-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "journal-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, journal: true)
            try render(name: "source-unavailable-full-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-full-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try render(name: "source-unavailable-compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory, unavailableSources: [.codex])
            try renderHint(name: "hint-dark", mode: .dark, outputDirectory: outputDirectory)
            try renderHint(name: "hint-light", mode: .light, outputDirectory: outputDirectory)
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

    private static func render(name: String, mode: AppearanceMode, compact: Bool, settings: Bool, outputDirectory: URL, unavailableSources: [TaskProvider] = [], journal: Bool = false) throws {
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        let store = journal ? TaskStore.journalPreview() : TaskStore.preview(unavailableSources: unavailableSources)
        store.isCompact = compact
        store.showsSettings = settings || journal
        store.showsJournal = journal
        let size = compact ? NSSize(width: 372, height: unavailableSources.isEmpty ? 182 : 206) : NSSize(width: 560, height: 700)
        let scheme: ColorScheme = mode == .dark ? .dark : .light
        let view = RootView()
            .environmentObject(store)
            .environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw SnapshotError.bitmap }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError.png }
        try png.write(to: outputDirectory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private enum SnapshotError: Error { case bitmap, png }
}
