import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

/// Opt-in visual diagnostics on a disposable CI runner with synthetic tasks only.
final class WindowLayoutAuditTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("Window layout audit runs only on an ephemeral GitHub-hosted runner.")
        }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticLayoutAudit", code: 1)
        }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    @MainActor private func render(_ host: NSView, to url: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "SyntheticLayoutAudit", code: 2)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SyntheticLayoutAudit", code: 3)
        }
        try png.write(to: url, options: .atomic)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func openWindow(host: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    @MainActor private func rect(_ value: NSRect) -> [Double] {
        [value.origin.x, value.origin.y, value.width, value.height].map { Double($0) }
    }

    @MainActor func testSyntheticScrollerLayoutAndDialog() throws {
        let destination = try fixtureDirectory()
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        let baseline = ProcessInfo.processInfo.environment["AITM_LAYOUT_BASELINE"] == "1"
        var records: [[String: Any]] = []
        for theme in ["light", "dark"] {
            for scenario in ["short", "long"] {
                for attached in [false, true] {
                    let store = scenario == "short" ? TaskStore.preview() : TaskStore.manySourcesPreview()
                    let root = RootView().environmentObject(store)
                        .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                        .frame(width: 560, height: 700)
                    let host = NSHostingView(rootView: root)
                    host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                    let window = attached ? openWindow(host: host) : nil
                    host.layoutSubtreeIfNeeded()
                    window?.displayIfNeeded()
                    if attached { RunLoop.current.run(until: Date().addingTimeInterval(1.2)) }
                    let name = "\(scenario)-\(theme)-\(attached ? "attached" : "unattached").png"
                    try render(host, to: destination.appendingPathComponent(name))
                    let probes = descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }
                    let scroll = probes.first(where: { $0.alwaysVisible })?.enclosingScrollView
                    if attached { XCTAssertNotNil(scroll, "The attached synthetic task list must expose its scroll view.") }
                    var record: [String: Any] = ["file": name, "attached": attached, "scenario": scenario,
                                                  "theme": theme, "probeCount": probes.count]
                    if let scroll {
                        record["style"] = scroll.scrollerStyle == .legacy ? "legacy" : "overlay"
                        record["legacyWidth"] = Double(NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                        record["hasScroller"] = scroll.hasVerticalScroller
                        record["autohides"] = scroll.autohidesScrollers
                        record["scrollBounds"] = rect(scroll.convert(scroll.bounds, to: host))
                        record["clipBounds"] = rect(scroll.contentView.convert(scroll.contentView.bounds, to: host))
                        if attached {
                            var chain: [[String: Any]] = []
                            var ancestor: NSView? = scroll
                            var reachedHost = false
                            while let view = ancestor, chain.count < 32 {
                                chain.append(["type": String(describing: type(of: view)),
                                              "frame": rect(view.frame), "bounds": rect(view.bounds),
                                              "frameInHost": rect(view.convert(view.bounds, to: host)),
                                              "isFlipped": view.isFlipped])
                                if view === host { reachedHost = true; break }
                                ancestor = view.superview
                            }
                            record["scrollAncestors"] = chain
                            record["ancestorsReachHost"] = reachedHost
                            XCTAssertTrue(reachedHost, "The synthetic scroll view must belong to its host.")
                        }
                        if let document = scroll.documentView {
                            record["documentBounds"] = rect(document.convert(document.bounds, to: host))
                            if attached && !baseline {
                                let clipWidth = scroll.contentView.bounds.width
                                XCTAssertGreaterThan(clipWidth, 0, "The attached task clip must have a measurable width.")
                                XCTAssertEqual(document.bounds.width, clipWidth, accuracy: 0.5,
                                               "The \(scenario) task document must match the visible clip width in \(theme) mode.")
                            }
                        } else if attached && !baseline {
                            XCTFail("The attached \(scenario) task list must expose its document view.")
                        }
                        if let scroller = scroll.verticalScroller {
                            record["scrollerBounds"] = rect(scroller.convert(scroller.bounds, to: host))
                            record["scrollerHidden"] = scroller.isHidden
                            record["scrollerEnabled"] = scroller.isEnabled
                            record["knobProportion"] = Double(scroller.knobProportion)
                        }
                    }
                    records.append(record)
                    window?.close()
                }
            }
            let store = TaskStore.preview()
            store.setPreviewUpdate()
            let root = RootView().environmentObject(store)
                .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                .frame(width: 560, height: 700)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            let window = openWindow(host: host)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            try render(host, to: destination.appendingPathComponent("update-ru-\(theme).png"))
            window.close()
        }
        let report = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: destination.appendingPathComponent("scroller-geometry.json"), options: .atomic)
    }

    @MainActor func testSyntheticActualSettingsMenusAndJournalButtons() throws {
        let destination = try fixtureDirectory()
        let baseline = ProcessInfo.processInfo.environment["AITM_LAYOUT_BASELINE"] == "1"
        _ = NSApplication.shared
        defer { AppLanguage.previewOverride = nil }
        var records: [[String: Any]] = []
        for language in [AppLanguage.ru, .en] {
            AppLanguage.previewOverride = language
            for theme in ["light", "dark"] {
                let suiteName = "AITaskMonitor.synthetic-settings." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
                defer { defaults.removePersistentDomain(forName: suiteName) }
                let store = TaskStore.preview()
                store.showsSettings = true
                let view = RootView().environmentObject(store)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    .environment(\.settingsPreviewClaude, .unconfirmed)
                    .environment(\.settingsPreviewCloud, .disconnected)
                    .environment(\.settingsPreviewKimi, .disconnected)
                    .environment(\.settingsPreviewHermes, .absent)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let window = openWindow(host: host)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                let probe = try XCTUnwrap(descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }.first)
                let scroll = try XCTUnwrap(probe.enclosingScrollView)
                let document = try XCTUnwrap(scroll.documentView)
                func orderedMenus() -> [NSPopUpButton] {
                    descendants(host).compactMap { $0 as? NSPopUpButton }
                        .filter { [7, 8, 10, 30, 100].contains($0.numberOfItems) }
                        .sorted {
                            let first = $0.convert($0.bounds, to: document)
                            let second = $1.convert($1.bounds, to: document)
                            return document.isFlipped ? first.minY < second.minY : first.maxY > second.maxY
                        }
                }
                let menus = orderedMenus()
                XCTAssertEqual(menus.count, 6, "The synthetic settings must expose all six journal and loop menus.")
                guard menus.count == 6 else { continue }
                XCTAssertEqual(menus.map(\.numberOfItems), [7, 10, 30, 100, 8, 30])
                let fittedMaximum = menus.map { $0.fittingSize.width }.max() ?? 0
                XCTAssertGreaterThan(fittedMaximum, 0)
                // On the measured macOS 15 runner the 120 pt visible control has a 130 pt NSView frame.
                var expectedWidth: CGFloat = 130
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) { expectedWidth = fittedMaximum }
                #endif
                if !baseline {
                    for menu in menus {
                        XCTAssertEqual(menu.bounds.width, expectedWidth, accuracy: 0.5,
                                       "The actual settings menu must match the widest fitted menu.")
                    }
                }
                func scrollTo(_ menu: NSPopUpButton) {
                    let frame = menu.convert(menu.bounds, to: document)
                    let clipHeight = scroll.contentView.bounds.height
                    let proposed = document.isFlipped ? frame.minY - 100 : frame.maxY - clipHeight + 100
                    let y = min(max(0, proposed), max(0, document.bounds.height - clipHeight))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                }
                let names = language == .ru ? ["Открыть журнал", "Очистить"] : ["Open journal", "Clear"]
                var captures: [[String: Any]] = []
                for (label, anchor) in [("journal", menus[0]), ("loop", menus[4])] {
                    scrollTo(anchor)
                    let name = "settings-menus-\(language.rawValue)-\(theme)-\(label).png"
                    try render(host, to: destination.appendingPathComponent(name))
                    let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                    let menuData: [[String: Any]] = menus.enumerated().map { index, menu in
                        let frame = menu.convert(menu.bounds, to: host)
                        return ["row": index + 1, "frame": rect(frame), "fittingWidth": Double(menu.fittingSize.width),
                                "fullyVisible": clip.contains(frame), "itemCount": menu.numberOfItems]
                    }
                    let buttons: [[String: Any]] = descendants(host).compactMap { $0 as? NSButton }
                        .filter { names.contains($0.title) }.map { button in
                            ["title": button.title, "frame": rect(button.convert(button.bounds, to: host))]
                        }
                    captures.append(["file": name, "clip": rect(clip), "menus": menuData, "journalButtons": buttons])
                }
                scrollTo(menus[0])
                let before = store.diagnosticSettings.retentionDays
                let target = before == 1 ? 2 : 1
                menus[0].selectItem(at: target - 1)
                let actionSent = menus[0].sendAction(menus[0].action, to: menus[0].target)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                let after = store.diagnosticSettings.retentionDays
                records.append(["language": language.rawValue, "theme": theme, "mode": baseline ? "baseline" : "candidate",
                                "expectedWidth": Double(expectedWidth), "fittedMaximum": Double(fittedMaximum),
                                "captures": captures,
                                "syntheticSelection": ["before": before, "requested": target,
                                                       "after": after, "actionSent": actionSent]])
            }
        }
        let report = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try report.write(to: destination.appendingPathComponent("settings-menu-geometry.json"), options: .atomic)
    }

    @MainActor func testDownloadAndLaterSyntheticClicks() throws {
        let destination = try fixtureDirectory()
        let mode = ProcessInfo.processInfo.environment["AITM_LAYOUT_BASELINE"]
        guard mode == nil || mode == "1" else {
            XCTFail("Unknown synthetic layout test mode.")
            return
        }
        let baseline = mode == "1"
        let horizontalOffsets: [CGFloat] = [-70, 0, 70]
        let verticalOffsets: [CGFloat] = [-15, 0, 15]
        var records: [[String: Any]] = []
        for control in ["download", "later"] {
            let centerX: CGFloat = control == "download" ? 363 : 196.5
            for dx in horizontalOffsets {
                for dy in verticalOffsets {
                    records.append([
                        "control": control,
                        "offsetX": Double(dx), "offsetY": Double(dy),
                        "pointX": Double(centerX + dx), "pointY": Double(290 + dy),
                        "required": !baseline || (dx == 0 && dy == 0),
                        "windowValid": NSNull(), "responded": NSNull()
                    ])
                }
            }
        }
        var guardFixtureValid = false
        defer {
            do {
                let report: [String: Any] = ["mode": baseline ? "baseline" : "candidate",
                                             "guardFixtureValid": guardFixtureValid,
                                             "points": records]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: destination.appendingPathComponent("update-clicks.json"), options: .atomic)
            } catch {
                XCTFail("Could not write synthetic click diagnostics: \(error)")
            }
        }
        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        let store = TaskStore.preview()
        let untrusted = URL(string: "https://example.invalid/synthetic")!
        guardFixtureValid = untrusted.path.split(separator: "/").count != 6 &&
            ReleaseSelector.trustedURL(untrusted.absoluteString, tag: "v1.0.0", asset: "app.dmg", platform: "macos") == nil
        guard guardFixtureValid else {
            XCTFail("The untrusted synthetic URL must be rejected before any click.")
            return
        }
        let update = AvailableUpdate(version: "0.4.0-alpha", url: untrusted)
        let root = RootView().environmentObject(store).environment(\.colorScheme, .light)
            .frame(width: 560, height: 700)
            .overlay { UpdateDialog(update: update).environmentObject(store) }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
        let window = openWindow(host: host)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        var eventNumber = 0
        func click(_ targetWindow: NSWindow, _ point: NSPoint) throws {
            eventNumber += 2
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: targetWindow.windowNumber,
                context: nil, eventNumber: eventNumber - 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: 0.01, windowNumber: targetWindow.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0))
            targetWindow.sendEvent(down)
            targetWindow.sendEvent(up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        // The invalid URL fails the existing guard before NSWorkspace.open on the pinned source.
        var recordIndex = 0
        for dx in horizontalOffsets {
            for dy in verticalOffsets {
                let index = recordIndex
                recordIndex += 1
                let windowValid = window.isVisible && window.windowNumber > 0 && host.window === window
                records[index]["windowValid"] = windowValid
                XCTAssertTrue(windowValid, "The synthetic download window must be visible and attached.")
                guard windowValid else { continue }
                store.updateOpenError = false
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                try click(window, NSPoint(x: 363 + dx, y: 290 + dy))
                let responded = store.updateOpenError
                records[index]["responded"] = responded
                if !baseline || (dx == 0 && dy == 0) {
                    XCTAssertTrue(responded, "Download did not respond at offset (\(dx), \(dy)).")
                }
            }
        }
        window.close()
        for dx in horizontalOffsets {
            for dy in verticalOffsets {
                let index = recordIndex
                recordIndex += 1
                let laterStore = TaskStore.preview()
                laterStore.setPreviewUpdate()
                let updateVisible = laterStore.visibleUpdate != nil
                XCTAssertTrue(updateVisible, "The synthetic update must be visible before testing Later.")
                let laterRoot = RootView().environmentObject(laterStore).environment(\.colorScheme, .light)
                    .frame(width: 560, height: 700)
                let laterHost = NSHostingView(rootView: laterRoot)
                laterHost.appearance = NSAppearance(named: .aqua)
                laterHost.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                let laterWindow = openWindow(host: laterHost)
                defer { laterWindow.close() }
                laterHost.layoutSubtreeIfNeeded()
                laterWindow.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(1.2))
                let windowValid = laterWindow.isVisible && laterWindow.windowNumber > 0 && laterHost.window === laterWindow
                records[index]["windowValid"] = windowValid
                XCTAssertTrue(windowValid, "The synthetic Later window must be visible and attached.")
                guard windowValid && updateVisible else { continue }
                try click(laterWindow, NSPoint(x: 196.5 + dx, y: 290 + dy))
                let responded = laterStore.visibleUpdate == nil
                records[index]["responded"] = responded
                if !baseline || (dx == 0 && dy == 0) {
                    XCTAssertTrue(responded, "Later did not respond at offset (\(dx), \(dy)).")
                }
            }
        }
        XCTAssertEqual(recordIndex, 18, "All synthetic button points must be checked.")
    }
}
