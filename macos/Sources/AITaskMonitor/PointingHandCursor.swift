import AppKit
import SwiftUI

struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorArea { CursorArea(frame: .zero) }

    func updateNSView(_ view: CursorArea, context: Context) {}

    final class CursorArea: NSView {
        // Enter and exit events for neighboring points may arrive out of order.
        private static var hoveredAreas: Set<ObjectIdentifier> = []
        private var trackingArea: NSTrackingArea?
        private var hovering = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            if let trackingArea { removeTrackingArea(trackingArea) }
            // The SwiftUI hosting view can report a visibleRect larger than these bounds.
            let trackingRect = bounds.intersection(visibleRect)
            if trackingRect.isEmpty {
                trackingArea = nil
            } else {
                let area = NSTrackingArea(rect: trackingRect, options: [.mouseEnteredAndExited, .activeAlways],
                                          owner: self, userInfo: nil)
                addTrackingArea(area)
                trackingArea = area
            }
            super.updateTrackingAreas()
            synchronizeCursor()
        }

        override func mouseEntered(with event: NSEvent) { synchronizeCursor() }

        override func mouseExited(with event: NSEvent) { synchronizeCursor() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow !== window {
                if let window {
                    NotificationCenter.default.removeObserver(self, name: NSWindow.willMiniaturizeNotification, object: window)
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didMiniaturizeNotification, object: window)
                    NotificationCenter.default.removeObserver(self, name: NSWindow.didDeminiaturizeNotification, object: window)
                    NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
                }
                stopHovering()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowWillHide),
                               name: NSWindow.willMiniaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillHide),
                               name: NSWindow.didMiniaturizeNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillHide),
                               name: NSWindow.willCloseNotification, object: window)
            center.addObserver(self, selector: #selector(windowDidRestore),
                               name: NSWindow.didDeminiaturizeNotification, object: window)
        }

        @objc private func windowWillHide(_ notification: Notification) {
            stopHovering()
        }

        @objc private func windowDidRestore(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in self?.synchronizeCursor() }
        }

        private func synchronizeCursor() {
            guard let window, window.isVisible, !window.isMiniaturized else {
                stopHovering()
                return
            }
            let pointer = NSEvent.mouseLocation
            let localPoint = convert(window.convertPoint(fromScreen: pointer), from: nil)
            let inside = bounds.intersection(visibleRect).contains(localPoint) &&
                NSWindow.windowNumber(at: pointer, belowWindowWithWindowNumber: 0) == window.windowNumber
            if inside {
                startHovering()
            } else {
                stopHovering()
            }
        }

        private func startHovering() {
            guard !hovering else { return }
            hovering = true
            if Self.hoveredAreas.isEmpty { NSCursor.pointingHand.push() }
            Self.hoveredAreas.insert(ObjectIdentifier(self))
        }

        private func stopHovering() {
            guard hovering else { return }
            hovering = false
            Self.hoveredAreas.remove(ObjectIdentifier(self))
            if Self.hoveredAreas.isEmpty { NSCursor.pop() }
        }
    }
}
