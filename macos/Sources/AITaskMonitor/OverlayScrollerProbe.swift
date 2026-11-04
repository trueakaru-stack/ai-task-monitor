import AppKit
import SwiftUI

/// Applies an overlay scroller to this scroll view without changing scroll behavior.
struct OverlayScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }

    func updateNSView(_ view: Probe, context: Context) { view.configure() }

    final class Probe: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configure()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }

        override func layout() {
            super.layout()
            configure()
        }

        func configure() {
            guard let scrollView = enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
        }
    }
}
