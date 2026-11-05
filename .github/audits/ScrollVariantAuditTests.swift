import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class ScrollVariantAuditTests: XCTestCase {
    @MainActor func testSyntheticScrollVariantsAtTwoTimes() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else { throw XCTSkip("Synthetic scroll audit is opt-in.") }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-"), let variant = env["AITM_SCROLL_VARIANT"],
              ["baseline", "outer", "clip", "outer-clip"].contains(variant) else {
            throw NSError(domain: "SyntheticScrollVariantAudit", code: 1)
        }
        let destination = URL(fileURLWithPath: root, isDirectory: true)
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rectangle(_ value: NSRect) -> [Double] {
            [value.origin.x, value.origin.y, value.width, value.height].map { Double($0) }
        }
        func capture(_ host: NSView, _ name: String) throws {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "SyntheticScrollVariantAudit", code: 2)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SyntheticScrollVariantAudit", code: 3)
            }
            try png.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        var records: [[String: Any]] = []
        for theme in ["light", "dark"] {
            for scenario in ["short", "long"] {
                ScrollVariantHistory.reset()
                let store = scenario == "short" ? TaskStore.preview() : TaskStore.manySourcesPreview()
                let rootView = RootView().environmentObject(store)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    .frame(width: 560, height: 700)
                let host = NSHostingView(rootView: rootView)
                host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.contentView = host
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                var samples: [[String: Any]] = []
                for (stage, delay) in [("initial", 1.2), ("late", 2.0)] {
                    RunLoop.current.run(until: Date().addingTimeInterval(delay))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let probe = try XCTUnwrap(descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }
                        .first { $0.alwaysVisible })
                    let scroll = try XCTUnwrap(probe.enclosingScrollView)
                    let document = try XCTUnwrap(scroll.documentView)
                    let name = "\(variant)-\(scenario)-\(theme)-\(stage).png"
                    try capture(host, name)
                    var chain: [[String: Any]] = []
                    var ancestor: NSView? = scroll
                    while let view = ancestor, chain.count < 32 {
                        chain.append(["type": String(describing: type(of: view)),
                                      "frame": rectangle(view.frame), "bounds": rectangle(view.bounds),
                                      "frameInHost": rectangle(view.convert(view.bounds, to: host)),
                                      "isFlipped": view.isFlipped])
                        if view === host { break }
                        ancestor = view.superview
                    }
                    XCTAssertGreaterThan(scroll.contentView.bounds.width, 0)
                    XCTAssertGreaterThan(document.bounds.width, 0)
                    samples.append(["stage": stage, "file": name,
                                    "scroll": rectangle(scroll.convert(scroll.bounds, to: host)),
                                    "clip": rectangle(scroll.contentView.convert(scroll.contentView.bounds, to: host)),
                                    "document": rectangle(document.convert(document.bounds, to: host)),
                                    "ancestors": chain, "clipWidthHistory": ScrollVariantHistory.widths,
                                    "historyCapped": ScrollVariantHistory.capped])
                }
                records.append(["variant": variant, "theme": theme, "scenario": scenario, "samples": samples])
            }
        }
        let report = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: destination.appendingPathComponent("scroll-variant-geometry.json"), options: .atomic)
    }
}
