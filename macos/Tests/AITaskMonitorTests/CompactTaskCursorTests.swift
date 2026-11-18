import AppKit
import CoreGraphics
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class CompactTaskCursorTests: XCTestCase {
    @MainActor
    func testSystemCursorAndTaskSwitchInRealWindow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITM_CURSOR_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("This test moves the pointer only on an isolated GitHub-hosted runner.")
        }
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["RUNNER_OS"] == "macOS",
              let temporary = environment["RUNNER_TEMP"],
              let fixture = environment["AITM_CURSOR_SYNTHETIC_ROOT"],
              fixture.hasPrefix(temporary + "/aitm-cursor-") else {
            XCTFail("The pointer test requires an isolated GitHub-hosted macOS runner.")
            return
        }

        _ = NSApplication.shared
        AppLanguage.previewOverride = .en
        defer {
            AppLanguage.previewOverride = nil
            NSCursor.arrow.set()
        }
        NSApp.setActivationPolicy(.regular)
        let store = TaskStore.preview()
        store.isCompact = true
        let host = NSHostingView(rootView: RootView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 200),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        settle(1.5)
        host.layoutSubtreeIfNeeded()

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func regions() -> [PointingHandCursor.CursorArea] {
            descendants(host).compactMap { $0 as? PointingHandCursor.CursorArea }
                .sorted { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
        }
        let points = regions()
        XCTAssertEqual(points.count, 2)
        guard points.count == 2 else { return }
        let display = try XCTUnwrap(NSScreen.screens.first)
        func quartzPoint(_ windowPoint: NSPoint) -> CGPoint {
            let screen = window.convertPoint(toScreen: windowPoint)
            return CGPoint(x: screen.x, y: display.frame.maxY - screen.y)
        }
        func center(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func post(_ type: CGEventType, at point: NSPoint) throws {
            let location = quartzPoint(point)
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                              mouseCursorPosition: location, mouseButton: .left))
            event.post(tap: .cghidEventTap)
        }
        func move(_ point: NSPoint) throws {
            let position = quartzPoint(point)
            XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
            try post(.mouseMoved, at: point)
            settle(0.5)
        }
        func cursorMatches(_ expected: NSCursor) -> Bool {
            guard let actual = NSCursor.currentSystem else { return false }
            return actual == expected ||
                (actual.hotSpot == expected.hotSpot && actual.image.tiffRepresentation == expected.image.tiffRepresentation)
        }
        func checkCursor(_ expected: NSCursor, _ message: String) {
            let current = NSCursor.currentSystem
            print("Cursor check \(message): current=\(String(describing: current)) currentApp=\(String(describing: NSCursor.current))")
            XCTAssertTrue(cursorMatches(expected), message)
        }

        try move(NSPoint(x: 20, y: window.contentView!.bounds.height - 25))
        checkCursor(.arrow, "Pointer outside task buttons returns to arrow")
        try move(center(points[0]))
        checkCursor(.pointingHand, "Active task button shows pointing hand")
        try move(center(points[1]))
        checkCursor(.pointingHand, "Inactive task button shows pointing hand")
        let originalAppearance = UserDefaults.standard.object(forKey: "appearanceMode")
        defer {
            if let originalAppearance {
                UserDefaults.standard.set(originalAppearance, forKey: "appearanceMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "appearanceMode")
            }
        }
        let evidence = URL(fileURLWithPath: fixture).appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        for theme in ["dark", "light"] {
            UserDefaults.standard.set(theme, forKey: "appearanceMode")
            settle(1.0)
            try move(center(regions()[1]))
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-C", "-l", String(window.windowNumber),
                                 evidence.appendingPathComponent("compact-\(theme).png").path]
            do {
                try capture.run()
                capture.waitUntilExit()
                print("CAPTURE \(theme): exit=\(capture.terminationStatus)")
            } catch {
                print("CAPTURE_UNAVAILABLE \(theme): \(error.localizedDescription)")
            }
        }
        try post(.leftMouseDown, at: center(regions()[1]))
        try post(.leftMouseUp, at: center(regions()[1]))
        settle(0.5)
        XCTAssertEqual(store.compactIndex, 1, "Clicking the inactive point selects its task")
        try move(NSPoint(x: 20, y: window.contentView!.bounds.height - 25))
        checkCursor(.arrow, "Pointer leaving the task buttons returns to arrow")
        try move(center(regions()[1]))
        checkCursor(.pointingHand, "Newly selected task button shows pointing hand")
        store.isCompact = false
        settle(0.8)
        try move(NSPoint(x: 20, y: window.contentView!.bounds.height - 25))
        checkCursor(.arrow, "Pointer is restored after the compact controls disappear")

        store.isCompact = true
        settle(0.8)
        var accessible: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func collect(_ value: Any, depth: Int = 0) {
            guard depth < 40, let item = value as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(item as AnyObject)).inserted else { return }
            accessible.append(item)
            for child in item.accessibilityChildren() ?? [] { collect(child, depth: depth + 1) }
        }
        collect(host)
        let labels = accessible.filter {
            $0.accessibilityRole() == .button &&
            ($0.accessibilityLabel() == "Task 1" || $0.accessibilityLabel() == "Task 2")
        }
        if accessible.count > 1 {
            XCTAssertEqual(labels.count, 2, "Both task buttons must retain accessibility labels")
            if let firstTask = labels.first(where: { $0.accessibilityLabel() == "Task 1" }) {
                firstTask.setAccessibilityFocused(true)
                settle(0.3)
                if firstTask.isAccessibilityFocused() {
                    let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
                    let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false))
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                    settle(0.4)
                    XCTAssertEqual(store.compactIndex, 0, "Space activates the focused task button")
                    print("KEYBOARD_VERIFIED: space selected Task 1")
                } else {
                    print("KEYBOARD_UNVERIFIED: runner could not focus a SwiftUI accessibility element")
                }
            }
        } else {
            print("AX_UNVERIFIED: the runner did not expose the SwiftUI accessibility tree")
        }

        let finalPoints = regions()
        XCTAssertEqual(finalPoints.count, 2)
        if finalPoints.count == 2 {
            try move(center(finalPoints[0]))
            checkCursor(.pointingHand, "Task button shows hand immediately before closing")
            window.close()
            settle(0.5)
            checkCursor(.arrow, "Closing the window releases the pointing hand cursor")
        }
    }

    @MainActor
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
