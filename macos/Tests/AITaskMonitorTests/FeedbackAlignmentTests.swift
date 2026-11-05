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
        let pasteboard = NSPasteboard.general // Isolated ephemeral CI runner only.
        defer { pasteboard.clearContents() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("synthetic sentinel", forType: .string))
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(pasteboard.string(forType: .string), FeedbackDraft.email)

        // Exercise all four edges and corners, not just the accessibility frame.
        for dx in [-12, 0, 12] as [CGFloat] {
            for dy in [-12, 0, 12] as [CGFloat] {
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("synthetic sentinel", forType: .string))
                let screen = NSPoint(x: screenFrame.midX + dx, y: screenFrame.midY + dy)
                let location = window.convertPoint(fromScreen: screen)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                    modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                window.sendEvent(down)
                window.sendEvent(up)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                XCTAssertEqual(pasteboard.string(forType: .string), FeedbackDraft.email,
                               "Click failed at button offset (\(dx), \(dy)).")
            }
        }
    }
}
