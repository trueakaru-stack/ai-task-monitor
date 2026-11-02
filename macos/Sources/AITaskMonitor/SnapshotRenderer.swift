import AppKit
import SwiftUI

@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) -> Int32 {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try render(name: "expanded-dark", mode: .dark, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "expanded-light", mode: .light, compact: false, settings: false, outputDirectory: outputDirectory)
            try render(name: "compact-dark", mode: .dark, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "compact-light", mode: .light, compact: true, settings: false, outputDirectory: outputDirectory)
            try render(name: "settings-dark", mode: .dark, compact: false, settings: true, outputDirectory: outputDirectory)
            try render(name: "settings-light", mode: .light, compact: false, settings: true, outputDirectory: outputDirectory)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Snapshot error: \(error)\n".utf8))
            return 1
        }
    }

    private static func render(name: String, mode: AppearanceMode, compact: Bool, settings: Bool, outputDirectory: URL) throws {
        UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
        let store = TaskStore.preview()
        store.isCompact = compact
        store.showsSettings = settings
        let size = compact ? NSSize(width: 372, height: 182) : NSSize(width: 560, height: 700)
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
