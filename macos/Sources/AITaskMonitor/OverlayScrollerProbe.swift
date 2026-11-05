import AppKit
import SwiftUI

/// Keeps native scrolling while choosing the requested trackless indicator style.
struct OverlayScrollerProbe: NSViewRepresentable {
    var alwaysVisible = false

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero, alwaysVisible: alwaysVisible) }

    func updateNSView(_ view: Probe, context: Context) {
        view.alwaysVisible = alwaysVisible
        view.configure()
    }

    final class TracklessScroller: NSScroller {
        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            if isEnabled && knobProportion < 1 { drawKnob() }
        }
    }

    final class Probe: NSView {
        var alwaysVisible: Bool
        private weak var observedScrollView: NSScrollView?
        private var scrollerStyleObservation: NSKeyValueObservation?

        init(frame: NSRect, alwaysVisible: Bool = false) {
            self.alwaysVisible = alwaysVisible
            super.init(frame: frame)
        }

        required init?(coder: NSCoder) { return nil }

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
            if alwaysVisible {
                if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
                if !(scrollView.verticalScroller is TracklessScroller) {
                    scrollView.verticalScroller = TracklessScroller(frame: .zero)
                }
                scrollView.hasVerticalScroller = true
                scrollView.autohidesScrollers = true
            } else if scrollView.scrollerStyle != .overlay {
                scrollView.scrollerStyle = .overlay
            }
        }
    }
}
