import AppKit
import ApplicationServices
import Darwin
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

    static func keyboardBaseline(fixture: String) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              let temp = environment["RUNNER_TEMP"], fixture.hasPrefix(temp + "/aitm-cursor-") else { return 2 }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        AppLanguage.previewOverride = .en
        let store = TaskStore.preview()
        store.isCompact = true
        store.compactIndex = 1
        let host = NSHostingView(rootView: RootView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        var result: Int32 = 2
        Task { @MainActor in
            defer {
                window.close()
                app.stop(nil)
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                    modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(event, atStart: false)
                }
            }
            func pause() async { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await pause()
            print("BASELINE_WINDOW active=\(app.isActive) key=\(window.isKeyWindow)")
            guard app.isActive && window.isKeyWindow else { return }
            let axApp = AXUIElementCreateApplication(getpid())
            var candidates: [AXUIElement] = []
            func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
                return value as? String
            }
            func collectAX(_ element: AXUIElement, depth: Int = 0) {
                guard depth < 30 else { return }
                let role = axString(element, kAXRoleAttribute as CFString)
                let label = axString(element, kAXTitleAttribute as CFString) ??
                    axString(element, kAXDescriptionAttribute as CFString)
                if role == "AXButton" && label == "Task 1" { candidates.append(element) }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let values = children as? [AXUIElement] {
                    for child in values { collectAX(child, depth: depth + 1) }
                }
            }
            collectAX(axApp)
            guard let target = candidates.first else {
                print("BASELINE_BLOCKED: no accessible task button")
                return
            }
            let setResult = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            await pause()
            var focusedValue: CFTypeRef?
            let readResult = AXUIElementCopyAttributeValue(target, kAXFocusedAttribute as CFString, &focusedValue)
            let focused = (focusedValue as? Bool) ?? false
            print("BASELINE_FOCUS set=\(setResult.rawValue) read=\(readResult.rawValue) focused=\(focused)")
            guard setResult == .success && focused else { return }
            print("BASELINE_INDEX_BEFORE_SPACE=\(store.compactIndex)")
            CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
            await pause()
            print("BASELINE_INDEX_AFTER_SPACE=\(store.compactIndex)")
            store.compactIndex = 1
            await pause()
            let press = AXUIElementPerformAction(target, kAXPressAction as CFString)
            await pause()
            print("BASELINE_AX_PRESS result=\(press.rawValue) index=\(store.compactIndex)")
            result = 0
        }
        app.run()
        return result
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
            let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                print("KEY_EVENT type=\(event.type.rawValue) code=\(event.keyCode) window=\(event.windowNumber)")
                return event
            }
            defer { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
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
            func points() -> [NSPoint] {
                let application = AXUIElementCreateApplication(getpid())
                var found: [String: NSPoint] = [:]
                func axText(_ element: AXUIElement, _ attribute: CFString) -> String? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
                    return value as? String
                }
                func visit(_ element: AXUIElement, depth: Int = 0) {
                    guard depth < 30 else { return }
                    let role = axText(element, kAXRoleAttribute as CFString)
                    let label = axText(element, kAXTitleAttribute as CFString) ??
                        axText(element, kAXDescriptionAttribute as CFString)
                    if role == "AXButton", let label, label == "Task 1" || label == "Task 2" {
                        var rawPosition: CFTypeRef?
                        var rawSize: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
                           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
                           let rawPosition, let rawSize,
                           CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() {
                            let posValue = unsafeBitCast(rawPosition, to: AXValue.self)
                            let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
                            var position = CGPoint.zero
                            var size = CGSize.zero
                            if AXValueGetValue(posValue, .cgPoint, &position),
                               AXValueGetValue(sizeValue, .cgSize, &size), size.width > 0, size.height > 0 {
                                let screen = NSPoint(x: position.x + size.width / 2,
                                    y: NSScreen.screens[0].frame.maxY - position.y - size.height / 2)
                                found[label] = window.convertPoint(fromScreen: screen)
                            }
                        }
                    }
                    var childrenValue: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                       let children = childrenValue as? [AXUIElement] {
                        for child in children { visit(child, depth: depth + 1) }
                    }
                }
                visit(application)
                return ["Task 1", "Task 2"].compactMap { found[$0] }
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
            await move(initial[0])
            check(cursor(.pointingHand), "Active task button shows system pointing hand")
            await move(initial[1])
            check(cursor(.pointingHand), "Inactive task button shows system pointing hand")
            await move(initial[0])
            check(cursor(.pointingHand), "Returning directly to the first point keeps the hand")
            for theme in ["dark", "light", "dark", "light"] {
                UserDefaults.standard.set(theme, forKey: "appearanceMode")
                await pause(1)
                check(cursor(.pointingHand), "Stationary hand survives change to \(theme) theme")
            }
            for theme in ["dark", "light"] {
                UserDefaults.standard.set(theme, forKey: "appearanceMode")
                await pause(1)
                let current = points()
                if current.count == 2 {
                    await move(NSPoint(x: 20, y: window.contentView!.bounds.height - 25))
                    await move(current[1])
                    check(cursor(.pointingHand), "Cursor is hand before \(theme) capture")
                    capture(theme)
                    await pause(0.3)
                    print("CAPTURE_AFTER \(theme) hand=\(cursor(.pointingHand))")
                }
            }
            if points().count == 2 {
                let target = points()[1]
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
                await move(points()[1])
                let handBeforeMiniaturize = cursor(.pointingHand)
                check(handBeforeMiniaturize, "Hand shown before minimizing")
                window.miniaturize(nil)
                await pause(1)
                if window.isMiniaturized {
                    if handBeforeMiniaturize {
                        check(cursor(.arrow), "Minimizing restores arrow without moving")
                    }
                    window.deminiaturize(nil)
                    app.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    await pause(1)
                } else {
                    print("UNVERIFIED: window did not minimize")
                }
            }
            if points().count == 2 {
                await move(points()[1])
                let handBeforeHide = cursor(.pointingHand)
                check(handBeforeHide, "Hand shown before Cmd+H")
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: true)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 4, keyDown: false)
                down?.flags = .maskCommand
                up?.flags = []
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                await pause(1)
                print("CMD_RELEASE command=\(NSEvent.modifierFlags.contains(.command))")
                check(!NSEvent.modifierFlags.contains(.command), "Command modifier is released after Cmd+H")
                if app.isHidden {
                    if handBeforeHide {
                        check(cursor(.arrow), "Cmd+H restores arrow without moving")
                    }
                    app.unhide(nil)
                    app.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    await pause(1)
                } else {
                    print("UNVERIFIED: Cmd+H did not hide the app")
                }
            }
            if points().count == 2 {
                await move(points()[1])
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
            check(points().count == 2, "Both task buttons retain accessibility labels and frames")
            if points().count == 2 {
                await move(outside)
                await move(points()[0])
                check(cursor(.pointingHand), "Hand shown before switching to another application")
            }
            let axApp = AXUIElementCreateApplication(getpid())
            var axRootChildren: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &axRootChildren)
            print("AX_SELF_RESULT \(axResult.rawValue), trusted=\(AXIsProcessTrusted())")
            var candidates: [AXUIElement] = []
            func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
                return value as? String
            }
            func collectAX(_ element: AXUIElement, depth: Int = 0) {
                guard depth < 30 else { return }
                let role = axString(element, kAXRoleAttribute as CFString)
                let label = axString(element, kAXTitleAttribute as CFString) ??
                    axString(element, kAXDescriptionAttribute as CFString)
                if role == "AXButton" && label == "Task 1" { candidates.append(element) }
                var childValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childValue) == .success,
                   let children = childValue as? [AXUIElement] {
                    for child in children { collectAX(child, depth: depth + 1) }
                }
            }
            if axResult == .success, let children = axRootChildren as? [AXUIElement] {
                for child in children { collectAX(child) }
            }
            if let target = candidates.first {
                let focusResult = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                await pause()
                var focusedValue: CFTypeRef?
                let focusRead = AXUIElementCopyAttributeValue(target, kAXFocusedAttribute as CFString, &focusedValue)
                let focused = (focusedValue as? Bool) ?? false
                print("AX_FOCUS set=\(focusResult.rawValue) read=\(focusRead.rawValue) focused=\(focused) active=\(app.isActive) key=\(window.isKeyWindow) responder=\(String(describing: window.firstResponder)) index=\(store.compactIndex)")
                if focusResult == .success && focused {
                    let spaceDown = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true)
                    let spaceUp = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false)
                    spaceDown?.flags = []
                    spaceUp?.flags = []
                    spaceDown?.post(tap: .cghidEventTap)
                    spaceUp?.post(tap: .cghidEventTap)
                    await pause()
                    var focusedAfter: CFTypeRef?
                    let readAfter = AXUIElementCopyAttributeValue(target, kAXFocusedAttribute as CFString, &focusedAfter)
                    print("KEY_AFTER focusRead=\(readAfter.rawValue) focused=\(String(describing: focusedAfter)) index=\(store.compactIndex) active=\(app.isActive) key=\(window.isKeyWindow)")
                    check(store.compactIndex == 0, "System keyboard activates the focused task button")
                } else { print("UNVERIFIED: AX focus did not move onto task button") }
                store.compactIndex = 1
                await pause()
                let pressResult = AXUIElementPerformAction(target, kAXPressAction as CFString)
                await pause()
                check(pressResult == .success && store.compactIndex == 0, "Accessibility press selects the task")
            } else { print("UNVERIFIED: no accessible Task 1 node available through AX") }
            if CommandLine.arguments.contains("--stop-after-keyboard") {
                print("BASELINE_KEYBOARD_SEQUENCE_COMPLETE")
                status = 0
                return
            }
            var activations = 0
            let activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: app, queue: .main) { _ in
                    activations += 1
                }
            defer { NotificationCenter.default.removeObserver(activationObserver) }
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            helper.arguments = ["--cursor-focus-helper"]
            do {
                try helper.run()
                await pause(2)
                if let helperApp = NSRunningApplication(processIdentifier: helper.processIdentifier) {
                    check(!app.isActive && !window.isKeyWindow,
                          "Switching apps with a stationary pointer does not cause an activation loop")
                    let helperInput = window.convertPoint(fromScreen: NSPoint(x: 730, y: 344))
                    await move(helperInput)
                    helperApp.activate(options: [.activateIgnoringOtherApps])
                    await pause(1)
                    guard let visualRoot = descendants(host).first(where: {
                        String(describing: type(of: $0)).contains("HoverActivationView")
                    }) else {
                        check(false, "Visible interface bounds are available")
                        status = 1
                        return
                    }
                    let rootHeight = visualRoot.bounds.height
                    let topY = visualRoot.isFlipped ? CGFloat(25) : rootHeight - 25
                    let cornerY = visualRoot.isFlipped ? CGFloat(1) : rootHeight - 1
                    let headerLocal = NSPoint(x: 70, y: topY)
                    let header = visualRoot.convert(headerLocal, to: nil)
                    let corner = visualRoot.convert(NSPoint(x: 1, y: cornerY), to: nil)
                    print("VISIBLE_BOUNDS root=\(visualRoot.bounds) windowContent=\(window.contentView!.bounds) headerLocal=\(headerLocal) headerWindow=\(header)")
                    let beforeCorner = activations
                    await move(corner)
                    await pause(0.4)
                    check(!app.isActive && activations == beforeCorner,
                          "Transparent rounded corner does not activate monitor")
                    func testWindowHover(_ description: String, _ target: NSPoint, hand: Bool = false) async {
                        await move(helperInput)
                        helperApp.activate(options: [.activateIgnoringOtherApps])
                        await pause(1)
                        check(!app.isActive && !window.isKeyWindow, "\(description): helper becomes active")
                        let before = activations
                        await move(target)
                        await pause(0.8)
                        check(app.isActive && window.isKeyWindow, "\(description): hover activates monitor")
                        check(activations == before + 1, "\(description): one activation")
                        await pause(0.6)
                        check(activations == before + 1, "\(description): no activation cycle")
                        check(cursor(hand ? .pointingHand : .arrow),
                              "\(description): correct cursor")
                    }
                    await testWindowHover("Header", header)
                    await testWindowHover("Background", visualRoot.convert(NSPoint(x: 25, y: 25), to: nil))
                    if let title = descendants(host).compactMap({ $0 as? TruncatingTextField }).first {
                        await testWindowHover("Task content", center(title))
                    } else { print("UNVERIFIED: task content unavailable") }
                    if points().count == 2 {
                        await testWindowHover("First point", points()[0], hand: true)
                        await testWindowHover("Second point", points()[1], hand: true)
                    } else {
                        check(false, "Task points remain accessible during activation checks")
                    }
                    await move(helperInput)
                    helperApp.activate(options: [.activateIgnoringOtherApps])
                    await pause(1)
                    let beforeRapidExit = activations
                    let rapidInside = visualRoot.convert(NSPoint(x: 30, y: 30), to: nil)
                    _ = CGWarpMouseCursorPosition(quartz(rapidInside))
                    post(.mouseMoved, rapidInside)
                    _ = CGWarpMouseCursorPosition(quartz(helperInput))
                    post(.mouseMoved, helperInput)
                    await pause(0.8)
                    check(!app.isActive && activations == beforeRapidExit,
                          "Queued hover does not activate monitor after pointer has left")
                    await move(helperInput)
                    check(cursor(.iBeam), "Moving into another app text field restores its I-beam")
                    store.isCompact = false
                    await pause(1)
                    if let expandedRoot = descendants(host).first(where: {
                        String(describing: type(of: $0)).contains("HoverActivationView")
                    }) {
                        let top = expandedRoot.isFlipped ? CGFloat(25) : expandedRoot.bounds.height - 25
                        let expandedHeader = expandedRoot.convert(NSPoint(x: 70, y: top), to: nil)
                        let expandedBackground = expandedRoot.convert(NSPoint(x: 25, y: 25), to: nil)
                        await testWindowHover("Expanded header", expandedHeader)
                        await testWindowHover("Expanded background", expandedBackground)
                    } else {
                        check(false, "Expanded interface bounds are available")
                    }
                    store.isCompact = true
                    await pause(1)
                } else {
                    print("UNVERIFIED: focus helper could not be inspected")
                }
            } catch { print("UNVERIFIED: could not launch focus helper: \(error)") }
            if helper.isRunning { helper.terminate() }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await pause(1)
            if points().count == 2 && app.isActive && window.isKeyWindow {
                await move(points()[0])
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
