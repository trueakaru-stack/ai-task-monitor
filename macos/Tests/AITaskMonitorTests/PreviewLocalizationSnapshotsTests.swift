import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class PreviewLocalizationSnapshotsTests: XCTestCase {
    @MainActor func testCompactSyntheticPreviewsInBothLanguagesAndThemes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("Preview snapshots run only on an ephemeral GitHub-hosted runner.")
        }
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted", environment["RUNNER_OS"] == "macOS",
              let temporary = environment["RUNNER_TEMP"], let root = environment["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticPreviewAudit", code: 1)
        }
        let destination = URL(fileURLWithPath: root, isDirectory: true)
        _ = NSApplication.shared
        defer { AppLanguage.previewOverride = nil }
        var report: [[String: Any]] = []
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for theme in ["light", "dark"] {
                for scenario in ["preview", "loop"] {
                    let store = scenario == "preview" ? TaskStore.preview() : TaskStore.loopPreview()
                    store.isCompact = true
                    let rootView = RootView().environmentObject(store)
                        .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    let host = NSHostingView(rootView: rootView)
                    host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 372, height: 182)
                    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 182),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "SyntheticPreviewAudit", code: 2)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "SyntheticPreviewAudit", code: 3)
                    }
                    let name = "\(scenario)-compact-\(language.rawValue)-\(theme).png"
                    try png.write(to: destination.appendingPathComponent(name), options: .atomic)
                    report.append(["file": name, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh])
                    window.close()
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("compact-preview-geometry.json"), options: .atomic)
    }
}
