import AppKit
import SwiftUI

/// Invisible, non-interactive geometry markers used only in a disposable CI copy.
@MainActor
struct ScrollWideCardProbe: NSViewRepresentable {
    let taskID: String
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) { view.taskID = taskID }
    final class Probe: NSView {
        var taskID = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor
struct ScrollWideButtonProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) { }
    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
