import AppKit
import SwiftUI

struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorArea { CursorArea(frame: .zero) }

    func updateNSView(_ view: CursorArea, context: Context) {}

    final class CursorArea: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            let cursorRect = visibleRect.intersection(bounds)
            if !cursorRect.isEmpty {
                addCursorRect(cursorRect, cursor: .pointingHand)
            }
        }
    }
}
