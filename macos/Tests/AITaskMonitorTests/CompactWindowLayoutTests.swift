import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class CompactWindowLayoutTests: XCTestCase {
    @MainActor
    func testCompactWindowSizesToContentAndKeepsItsBottomEdge() throws {
        _ = NSApplication.shared
        let store = TaskStore.loopPreview(unavailableSources: [.claude])
        store.isCompact = true
        let host = NSHostingView(rootView: RootView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let title = try XCTUnwrap(descendants(host).compactMap { $0 as? TruncatingTextField }
            .first { $0.stringValue == store.tasks[0].title })
        XCTAssertEqual(try XCTUnwrap(title.font).pointSize, 16, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(title.bounds.height, title.intrinsicContentSize.height - 1)
        let warningHeight = window.frame.height
        let bottom = window.frame.minY
        let right = window.frame.maxX
        XCTAssertGreaterThan(warningHeight, 150)

        store.compactIndex = 1
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        XCTAssertLessThan(window.frame.height, warningHeight - 10, "Removing a warning must remove its reserved height")
        XCTAssertLessThan(window.frame.height, 182, "Compact content must not leave the old empty area below")
        XCTAssertEqual(window.frame.minY, bottom, accuracy: 1)
        XCTAssertEqual(window.frame.maxX, right, accuracy: 1)
        let nextTitle = try XCTUnwrap(descendants(host).compactMap { $0 as? TruncatingTextField }
            .first { $0.stringValue == store.tasks[1].title })
        XCTAssertEqual(try XCTUnwrap(nextTitle.font).pointSize, 16, accuracy: 0.01)
        let titleRect = host.convert(nextTitle.bounds, from: nextTitle)
        XCTAssertTrue(host.bounds.insetBy(dx: 0, dy: -1).contains(titleRect), "The task title must remain visible after resizing")

        window.setFrameOrigin(NSPoint(x: 120, y: 200))
        let movedBottom = window.frame.minY
        let movedRight = window.frame.maxX
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        store.compactIndex = 0
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        XCTAssertGreaterThan(window.frame.height, 182, "Restoring a warning must restore its required height")
        XCTAssertEqual(window.frame.minY, movedBottom, accuracy: 1, "Resizing must respect a manually moved window")
        XCTAssertEqual(window.frame.maxX, movedRight, accuracy: 1)
    }
}
