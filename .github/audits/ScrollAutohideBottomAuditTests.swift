import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class ScrollAutohideBottomAuditTests: XCTestCase {
    private func fixture() throws -> (URL, String) {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else { throw XCTSkip("Synthetic bottom audit is opt-in.") }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-bottom-"), let variant = env["AITM_SCROLL_VARIANT"],
              ["baseline", "autohide"].contains(variant) else {
            throw NSError(domain: "SyntheticScrollBottomAudit", code: 1)
        }
        return (URL(fileURLWithPath: root, isDirectory: true), variant)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private func rectangle(_ value: NSRect) -> [Double] {
        [value.origin.x, value.origin.y, value.width, value.height].map { Double($0) }
    }
    private func writeJSON(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    @MainActor private func open(_ host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
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
        return window
    }
    @MainActor private func capture(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "SyntheticScrollBottomAudit", code: 2)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SyntheticScrollBottomAudit", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }
    @MainActor private func scrollView(_ host: NSView) throws -> NSScrollView {
        host.layoutSubtreeIfNeeded()
        let marker = try XCTUnwrap(descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }.first { $0.alwaysVisible })
        return try XCTUnwrap(marker.enclosingScrollView)
    }
    @MainActor private func card(_ id: String, in host: NSView) -> NSRect? {
        descendants(host).compactMap { $0 as? ScrollWideCardProbe.Probe }.first { $0.taskID == id }
            .map { $0.convert($0.bounds, to: host) }
    }
    private func visible(_ card: NSRect?, within clip: NSRect, horizontally: Bool) -> Bool {
        guard let card, card.width > 1, card.height > 1 else { return false }
        let vertical = card.minY >= clip.minY - 0.5 && card.maxY <= clip.maxY + 0.5
        return vertical && (!horizontally || (card.minX >= clip.minX - 0.5 && card.maxX <= clip.maxX + 0.5))
    }
    @MainActor private func indicatorVisible(_ scroll: NSScrollView, in host: NSView) -> Bool {
        guard scroll.hasVerticalScroller, let indicator = scroll.verticalScroller else { return false }
        let frame = indicator.convert(indicator.bounds, to: host)
        return indicator.isEnabled && !indicator.isHiddenOrHasHiddenAncestor && indicator.alphaValue > 0 &&
            indicator.knobProportion < 1 && frame.width > 0 && frame.minX >= host.bounds.minX - 0.5 &&
            frame.maxX <= host.bounds.maxX + 0.5
    }
    @MainActor private func wheel(_ scroll: NSScrollView, horizontal: Bool, delta: Int32) throws {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertNotEqual(horizontal ? event.scrollingDeltaX : event.scrollingDeltaY, 0)
        scroll.scrollWheel(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.04))
    }
    @MainActor private func horizontalProbe(_ scroll: NSScrollView) throws -> ([Double], Double) {
        let origin = scroll.contentView.bounds.origin
        var offsets: [Double] = []
        for delta in [-40, 40] as [Int32] {
            try wheel(scroll, horizontal: true, delta: delta)
            offsets.append(Double(scroll.contentView.bounds.minX - origin.x))
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let doc = try XCTUnwrap(scroll.documentView)
        let possible = max(0, doc.bounds.width - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: origin.x + possible, y: origin.y))
        scroll.reflectScrolledClipView(scroll.contentView)
        let programmatic = Double(scroll.contentView.bounds.minX - origin.x)
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        return (offsets, programmatic)
    }

    @MainActor func testScrolledBottomThenTasksShrinkAndReturn() throws {
        let (destination, variant) = try fixture()
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var output: [[String: Any]] = []
        for theme in ["light", "dark"] {
            for mode in ["filter", "disappearance"] {
                let firstTask = try XCTUnwrap(TaskStore.preview().tasks.first)
                XCTAssertEqual(firstTask.provider, .codex)
                let secondTask = MonitoredTask(id: "codex-preview-second", provider: .codex,
                    title: "Синтетическая вторая задача", activity: "Выполняет действие", isActive: true,
                    progress: nil, progressKind: .none, steps: [], updatedAt: Date())
                let others = TaskStore.manySourcesPreview().tasks.filter { $0.provider != .codex }
                let shortTasks = [firstTask, secondTask]
                let longTasks = shortTasks + others
                let lastID = try XCTUnwrap(longTasks.last?.id)
                let store = TaskStore(previewTasks: longTasks)
                let root = RootView().environmentObject(store)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light).frame(width: 560, height: 700)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let window = open(host)
                defer { window.close() }
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                var scroll = try scrollView(host)
                let initialDocument = try XCTUnwrap(scroll.documentView)
                let initialHeight = initialDocument.bounds.height
                XCTAssertEqual(store.filteredTasks.count, longTasks.count)
                XCTAssertGreaterThan(initialHeight, scroll.contentView.bounds.height + 1,
                                     "The synthetic long list must overflow vertically.")
                var reachedBottom = false
                var scrollAttempts = 0
                var stableBottom = 0
                for _ in 0..<80 {
                    try wheel(scroll, horizontal: false, delta: -40)
                    scrollAttempts += 1
                    host.layoutSubtreeIfNeeded()
                    scroll = try scrollView(host)
                    let doc = try XCTUnwrap(scroll.documentView)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let maximum = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                    let atEnd = abs(scroll.contentView.bounds.minY - maximum) <= 1 && visible(card(lastID, in: host), within: clip, horizontally: false)
                    stableBottom = atEnd ? stableBottom + 1 : 0
                    if stableBottom >= 3 { reachedBottom = true; break }
                }
                let bottomDocument = try XCTUnwrap(scroll.documentView)
                let bottomClip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                let bottomCard = card(lastID, in: host)
                try capture(host, to: destination.appendingPathComponent("\(variant)-\(mode)-\(theme)-long-bottom.png"))
                let bottomIndicator = scroll.verticalScroller
                let bottomIndicatorFrame = bottomIndicator.map { $0.convert($0.bounds, to: host) }
                let bottomIndicatorDrawn = indicatorVisible(scroll, in: host)
                let bottomGap = bottomCard.map { Double(host.bounds.width - min($0.maxX, bottomClip.maxX)) } ?? -1
                let (bottomHorizontal, bottomProgrammatic) = try horizontalProbe(scroll)
                output.append(["variant": variant, "mode": mode, "theme": theme, "stage": "long-bottom",
                               "reachedBottom": reachedBottom, "attempts": scrollAttempts,
                               "initialDocumentHeight": Double(initialHeight), "bottomDocumentHeight": Double(bottomDocument.bounds.height),
                               "offsetY": Double(scroll.contentView.bounds.minY), "clip": rectangle(bottomClip),
                               "lastCard": bottomCard.map(rectangle) ?? [],
                               "lastVerticallyVisible": visible(bottomCard, within: bottomClip, horizontally: false),
                               "lastFullyVisible": visible(bottomCard, within: bottomClip, horizontally: true), "gap": bottomGap,
                               "indicatorFrame": bottomIndicatorFrame.map(rectangle) ?? [], "indicatorDrawn": bottomIndicatorDrawn,
                               "horizontalWheelOffsets": bottomHorizontal, "programmaticHorizontalOffset": bottomProgrammatic])
                try writeJSON(output, to: destination.appendingPathComponent("bottom-geometry.json"))
                XCTAssertTrue(reachedBottom, "The synthetic wheel must reach the visible final card.")
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "The long list must actually be scrolled.")
                if variant == "autohide" {
                    XCTAssertTrue(visible(bottomCard, within: bottomClip, horizontally: true), "The final card must be fully visible.")
                    XCTAssertEqual(bottomGap, 20, accuracy: 1)
                    XCTAssertTrue(bottomIndicatorDrawn, "The long list must show its vertical scroller.")
                    for offset in bottomHorizontal { XCTAssertEqual(offset, 0, accuracy: 0.5) }
                    XCTAssertEqual(bottomProgrammatic, 0, accuracy: 0.5)
                }

                if mode == "filter" { store.selectedProvider = .codex }
                else { store.replaceSyntheticAuditTasks(shortTasks) }
                let afterShort = ProcessInfo.processInfo.systemUptime
                for (stage, seconds) in [("short-initial", 1.2), ("short-late", 3.2)] {
                    let remaining = max(0, seconds - (ProcessInfo.processInfo.systemUptime - afterShort))
                    RunLoop.current.run(until: Date().addingTimeInterval(remaining))
                    scroll = try scrollView(host)
                    let doc = try XCTUnwrap(scroll.documentView)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let first = card(firstTask.id, in: host)
                    let second = card(secondTask.id, in: host)
                    let gap = first.map { Double(host.bounds.width - min($0.maxX, clip.maxX)) } ?? -1
                    let origin = scroll.contentView.bounds.origin
                    let (horizontal, programmatic) = try horizontalProbe(scroll)
                    try capture(host, to: destination.appendingPathComponent("\(variant)-\(mode)-\(theme)-\(stage).png"))
                    let firstVisible = visible(first, within: clip, horizontally: true)
                    let secondVisible = visible(second, within: clip, horizontally: true)
                    let indicatorDrawn = indicatorVisible(scroll, in: host)
                    output.append(["variant": variant, "mode": mode, "theme": theme, "stage": stage,
                                   "elapsed": ProcessInfo.processInfo.systemUptime - afterShort,
                                   "taskCount": store.filteredTasks.count, "offsetX": Double(origin.x), "offsetY": Double(origin.y),
                                   "clip": rectangle(clip), "document": rectangle(doc.convert(doc.bounds, to: host)),
                                   "firstCard": first.map(rectangle) ?? [], "secondCard": second.map(rectangle) ?? [],
                                   "firstVisible": firstVisible, "secondVisible": secondVisible, "gap": gap,
                                   "horizontalWheelOffsets": horizontal, "programmaticHorizontalOffset": programmatic,
                                   "indicatorDrawn": indicatorDrawn])
                    try writeJSON(output, to: destination.appendingPathComponent("bottom-geometry.json"))
                    if variant == "autohide" {
                        XCTAssertEqual(store.filteredTasks.count, 2)
                        XCTAssertEqual(origin.y, 0, accuracy: 0.5, "The short list must reset the previous bottom offset.")
                        XCTAssertTrue(firstVisible && secondVisible, "Both remaining cards must be visible.")
                        XCTAssertEqual(gap, 20, accuracy: 1)
                        for offset in horizontal { XCTAssertEqual(offset, 0, accuracy: 0.5) }
                        XCTAssertEqual(programmatic, 0, accuracy: 0.5)
                        XCTAssertFalse(indicatorDrawn, "A fitting short list must not draw its vertical scroller.")
                    }
                }

                if mode == "filter" { store.selectedProvider = .all }
                else { store.replaceSyntheticAuditTasks(longTasks) }
                let afterRestore = ProcessInfo.processInfo.systemUptime
                for (stage, seconds) in [("restored-initial", 1.2), ("restored-late", 3.2)] {
                    let remaining = max(0, seconds - (ProcessInfo.processInfo.systemUptime - afterRestore))
                    RunLoop.current.run(until: Date().addingTimeInterval(remaining))
                    scroll = try scrollView(host)
                    let doc = try XCTUnwrap(scroll.documentView)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let first = card(firstTask.id, in: host)
                    let origin = scroll.contentView.bounds.origin
                    let indicator = scroll.verticalScroller
                    let indicatorFrame = indicator.map { $0.convert($0.bounds, to: host) }
                    let indicatorDrawn = indicatorVisible(scroll, in: host)
                    let gap = first.map { Double(host.bounds.width - min($0.maxX, clip.maxX)) } ?? -1
                    let (horizontal, programmatic) = try horizontalProbe(scroll)
                    try capture(host, to: destination.appendingPathComponent("\(variant)-\(mode)-\(theme)-\(stage).png"))
                    let firstVisible = visible(first, within: clip, horizontally: true)
                    output.append(["variant": variant, "mode": mode, "theme": theme, "stage": stage,
                                   "elapsed": ProcessInfo.processInfo.systemUptime - afterRestore,
                                   "taskCount": store.filteredTasks.count, "offsetX": Double(origin.x), "offsetY": Double(origin.y),
                                   "clip": rectangle(clip), "document": rectangle(doc.convert(doc.bounds, to: host)),
                                   "firstCard": first.map(rectangle) ?? [], "firstVisible": firstVisible, "gap": gap,
                                   "indicatorFrame": indicatorFrame.map(rectangle) ?? [], "indicatorDrawn": indicatorDrawn,
                                   "horizontalWheelOffsets": horizontal, "programmaticHorizontalOffset": programmatic])
                    try writeJSON(output, to: destination.appendingPathComponent("bottom-geometry.json"))
                    if variant == "autohide" {
                        XCTAssertEqual(store.filteredTasks.count, longTasks.count)
                        XCTAssertEqual(origin.y, 0, accuracy: 0.5, "The restored list must start at the top.")
                        XCTAssertTrue(firstVisible, "The first restored task must be visible.")
                        XCTAssertTrue(indicatorDrawn, "The long list must show its vertical scroller inside the window.")
                        XCTAssertEqual(gap, 20, accuracy: 1)
                        for offset in horizontal { XCTAssertEqual(offset, 0, accuracy: 0.5) }
                        XCTAssertEqual(programmatic, 0, accuracy: 0.5)
                    }
                }
                scroll = try scrollView(host)
                let restoredInitialHeight = try XCTUnwrap(scroll.documentView).bounds.height
                var restoredReachedBottom = false
                var restoredAttempts = 0
                var restoredStableBottom = 0
                for _ in 0..<80 {
                    try wheel(scroll, horizontal: false, delta: -40)
                    restoredAttempts += 1
                    host.layoutSubtreeIfNeeded()
                    scroll = try scrollView(host)
                    let doc = try XCTUnwrap(scroll.documentView)
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let maximum = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                    let atEnd = abs(scroll.contentView.bounds.minY - maximum) <= 1 && visible(card(lastID, in: host), within: clip, horizontally: false)
                    restoredStableBottom = atEnd ? restoredStableBottom + 1 : 0
                    if restoredStableBottom >= 3 { restoredReachedBottom = true; break }
                }
                let restoredDocument = try XCTUnwrap(scroll.documentView)
                let restoredClip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                let restoredLast = card(lastID, in: host)
                let restoredGap = restoredLast.map { Double(host.bounds.width - min($0.maxX, restoredClip.maxX)) } ?? -1
                let restoredIndicator = indicatorVisible(scroll, in: host)
                let (restoredHorizontal, restoredProgrammatic) = try horizontalProbe(scroll)
                try capture(host, to: destination.appendingPathComponent("\(variant)-\(mode)-\(theme)-restored-bottom.png"))
                output.append(["variant": variant, "mode": mode, "theme": theme, "stage": "restored-bottom",
                               "reachedBottom": restoredReachedBottom, "attempts": restoredAttempts,
                               "initialDocumentHeight": Double(restoredInitialHeight), "bottomDocumentHeight": Double(restoredDocument.bounds.height),
                               "offsetY": Double(scroll.contentView.bounds.minY), "clip": rectangle(restoredClip),
                               "lastCard": restoredLast.map(rectangle) ?? [],
                               "lastFullyVisible": visible(restoredLast, within: restoredClip, horizontally: true), "gap": restoredGap,
                               "indicatorDrawn": restoredIndicator, "horizontalWheelOffsets": restoredHorizontal,
                               "programmaticHorizontalOffset": restoredProgrammatic])
                try writeJSON(output, to: destination.appendingPathComponent("bottom-geometry.json"))
                if variant == "autohide" {
                    XCTAssertTrue(restoredReachedBottom, "The restored list must reach its final card.")
                    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                    XCTAssertTrue(visible(restoredLast, within: restoredClip, horizontally: true))
                    XCTAssertEqual(restoredGap, 20, accuracy: 1)
                    XCTAssertTrue(restoredIndicator)
                    for offset in restoredHorizontal { XCTAssertEqual(offset, 0, accuracy: 0.5) }
                    XCTAssertEqual(restoredProgrammatic, 0, accuracy: 0.5)
                }
            }
        }
    }
}
