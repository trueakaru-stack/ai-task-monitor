import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class FeedbackAlignmentTests: XCTestCase {
    @MainActor
    func testCopyButtonBoundsAndAccessibilityAtSettingsEnd() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITM_FEEDBACK_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("This test uses only an ephemeral GitHub-hosted runner and its synthetic clipboard.")
        }
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["RUNNER_OS"] == "macOS",
              let temporary = environment["RUNNER_TEMP"],
              let fixture = environment["AITM_FEEDBACK_SYNTHETIC_ROOT"],
              fixture.hasPrefix(temporary + "/aitm-feedback-") else {
            XCTFail("The opt-in test requires an ephemeral GitHub-hosted macOS runner and isolated fixture.")
            return
        }
        _ = NSApplication.shared
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let store = TaskStore.preview()
        store.showsSettings = true
        let root = RootView().environmentObject(store).environment(\.settingsPreviewEnd, true)
            .frame(width: 560, height: 700)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()

        var accessibilityElements: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func collect(_ value: Any, depth: Int = 0) {
            guard depth < 40 else { return }
            guard let item = value as? any NSAccessibilityProtocol else {
                print("Synthetic AX nonconforming node at depth \(depth): \(type(of: value))")
                return
            }
            guard visited.insert(ObjectIdentifier(item as AnyObject)).inserted else { return }
            accessibilityElements.append(item)
            let children = item.accessibilityChildren() ?? []
            print("Synthetic AX node depth=\(depth) type=\(type(of: value)) role=\(String(describing: item.accessibilityRole())) children=\(children.count)")
            for child in children {
                collect(child, depth: depth + 1)
            }
        }
        collect(host)
        guard accessibilityElements.count > 1 else {
            throw XCTSkip("The synthetic hosting view exposes no AX children on this runner; accessibility is unverified.")
        }
        let buttons = accessibilityElements.filter {
            $0.accessibilityLabel() == "Copy email address" || $0.accessibilityTitle() == "Copy email address"
        }
        XCTAssertEqual(buttons.count, 1, "There must be exactly one accessible copy button.")
        let button = try XCTUnwrap(buttons.first, "The copy button must remain visible to accessibility.")
        XCTAssertEqual(button.accessibilityRole(), .button)
        let screenFrame = button.accessibilityFrame()
        let localFrame = host.convert(window.convertFromScreen(screenFrame), from: nil)
        print("Synthetic feedback button frame: \(localFrame)")
        if environment["AITM_FEEDBACK_BASELINE"] == "1" { return }
        XCTAssertEqual(localFrame.width, 28, accuracy: 0.5)
        XCTAssertEqual(localFrame.height, 28, accuracy: 0.5)
        XCTAssertEqual(localFrame.midX, 188, accuracy: 1.0, "The 28 pt button must be centered on the unchanged icon.")
        let overlappingImages = accessibilityElements.filter {
            $0.accessibilityRole() == .image && $0.accessibilityFrame().intersects(screenFrame)
        }
        XCTAssertTrue(overlappingImages.isEmpty, "A hidden layout symbol must not create a second accessible element.")
        for dx in [-12, 0, 12] as [CGFloat] {
            let point = NSPoint(x: screenFrame.midX + dx, y: screenFrame.midY)
            let hit = host.accessibilityHitTest(point) as? any NSAccessibilityProtocol
            XCTAssertEqual(hit?.accessibilityLabel(), "Copy email address", "The target must span the button width.")
        }
    }

    @MainActor
    func testCopyButtonAcceptsSyntheticMouseClicks() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITM_FEEDBACK_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("This test uses only an ephemeral GitHub-hosted runner and its synthetic clipboard.")
        }
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true",
              environment["RUNNER_ENVIRONMENT"] == "github-hosted",
              environment["RUNNER_OS"] == "macOS",
              let temporary = environment["RUNNER_TEMP"],
              let fixture = environment["AITM_FEEDBACK_SYNTHETIC_ROOT"],
              fixture.hasPrefix(temporary + "/aitm-feedback-") else {
            XCTFail("The opt-in test requires an ephemeral GitHub-hosted macOS runner and isolated fixture.")
            return
        }
        _ = NSApplication.shared
        AppLanguage.previewOverride = .en
        defer { AppLanguage.previewOverride = nil }
        let store = TaskStore.preview()
        store.showsSettings = true
        let root = RootView().environmentObject(store).environment(\.settingsPreviewEnd, true)
            .frame(width: 560, height: 700)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()

        let symbol = NSHostingView(rootView: Image(systemName: "doc.on.doc")
            .font(.system(size: 13)).fixedSize())
        print("Synthetic intrinsic symbol size: \(symbol.fittingSize)")
        let pasteboard = NSPasteboard.general // Isolated ephemeral CI runner only.
        defer { pasteboard.clearContents() }
        var eventNumber = 0
        func click(_ point: NSPoint) throws -> Bool {
            pasteboard.clearContents()
            guard pasteboard.setString("synthetic sentinel", forType: .string) else {
                XCTFail("Unable to initialize the synthetic clipboard.")
                return false
            }
            eventNumber += 2
            let now = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: now, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber - 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                modifierFlags: [], timestamp: now + 0.01, windowNumber: window.windowNumber,
                context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 0))
            window.sendEvent(down)
            window.sendEvent(up)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            return pasteboard.string(forType: .string) == FeedbackDraft.email
        }

        // The pinned 560×700 native preview places the visible symbol around (188, 32.5)
        // in window coordinates; these clicks do not rely on the AX frame.
        let center = NSPoint(x: 188, y: 32.5)
        if environment["AITM_FEEDBACK_BASELINE"] == "1" {
            XCTAssertTrue(try click(center), "The original button must respond to the center-click control.")
            return
        }
        var failed: [NSPoint] = []
        for dx in [-12, 0, 12] as [CGFloat] {
            for dy in [-12, 0, 12] as [CGFloat] {
                let point = NSPoint(x: center.x + dx, y: center.y + dy)
                let success = try click(point)
                print("Synthetic click offset=(\(dx), \(dy)) accepted=\(success)")
                if !success { failed.append(point) }
                XCTAssertTrue(success, "Click failed at button offset (\(dx), \(dy)).")
            }
        }
        var horizontal: [Int] = []
        var vertical: [Int] = []
        for x in 170...218 {
            if try click(NSPoint(x: CGFloat(x), y: center.y)) {
                horizontal.append(x)
            }
        }
        for y in 8...57 {
            if try click(NSPoint(x: center.x, y: CGFloat(y))) {
                vertical.append(y)
            }
        }
        print("Synthetic accepted x-coordinates: \(horizontal)")
        print("Synthetic accepted y-coordinates: \(vertical)")
        XCTAssertEqual(horizontal.count, 28, "The target must cover 28 pt horizontally.")
        XCTAssertEqual(vertical.count, 28, "The target must cover 28 pt vertically.")
        if let first = horizontal.first, let last = horizontal.last {
            XCTAssertEqual(last - first + 1, horizontal.count, "The horizontal target must be continuous.")
        }
        if let first = vertical.first, let last = vertical.last {
            XCTAssertEqual(last - first + 1, vertical.count, "The vertical target must be continuous.")
        }
        XCTAssertTrue(failed.isEmpty, "The 3×3 target checks must all pass.")
    }
}
