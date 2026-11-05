import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class ScrollFixedAuditTests: XCTestCase {
    private func fixture() throws -> (URL, String) {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else { throw XCTSkip("Synthetic scroll audit is opt-in.") }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-"), let variant = env["AITM_SCROLL_VARIANT"],
              ["baseline", "fixed-before", "fixed-after"].contains(variant) else {
            throw NSError(domain: "SyntheticScrollWideAudit", code: 1)
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
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
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
            throw NSError(domain: "SyntheticScrollWideAudit", code: 2)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SyntheticScrollWideAudit", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }

    @MainActor func testCardEdgesAndHorizontalScrolling() throws {
        let (destination, variant) = try fixture()
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var results: [[String: Any]] = []
        for theme in ["light", "dark"] {
            for scenario in ["short", "long"] {
                let store = scenario == "short" ? TaskStore.preview() : TaskStore.manySourcesPreview()
                let firstID = try XCTUnwrap(store.filteredTasks.first?.id)
                let root = RootView().environmentObject(store)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    .frame(width: 560, height: 700)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let window = open(host)
                defer { window.close() }
                var samples: [[String: Any]] = []
                let openedAt = Date()
                for (stage, elapsed) in [("initial", 1.2), ("late", 3.2)] {
                    RunLoop.current.run(until: openedAt.addingTimeInterval(elapsed))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let sampledAt = Date()
                    let file = "\(variant)-\(scenario)-\(theme)-\(stage).png"
                    try capture(host, to: destination.appendingPathComponent(file))
                    let views = descendants(host)
                    let probe = try XCTUnwrap(views.compactMap { $0 as? OverlayScrollerProbe.Probe }.first { $0.alwaysVisible })
                    let scroll = try XCTUnwrap(probe.enclosingScrollView)
                    let document = try XCTUnwrap(scroll.documentView)
                    let card = try XCTUnwrap(views.compactMap { $0 as? ScrollWideCardProbe.Probe }.first { $0.taskID == firstID })
                    let scrollFrame = scroll.convert(scroll.bounds, to: host)
                    let clipFrame = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let cardFrame = card.convert(card.bounds, to: host)
                    let scroller = scroll.verticalScroller
                    let scrollerFrame = scroller.map { $0.convert($0.bounds, to: host) }
                    let visibleRight = min(cardFrame.maxX, clipFrame.maxX)
                    let rightGap = host.bounds.width - visibleRight
                    let fullyVisible = cardFrame.maxX <= clipFrame.maxX + 0.5
                    XCTAssertGreaterThan(cardFrame.width, 1, "The card probe must have a measurable frame.")
                    XCTAssertGreaterThan(cardFrame.height, 1, "The card probe must have a measurable frame.")

                    let original = scroll.contentView.bounds.origin
                    var wheelOffsets: [Double] = []
                    var wheelDeltas: [Double] = []
                    for delta in [-40, 40] as [Int32] {
                        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                      wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0))
                        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
                        wheelDeltas.append(Double(event.scrollingDeltaX))
                        XCTAssertNotEqual(event.scrollingDeltaX, 0, "The synthetic horizontal wheel event must contain a delta.")
                        scroll.scrollWheel(with: event)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                        wheelOffsets.append(Double(scroll.contentView.bounds.minX - original.x))
                        scroll.contentView.scroll(to: original)
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    let possibleOffset = max(0, document.bounds.width - scroll.contentView.bounds.width)
                    scroll.contentView.scroll(to: NSPoint(x: original.x + possibleOffset, y: original.y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    let programmaticOffset = scroll.contentView.bounds.minX - original.x
                    scroll.contentView.scroll(to: original)
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if variant != "baseline" {
                        XCTAssertTrue(fullyVisible, "The first card's right edge must remain inside the clip.")
                        XCTAssertEqual(rightGap, 20, accuracy: 1, "The visible card must retain its right margin.")
                        XCTAssertFalse(scroll.hasHorizontalScroller, "The synthetic task list must not show a horizontal scroller.")
                        for offset in wheelOffsets { XCTAssertEqual(offset, 0, accuracy: 0.5, "A horizontal wheel event must not move the list.") }
                        XCTAssertEqual(programmaticOffset, 0, accuracy: 0.5, "The document must not have a horizontal overflow.")
                        XCTAssertGreaterThanOrEqual(scrollFrame.minX, host.bounds.minX - 0.5, "The scroll view must remain inside the host.")
                        XCTAssertLessThanOrEqual(scrollFrame.maxX, host.bounds.maxX + 0.5, "The scroll view must remain inside the host.")
                        if scenario == "long" {
                            XCTAssertTrue(scroll.hasVerticalScroller, "A long list must retain its vertical scroller.")
                            if let vertical = scroller, let frame = scrollerFrame {
                                XCTAssertFalse(vertical.isHiddenOrHasHiddenAncestor, "The vertical scroller must not be hidden.")
                                XCTAssertTrue(vertical.isEnabled, "The vertical scroller must be enabled for a long list.")
                                XCTAssertLessThan(vertical.knobProportion, 1, "The vertical scroller must indicate overflow.")
                                XCTAssertGreaterThan(frame.width, 0, "The vertical scroller must have a visible frame.")
                                XCTAssertGreaterThanOrEqual(frame.minX, host.bounds.minX - 0.5, "The vertical scroller must remain inside the host.")
                                XCTAssertLessThanOrEqual(frame.maxX, host.bounds.maxX + 0.5, "The vertical scroller must remain inside the host.")
                            } else {
                                XCTFail("A long list must retain a vertical scroller view.")
                            }
                        }
                    }
                    samples.append(["stage": stage, "elapsedTargetSeconds": elapsed,
                                    "elapsedActualSeconds": sampledAt.timeIntervalSince(openedAt), "file": file,
                                    "scroll": rectangle(scrollFrame),
                                    "clip": rectangle(clipFrame), "document": rectangle(document.convert(document.bounds, to: host)),
                                    "firstCard": rectangle(cardFrame), "rightGap": Double(rightGap),
                                    "rightEdgeVisible": fullyVisible, "hasHorizontalScroller": scroll.hasHorizontalScroller,
                                    "hasVerticalScroller": scroll.hasVerticalScroller,
                                    "verticalScrollerFrame": scrollerFrame.map(rectangle) ?? [],
                                    "verticalScrollerHidden": scroller?.isHiddenOrHasHiddenAncestor ?? true,
                                    "verticalScrollerAlpha": Double(scroller?.alphaValue ?? 0),
                                    "verticalScrollerEnabled": scroller?.isEnabled ?? false,
                                    "verticalScrollerKnobProportion": Double(scroller?.knobProportion ?? 1),
                                    "wheelDeltas": wheelDeltas, "wheelOffsets": wheelOffsets,
                                    "programmaticOffset": Double(programmaticOffset)])
                    try writeJSON(results + [["variant": variant, "theme": theme, "scenario": scenario, "samples": samples]],
                                  to: destination.appendingPathComponent("fixed-geometry.json"))
                }
                results.append(["variant": variant, "theme": theme, "scenario": scenario, "samples": samples])
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
                XCTAssertNotNil(store.tasks.first?.loopWarning)
                let root = RootView().environmentObject(store)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    .frame(width: 560, height: 700)
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
                let probe = try XCTUnwrap(descendants(host).compactMap { $0 as? ScrollWideButtonProbe.Probe }.first)
                XCTAssertGreaterThan(probe.bounds.width, 8)
                XCTAssertGreaterThan(probe.bounds.height, 8)
                guard probe.bounds.width > 8, probe.bounds.height > 8 else { continue }
                let buttonFrame = probe.convert(probe.bounds, to: host)
                let x = xBand == "left" ? probe.bounds.minX + 4 : xBand == "right" ? probe.bounds.maxX - 4 : probe.bounds.midX
                let y = yBand == "low" ? probe.bounds.minY + 4 : yBand == "high" ? probe.bounds.maxY - 4 : probe.bounds.midY
                let point = probe.convert(NSPoint(x: x, y: y), to: nil)
                eventNumber += 2
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber - 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0))
                window.sendEvent(down)
                window.sendEvent(up)
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let dismissed = store.tasks.first?.loopWarning == nil
                if xBand == "center", yBand == "center" {
                    XCTAssertTrue(dismissed, "The synthetic warning button must respond at its center.")
                }
                results.append(["variant": variant, "theme": theme, "xBand": xBand, "yBand": yBand,
                                "buttonFrame": rectangle(buttonFrame),
                                "pointInWindow": [Double(point.x), Double(point.y)], "dismissed": dismissed])
                try writeJSON(results, to: destination.appendingPathComponent("fixed-hit-tests.json"))
              }
            }
        }
    }
}
