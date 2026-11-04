import AppKit
import SwiftUI

/// Applies an overlay scroller to this scroll view without changing scroll behavior.
struct OverlayScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }

    func updateNSView(_ view: Probe, context: Context) { view.configure() }

    final class Probe: NSView {
        private weak var observedScrollView: NSScrollView?
        private var scrollerStyleObservation: NSKeyValueObservation?

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
            guard let scrollView = enclosingScrollView else {
                scrollerStyleObservation = nil
                observedScrollView = nil
                return
            }
            if observedScrollView !== scrollView {
                observedScrollView = scrollView
                scrollerStyleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.configure() }
                }
            }
            if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        }
    }
}
