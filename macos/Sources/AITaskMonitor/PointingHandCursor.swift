import AppKit
import Combine
import SwiftUI

private enum TaskPointCursor {
    private static var owners: Set<UUID> = []

    static func enter(_ id: UUID) {
        guard owners.insert(id).inserted else { return }
        if owners.count == 1 {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pointingHand.set()
        }
    }

    static func leave(_ id: UUID) {
        guard owners.remove(id) != nil else { return }
        if owners.isEmpty { NSCursor.pop() }
    }

    static func contains(_ id: UUID) -> Bool { owners.contains(id) }
}

struct PointingHandCursor: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var id = UUID()
    @State private var ownerWindowNumber: Int?
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                print("HOVER_EVENT inside=\(inside) appActive=\(NSApp.isActive)")
                if inside {
                    let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
                    guard let window = NSApp.windows.first(where: { $0.windowNumber == number }),
                          window.isVisible, !window.isMiniaturized else { return }
                    ownerWindowNumber = number
                    hovering = true
                    if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                    if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                    TaskPointCursor.enter(id)
                    scheduleRefresh()
                } else {
                    releaseCursor()
                }
            }
            .onDisappear { releaseCursor() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willMiniaturizeNotification)) { releaseForWindow($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { releaseForWindow($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { releaseForWindow($0) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willHideNotification)) { _ in releaseCursor() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in releaseCursor() }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in scheduleRefresh() }
            .onChange(of: colorScheme) { _ in scheduleRefresh() }
    }

    private func releaseForWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.windowNumber == ownerWindowNumber else { return }
        releaseCursor()
    }

    private func releaseCursor() {
        guard hovering else { return }
        hovering = false
        ownerWindowNumber = nil
        TaskPointCursor.leave(id)
    }

    private func scheduleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard hovering, TaskPointCursor.contains(id), NSApp.isActive,
                  let ownerWindowNumber,
                  NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == ownerWindowNumber else { return }
            NSCursor.pointingHand.set()
        }
    }
}
