import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class OverlayScrollerTests: XCTestCase {
    @MainActor
    func testProbeUsesOverlayWithoutDisablingVerticalScrolling() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scrollView.documentView = content
        let probe = OverlayScrollerProbe.Probe(frame: .zero)
        content.addSubview(probe)
        probe.configure()
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 100, accuracy: 0.5)
    }

    @MainActor
    func testSwiftUIScrollViewReceivesOverlayStyle() throws {
        _ = NSApplication.shared
        let view = ScrollView {
            VStack {
                ForEach(0..<30, id: \.self) { value in Text("Row \(value)") }
            }
            .background(OverlayScrollerProbe().frame(width: 0, height: 0))
        }
        .frame(width: 200, height: 100)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        XCTAssertEqual(scroll.scrollerStyle, .overlay)
        XCTAssertNotNil(scroll.documentView)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
    }

    @MainActor
    func testSettingsProbeConfiguresTheDisplayedScrollView() throws {
        _ = NSApplication.shared
        let store = TaskStore.preview()
        store.showsSettings = true
        let root = RootView().environmentObject(store).environment(\.settingsPreviewEnd, true)
            .frame(width: 560, height: 700)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let probes = descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }
        let probe = try XCTUnwrap(probes.first)
        let scroll = try XCTUnwrap(probe.enclosingScrollView)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "Settings must stay in overlay mode after layout")
        scroll.scrollerStyle = .legacy
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "The probe must recover if AppKit changes the style")
        XCTAssertTrue(scroll.hasVerticalScroller)
    }
}
