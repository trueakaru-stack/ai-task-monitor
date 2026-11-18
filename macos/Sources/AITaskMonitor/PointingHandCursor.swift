import AppKit
import SwiftUI

struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorArea { CursorArea(frame: .zero) }

    func updateNSView(_ view: CursorArea, context: Context) {}

    final class CursorArea: NSView {
        private static var hoveredAreas: Set<ObjectIdentifier> = []
        private var trackingArea: NSTrackingArea?
        private var hovering = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            if let trackingArea { removeTrackingArea(trackingArea) }
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
            if newWindow !== window { stopHovering() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func synchronizeCursor() {
            guard let window, window.isVisible else {
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
