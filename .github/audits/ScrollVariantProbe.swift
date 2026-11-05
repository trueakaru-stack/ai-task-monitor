import AppKit
import SwiftUI

/// Test-only history with a finite cap to expose, rather than sustain, layout feedback.
@MainActor
enum ScrollVariantHistory {
    private(set) static var widths: [Double] = []
    private(set) static var capped = false
    private(set) static var generation: UInt64 = 0

    static func reset() { generation &+= 1; widths = []; capped = false }
    static func record(_ width: CGFloat, generation requested: UInt64) -> Bool {
        guard requested == generation else { return false }
        if let last = widths.last, abs(last - Double(width)) <= 0.5 { return false }
        guard widths.count < 12 else { capped = true; return false }
        widths.append(Double(width))
        return true
    }
}

/// Reports only the content-view width of the surrounding synthetic scroll view.
@MainActor
struct ScrollVariantClipProbe: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> Probe {
        let view = Probe(frame: .zero)
        view.generation = ScrollVariantHistory.generation
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        let binding = $width
        let generation = view.generation
        view.onWidth = { proposed in
            guard proposed.isFinite, proposed > 0, abs(binding.wrappedValue - proposed) > 0.5,
                  ScrollVariantHistory.record(proposed, generation: generation) else { return }
            DispatchQueue.main.async {
                guard ScrollVariantHistory.generation == generation else { return }
                binding.wrappedValue = proposed
            }
        }
        view.attach()
    }

    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        var generation: UInt64 = 0
        var onWidth: (@MainActor (CGFloat) -> Void)?
        private weak var clip: NSClipView?
        private var observations: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        func attach() {
            guard let target = enclosingScrollView?.contentView else { return }
            if clip !== target {
                detach()
                clip = target
                target.postsBoundsChangedNotifications = true
                target.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                observations = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
                    center.addObserver(forName: name, object: target, queue: .main) { [weak self] _ in
                        self?.reportWidth()
                    }
                }
            }
            reportWidth()
        }

        private func reportWidth() {
            guard let clip else { return }
            onWidth?(clip.bounds.width)
        }

        func detach() {
            for observation in observations { NotificationCenter.default.removeObserver(observation) }
            observations.removeAll()
            clip = nil
        }
    }
}
