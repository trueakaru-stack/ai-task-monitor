import AppKit
import SwiftUI

/// Keeps native scrolling while choosing the requested trackless indicator style.
struct OverlayScrollerProbe: NSViewRepresentable {
    var alwaysVisible = false
    var restoresOriginalScroller = false

    func makeNSView(context: Context) -> Probe {
        Probe(frame: .zero, alwaysVisible: alwaysVisible, restoresOriginalScroller: restoresOriginalScroller)
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.alwaysVisible = alwaysVisible
        view.restoresOriginalScroller = restoresOriginalScroller
        view.configure()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.stopObservingAndRestore()
    }

    final class TracklessScroller: NSScroller {
        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            if isEnabled && knobProportion < 1 { drawKnob() }
        }
    }

    final class Probe: NSView {
        var alwaysVisible: Bool
        var restoresOriginalScroller: Bool
        private weak var observedScrollView: NSScrollView?
        private var scrollerStyleObservation: NSKeyValueObservation?
        private weak var savedScrollView: NSScrollView?
        private var savedScroller: ScrollerState?
        private var dismantled = false

        private struct ScrollerState {
            let scroller: NSScroller?
            let style: NSScroller.Style
            let hasVerticalScroller: Bool
            let autohidesScrollers: Bool
        }

        init(frame: NSRect, alwaysVisible: Bool = false, restoresOriginalScroller: Bool = false) {
            self.alwaysVisible = alwaysVisible
            self.restoresOriginalScroller = restoresOriginalScroller
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
            guard !dismantled else { return }
            guard let scrollView = enclosingScrollView else {
                restoreSavedScroller()
                scrollerStyleObservation = nil
                observedScrollView = nil
                return
            }
            if observedScrollView !== scrollView {
                restoreSavedScroller()
                observedScrollView = scrollView
                scrollerStyleObservation = scrollView.observe(\.scrollerStyle, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { [weak self] in self?.configure() }
                }
            }
            if alwaysVisible {
                if restoresOriginalScroller && savedScroller == nil {
                    savedScrollView = scrollView
                    savedScroller = ScrollerState(scroller: scrollView.verticalScroller,
                        style: scrollView.scrollerStyle, hasVerticalScroller: scrollView.hasVerticalScroller,
                        autohidesScrollers: scrollView.autohidesScrollers)
                }
                if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
                if !(scrollView.verticalScroller is TracklessScroller) {
                    scrollView.verticalScroller = TracklessScroller(frame: .zero)
                }
                scrollView.hasVerticalScroller = true
                scrollView.autohidesScrollers = true
            } else {
                restoreSavedScroller()
                if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
            }
        }

        func stopObservingAndRestore() {
            dismantled = true
            scrollerStyleObservation = nil
            observedScrollView = nil
            restoreSavedScroller()
        }

        func restoreSavedScroller() {
            guard let saved = savedScroller else { return }
            let scrollView = savedScrollView
            savedScroller = nil
            savedScrollView = nil
            guard let scrollView else { return }
            scrollView.verticalScroller = saved.scroller
            scrollView.hasVerticalScroller = saved.hasVerticalScroller
            scrollView.autohidesScrollers = saved.autohidesScrollers
            if scrollView.scrollerStyle != saved.style { scrollView.scrollerStyle = saved.style }
        }
    }
}
