import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class ScrollAutohideAuditTests: XCTestCase {
    private func fixture() throws -> (URL, String) {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else { throw XCTSkip("Synthetic scroll audit is opt-in.") }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-autohide-"), let variant = env["AITM_SCROLL_VARIANT"],
              ["baseline", "autohide"].contains(variant) else {
            throw NSError(domain: "SyntheticScrollAutohideAudit", code: 1)
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
            throw NSError(domain: "SyntheticScrollAutohideAudit", code: 2)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SyntheticScrollAutohideAudit", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }
    private func near(_ left: NSRect, _ right: NSRect) -> Bool {
        zip(rectangle(left), rectangle(right)).allSatisfy { abs($0.0 - $0.1) <= 0.5 }
    }

    private struct Observation {
        let elapsed: Double
        let scroll: NSRect
        let clip: NSRect
        let document: NSRect
        let card: NSRect
        let scroller: NSRect?
        let scrollerHidden: Bool
        let scrollerEnabled: Bool
        let scrollerAlpha: Double
        let knob: Double
        let hasVertical: Bool
        let hasHorizontal: Bool
        let autohides: Bool
        let hostWidth: Double

        var drawn: Bool {
            guard let scroller else { return false }
            return hasVertical && !scrollerHidden && scrollerEnabled && scrollerAlpha > 0 && knob < 1 &&
                scroller.width > 0 && scroller.minX >= -0.5 && Double(scroller.maxX) <= hostWidth + 0.5
        }
        var gap: Double { hostWidth - Double(min(card.maxX, clip.maxX)) }
        var fullyVisible: Bool { card.maxX <= clip.maxX + 0.5 }
        var json: [String: Any] {
            func r(_ rect: NSRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }
            return ["elapsed": elapsed, "scroll": r(scroll), "clip": r(clip), "document": r(document),
                    "card": r(card), "scroller": scroller.map(r) ?? [], "scrollerHidden": scrollerHidden,
                    "scrollerEnabled": scrollerEnabled, "scrollerAlpha": scrollerAlpha, "knob": knob,
                    "hasVertical": hasVertical, "hasHorizontal": hasHorizontal, "autohides": autohides,
                    "hostWidth": hostWidth, "indicatorDrawn": drawn, "gap": gap, "fullyVisible": fullyVisible]
        }
    }

    @MainActor private func sample(_ host: NSView, taskID: String, elapsed: Double) throws -> (Observation, NSScrollView) {
        host.layoutSubtreeIfNeeded()
        let views = descendants(host)
        let marker = try XCTUnwrap(views.compactMap { $0 as? OverlayScrollerProbe.Probe }.first { $0.alwaysVisible })
        let scroll = try XCTUnwrap(marker.enclosingScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let card = try XCTUnwrap(views.compactMap { $0 as? ScrollWideCardProbe.Probe }.first { $0.taskID == taskID })
        let scroller = scroll.verticalScroller
        let row = Observation(elapsed: elapsed, scroll: scroll.convert(scroll.bounds, to: host),
                              clip: scroll.contentView.convert(scroll.contentView.bounds, to: host),
                              document: document.convert(document.bounds, to: host),
                              card: card.convert(card.bounds, to: host),
                              scroller: scroller.map { $0.convert($0.bounds, to: host) },
                              scrollerHidden: scroller?.isHiddenOrHasHiddenAncestor ?? true,
                              scrollerEnabled: scroller?.isEnabled ?? false,
                              scrollerAlpha: Double(scroller?.alphaValue ?? 0),
                              knob: Double(scroller?.knobProportion ?? 1),
                              hasVertical: scroll.hasVerticalScroller, hasHorizontal: scroll.hasHorizontalScroller,
                              autohides: scroll.autohidesScrollers, hostWidth: Double(host.bounds.width))
        return (row, scroll)
    }

    @MainActor func testTransitionsAndScrolling() throws {
        let (destination, variant) = try fixture()
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var output: [[String: Any]] = []
        for theme in ["light", "dark"] {
            let firstTask = try XCTUnwrap(TaskStore.preview().tasks.first)
            XCTAssertEqual(firstTask.provider, .codex)
            let secondTask = MonitoredTask(id: "codex-preview-second", provider: .codex,
                title: "Синтетическая вторая задача", activity: "Выполняет действие", isActive: true,
                progress: nil, progressKind: .none, steps: [], updatedAt: Date())
            let otherTasks = TaskStore.manySourcesPreview().tasks.filter { $0.provider != .codex }
            let store = TaskStore(previewTasks: [firstTask, secondTask] + otherTasks)
            store.selectedProvider = .codex
            let root = RootView().environmentObject(store)
                .environment(\.colorScheme, theme == "dark" ? .dark : .light).frame(width: 560, height: 700)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            let window = open(host)
            defer { window.close() }
            for (phase, selection) in [("short-initial", ProviderFilter.codex), ("long", .all), ("short-restored", .codex)] {
                store.selectedProvider = selection
                XCTAssertEqual(store.filteredTasks.count, phase == "long" ? 2 + otherTasks.count : 2,
                               "The fixture must switch between short and long task lists.")
                let id = try XCTUnwrap(store.filteredTasks.first?.id)
                let start = ProcessInfo.processInfo.systemUptime
                var rows: [Observation] = []
                var initialCaptured = false
                while true {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    let (row, _) = try sample(host, taskID: id, elapsed: elapsed)
                    rows.append(row)
                    if elapsed >= 1.2 && !initialCaptured {
                        window.displayIfNeeded()
                        try capture(host, to: destination.appendingPathComponent("\(variant)-\(phase)-\(theme)-initial.png"))
                        initialCaptured = true
                    }
                    if elapsed >= 3.2 { break }
                }
                window.displayIfNeeded()
                try capture(host, to: destination.appendingPathComponent("\(variant)-\(phase)-\(theme)-late.png"))
                let settled = rows.filter { $0.elapsed >= 1.2 }
                let first = try XCTUnwrap(settled.first)
                XCTAssertEqual(first.document.height > first.clip.height + 0.5, phase == "long",
                               "The long list must overflow vertically and the short list must fit.")
                let stable = settled.dropFirst().allSatisfy { row in
                    let scrollerStable: Bool
                    if let left = first.scroller, let right = row.scroller { scrollerStable = near(left, right) }
                    else { scrollerStable = first.scroller == nil && row.scroller == nil }
                    return near(first.scroll, row.scroll) && near(first.clip, row.clip) && near(first.document, row.document) &&
                    near(first.card, row.card) && scrollerStable && first.drawn == row.drawn &&
                    first.scrollerHidden == row.scrollerHidden && first.scrollerEnabled == row.scrollerEnabled &&
                    abs(first.knob - row.knob) <= 0.001 && abs(first.scrollerAlpha - row.scrollerAlpha) <= 0.001 &&
                    first.hasVertical == row.hasVertical && first.hasHorizontal == row.hasHorizontal && first.autohides == row.autohides
                }
                let (_, scroll) = try sample(host, taskID: id, elapsed: ProcessInfo.processInfo.systemUptime - start)
                let document = try XCTUnwrap(scroll.documentView)
                let origin = scroll.contentView.bounds.origin
                var horizontal: [Double] = []
                var vertical: [Double] = []
                for axis in ["horizontal", "vertical"] {
                    for delta in [-40, 40] as [Int32] {
                        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                      wheel1: axis == "vertical" ? delta : 0,
                                                      wheel2: axis == "horizontal" ? delta : 0, wheel3: 0))
                        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
                        XCTAssertNotEqual(axis == "vertical" ? event.scrollingDeltaY : event.scrollingDeltaX, 0)
                        scroll.scrollWheel(with: event)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                        let displacement = axis == "vertical" ? scroll.contentView.bounds.minY - origin.y : scroll.contentView.bounds.minX - origin.x
                        if axis == "vertical" { vertical.append(Double(displacement)) }
                        else { horizontal.append(Double(displacement)) }
                        scroll.contentView.scroll(to: origin)
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                }
                let available = max(0, document.bounds.width - scroll.contentView.bounds.width)
                scroll.contentView.scroll(to: NSPoint(x: origin.x + available, y: origin.y))
                scroll.reflectScrolledClipView(scroll.contentView)
                let programmatic = Double(scroll.contentView.bounds.minX - origin.x)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                let gaps = zip(rows.dropFirst(), rows).map { $0.0.elapsed - $0.1.elapsed }
                output.append(["variant": variant, "theme": theme, "phase": phase, "taskCount": store.filteredTasks.count,
                               "stableAfter1_2s": stable,
                               "maxSampleInterval": gaps.max() ?? 0, "samples": rows.map(\.json),
                               "horizontalWheelOffsets": horizontal, "verticalWheelOffsets": vertical,
                               "programmaticHorizontalOffset": programmatic])
                try writeJSON(output, to: destination.appendingPathComponent("autohide-geometry.json"))
                if variant == "autohide" {
                    XCTAssertGreaterThanOrEqual(settled.count, 20, "The settled interval needs enough samples.")
                    XCTAssertLessThanOrEqual(gaps.max() ?? 0, 0.25, "The sampled layout must not have a long observation gap.")
                    XCTAssertTrue(stable, "The sampled geometry must settle after 1.2 seconds.")
                    XCTAssertTrue(settled.allSatisfy { $0.autohides && $0.fullyVisible && abs($0.gap - 20) <= 1 },
                                  "The card edge and 20-point right margin must remain visible.")
                    XCTAssertTrue(settled.allSatisfy { $0.scroll.minX >= -0.5 && Double($0.scroll.maxX) <= $0.hostWidth + 0.5 },
                                  "The entire scroll view must remain inside the host.")
                    XCTAssertTrue(settled.allSatisfy { $0.drawn == (phase == "long") },
                                  "Only a long list must draw its vertical indicator.")
                    XCTAssertTrue(settled.allSatisfy { !$0.hasHorizontal })
                    for offset in horizontal { XCTAssertEqual(offset, 0, accuracy: 0.5) }
                    XCTAssertEqual(programmatic, 0, accuracy: 0.5)
                    if phase == "long" { XCTAssertTrue(vertical.contains { abs($0) > 0.5 }, "The long list must still scroll vertically.") }
                }
            }
        }
    }

    @MainActor func testSyntheticWarningButtonHits() throws {
        let (destination, variant) = try fixture()
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var results: [[String: Any]] = []
        var eventNumber = 0
        for theme in ["light", "dark"] {
            for yBand in ["low", "center", "high"] {
                for xBand in ["left", "center", "right"] {
                    let store = TaskStore.loopPreview()
                    let root = RootView().environmentObject(store)
                        .environment(\.colorScheme, theme == "dark" ? .dark : .light).frame(width: 560, height: 700)
                    let host = NSHostingView(rootView: root)
                    host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                    let window = open(host)
                    defer { window.close() }
                    RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    if xBand == "left", yBand == "low" {
                        try capture(host, to: destination.appendingPathComponent("\(variant)-warning-\(theme).png"))
                    }
                    let marker = try XCTUnwrap(descendants(host).compactMap { $0 as? ScrollWideButtonProbe.Probe }.first)
                    guard marker.bounds.width > 8, marker.bounds.height > 8 else { XCTFail("Button marker has no usable bounds."); continue }
                    let frame = marker.convert(marker.bounds, to: host)
                    let x = xBand == "left" ? marker.bounds.minX + 4 : xBand == "right" ? marker.bounds.maxX - 4 : marker.bounds.midX
                    let y = yBand == "low" ? marker.bounds.minY + 4 : yBand == "high" ? marker.bounds.maxY - 4 : marker.bounds.midY
                    let point = marker.convert(NSPoint(x: x, y: y), to: nil)
                    eventNumber += 2
                    let timestamp = ProcessInfo.processInfo.systemUptime
                    let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber - 1, clickCount: 1, pressure: 1))
                    let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0))
                    let checkpoint = destination.appendingPathComponent("autohide-click-checkpoint.json")
                    func mark(_ phase: String) throws {
                        try writeJSON(["variant": variant, "theme": theme, "xBand": xBand, "yBand": yBand, "phase": phase], to: checkpoint)
                    }
                    try mark("before-post-up")
                    NSApp.postEvent(up, atStart: true)
                    try mark("before-send-down")
                    window.sendEvent(down)
                    try mark("after-send-down")
                    let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date.distantPast, inMode: .default, dequeue: true)
                    if let pending {
                        guard pending.windowNumber == window.windowNumber, pending.eventNumber == eventNumber else {
                            throw NSError(domain: "SyntheticScrollAutohideAudit", code: 4)
                        }
                        window.sendEvent(pending)
                    }
                    try mark("after-send-up")
                    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    let dismissed = store.tasks.first?.loopWarning == nil
                    if xBand == "center", yBand == "center" { XCTAssertTrue(dismissed, "The button center must respond.") }
                    results.append(["variant": variant, "theme": theme, "xBand": xBand, "yBand": yBand,
                                    "buttonFrame": rectangle(frame), "dismissed": dismissed, "queuedUpRecovered": pending != nil])
                    try writeJSON(results, to: destination.appendingPathComponent("autohide-hit-tests.json"))
                    try mark("completed")
                }
            }
        }
    }
}
