import AppKit
import CoreGraphics
import SwiftUI

@MainActor
enum CursorIntegrationHarness {
    static func focusHelper() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 650, y: 300, width: 160, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Synthetic focus helper"
        let input = NSTextField(frame: NSRect(x: 10, y: 30, width: 140, height: 28))
        input.stringValue = "Example"
        window.contentView?.addSubview(input)
        DispatchQueue.main.async {
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        app.run()
        return 0
    }

    static func run(fixture: String) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              let temp = environment["RUNNER_TEMP"], fixture.hasPrefix(temp + "/aitm-cursor-") else {
            print("BLOCKED: This harness runs only on an isolated GitHub-hosted macOS runner")
            return 2
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let hideItem = NSMenuItem(title: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = app
        applicationMenu.addItem(hideItem)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        app.mainMenu = menu
        AppLanguage.previewOverride = .en
        let store = TaskStore.preview()
        store.isCompact = true
        let host = NSHostingView(rootView: RootView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.acceptsMouseMovedEvents = true
        let evidence = URL(fileURLWithPath: fixture).appendingPathComponent("evidence", isDirectory: true)
        var status: Int32 = 1
        Task { @MainActor in
            var failures = 0
            func check(_ value: Bool, _ description: String) {
                print("\(value ? "PASS" : "FAIL"): \(description)")
                if !value { failures += 1 }
            }
            func pause(_ seconds: Double = 0.6) async {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            func points() -> [PointingHandCursor.CursorArea] {
                descendants(host).compactMap { $0 as? PointingHandCursor.CursorArea }
                    .sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
            }
            func center(_ view: NSView) -> NSPoint {
                view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            }
            func quartz(_ p: NSPoint) -> CGPoint {
                let screenPoint = window.convertPoint(toScreen: p)
                return CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
            }
            func post(_ type: CGEventType, _ p: NSPoint) {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                          mouseCursorPosition: quartz(p), mouseButton: .left) else {
                    check(false, "Create pointer event")
                    return
                }
                if type == .leftMouseDown || type == .leftMouseUp {
                    event.setIntegerValueField(.mouseEventClickState, value: 1)
                }
                event.post(tap: .cghidEventTap)
            }
            func move(_ p: NSPoint) async {
                check(CGWarpMouseCursorPosition(quartz(p)) == .success, "Move system pointer")
                post(.mouseMoved, p)
                await pause()
            }
            func cursor(_ expected: NSCursor) -> Bool {
                guard let current = NSCursor.currentSystem else { return false }
                return current == expected ||
                    (current.hotSpot == expected.hotSpot && current.image.tiffRepresentation == expected.image.tiffRepresentation)
            }
            func capture(_ theme: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-C", "-l", String(window.windowNumber),
                                     evidence.appendingPathComponent("compact-\(theme).png").path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    print("CAPTURE \(theme): \(process.terminationStatus)")
                } catch { print("CAPTURE_UNAVAILABLE: \(error)") }
            }
            defer {
                window.close()
                app.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(event, atStart: false)
                }
            }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await pause(2)
            print("WINDOW_STATE active=\(app.isActive) key=\(window.isKeyWindow)")
            guard app.isActive && window.isKeyWindow else {
                print("BLOCKED: app window could not become active and key")
                status = 2
                return
            }
            let initial = points()
            check(initial.count == 2, "Two task buttons exist")
            guard initial.count == 2 else { status = 1; return }
            NSCursor.pointingHand.set()
            await pause(0.2)
            check(cursor(.pointingHand), "System cursor positive control")
            NSCursor.arrow.set()
            await move(center(initial[0]))
            check(cursor(.pointingHand), "Active task button shows system pointing hand")
            await move(center(initial[1]))
            check(cursor(.pointingHand), "Inactive task button shows system pointing hand")
            await move(center(initial[0]))
            check(cursor(.pointingHand), "Returning directly to the first point keeps the hand")
            for theme in ["dark", "light"] {
                UserDefaults.standard.set(theme, forKey: "appearanceMode")
                await pause(1)
                let current = points()
                if current.count == 2 {
                    await move(center(current[1]))
                    check(cursor(.pointingHand), "Cursor remains hand in \(theme) theme")
                    capture(theme)
                }
            }
            if points().count == 2 {
                let target = center(points()[1])
                post(.leftMouseDown, target)
                post(.leftMouseUp, target)
                await pause()
                check(store.compactIndex == 1, "System click selects the other task")
            }
            if let title = descendants(host).compactMap({ $0 as? TruncatingTextField }).first {
                await move(center(title))
                check(cursor(.arrow), "Moving to the neighboring task title restores arrow")
            } else { print("UNVERIFIED: task title view not found") }
            let outside = NSPoint(x: 20, y: window.contentView!.bounds.height - 25)
            await move(outside)
            check(cursor(.arrow), "Leaving the task points restores arrow")
            if points().count == 2 {
                await move(center(points()[1]))
                let handBeforeMiniaturize = cursor(.pointingHand)
                check(handBeforeMiniaturize, "Hand shown before minimizing")
                window.miniaturize(nil)
                await pause(1)
                if window.isMiniaturized && handBeforeMiniaturize {
                    check(cursor(.arrow), "Minimizing restores arrow without moving")
                    window.deminiaturize(nil)
                    app.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    await pause(1)
                } else {
                    print("UNVERIFIED: window did not minimize or hand precondition was absent")
                }
            }
            if points().count == 2 {
                await move(center(points()[1]))
                let handBeforeHide = cursor(.pointingHand)
                check(handBeforeHide, "Hand shown before Cmd+H")
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                await pause(1)
                if app.isHidden && handBeforeHide {
                    check(cursor(.arrow), "Cmd+H restores arrow without moving")
                    app.unhide(nil)
                    app.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    await pause(1)
                } else {
                    print("UNVERIFIED: Cmd+H did not hide the app or hand precondition was absent")
                }
            }
            if points().count == 2 {
                await move(center(points()[1]))
                let handBeforeRemoval = cursor(.pointingHand)
                check(handBeforeRemoval, "Hand shown immediately before removing points")
                store.isCompact = false
                await pause(1)
                if handBeforeRemoval {
                    check(cursor(.arrow), "Removing the points restores arrow without moving")
                } else { print("UNVERIFIED: removal restoration requires a prior hand cursor") }
            }
            store.isCompact = true
            await pause(1)
            var accessible: [any NSAccessibilityProtocol] = []
            var visited: Set<ObjectIdentifier> = []
            func collect(_ value: Any, depth: Int = 0) {
                guard depth < 40, let item = value as? any NSAccessibilityProtocol,
                      visited.insert(ObjectIdentifier(item as AnyObject)).inserted else { return }
                accessible.append(item)
                for child in item.accessibilityChildren() ?? [] { collect(child, depth: depth + 1) }
            }
            collect(host)
            let taskButtons = accessible.filter {
                $0.accessibilityRole() == .button &&
                ($0.accessibilityLabel() == "Task 1" || $0.accessibilityLabel() == "Task 2")
            }
            if accessible.count <= 1 {
                print("UNVERIFIED: SwiftUI accessibility tree not exposed")
            } else {
                check(taskButtons.count == 2, "Both task buttons retain accessibility labels")
                if let first = taskButtons.first(where: { $0.accessibilityLabel() == "Task 1" }) {
                    first.setAccessibilityFocused(true)
                    await pause()
                    if first.isAccessibilityFocused() {
                        CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap)
                        CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
                        await pause()
                        check(store.compactIndex == 0, "Space activates the focused task button")
                    } else { print("UNVERIFIED: keyboard focus unavailable") }
                }
            }
            if points().count == 2 {
                await move(outside)
                await move(center(points()[0]))
                check(cursor(.pointingHand), "Hand shown before switching to another application")
            }
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            helper.arguments = ["--cursor-focus-helper"]
            do {
                try helper.run()
                await pause(2)
                if !app.isActive && !window.isKeyWindow && points().count == 2 {
                    print("INACTIVE_WINDOW_STATE active=false key=false")
                    check(cursor(.pointingHand), "Hand persists when app becomes inactive under pointer")
                    await move(outside)
                    check(cursor(.arrow), "Leaving points in inactive window restores arrow")
                    await move(center(points()[0]))
                    print("INACTIVE_CURSOR system=\(String(describing: NSCursor.currentSystem)) app=\(NSCursor.current)")
                    let inactiveHand = cursor(.pointingHand)
                    check(inactiveHand, "Inactive floating window shows pointing hand")
                    if !inactiveHand {
                        NSCursor.pointingHand.set()
                        await pause()
                        print("DIRECT_INACTIVE_SET hand=\(cursor(.pointingHand))")
                    }
                    check(!app.isActive && !window.isKeyWindow, "Hover on the floating window does not steal focus")
                    let helperInput = window.convertPoint(fromScreen: NSPoint(x: 730, y: 344))
                    await move(helperInput)
                    check(cursor(.iBeam), "Moving into another app text field restores its I-beam")
                    check(!app.isActive && !window.isKeyWindow, "Hover does not focus the floating window")
                } else {
                    print("UNVERIFIED: could not activate separate focus helper")
                }
            } catch { print("UNVERIFIED: could not launch focus helper: \(error)") }
            if helper.isRunning { helper.terminate() }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await pause(1)
            if points().count == 2 && app.isActive && window.isKeyWindow {
                await move(center(points()[0]))
                let handBeforeClose = cursor(.pointingHand)
                check(handBeforeClose, "Task point shows hand immediately before closing")
                window.close()
                await pause(1)
                if handBeforeClose {
                    check(cursor(.arrow), "Closing window releases pointing hand without moving")
                } else { print("UNVERIFIED: close restoration requires a prior hand cursor") }
            } else {
                print("UNVERIFIED: unable to reactivate window for close check")
            }
            status = failures == 0 ? 0 : 1
            print("RESULT failures=\(failures)")
        }
        app.run()
        return status
    }
}
