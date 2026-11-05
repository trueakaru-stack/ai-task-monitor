import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

/// Opt-in comparison using one synthetic window on an ephemeral CI runner.
final class WindowShadowAuditTests: XCTestCase {
    @MainActor func testOwnWindowShadowAgainstHostBitmap() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_CAPTURE_OWN_WINDOW"] == "1" else {
            throw XCTSkip("Own-window shadow capture is opt-in.")
        }
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1", env["GITHUB_ACTIONS"] == "true",
              env["CI"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["RUNNER_OS"] == "macOS", let temporary = env["RUNNER_TEMP"],
              let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticShadowAudit", code: 1)
        }
        let destination = URL(fileURLWithPath: root, isDirectory: true)
        func writeReport(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("window-shadow.json"), options: .atomic)
        }
        func skip(_ reason: String) throws -> Never {
            try writeReport(["status": "skipped", "reason": reason])
            throw XCTSkip("Own-window shadow audit skipped: \(reason).")
        }
        #if compiler(>=6.2)
        guard #available(macOS 14.4, *) else { try skip("api_unavailable") }
        guard CGPreflightScreenCaptureAccess() else { try skip("capture_permission_unavailable") }

        _ = NSApplication.shared
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        let store = TaskStore.preview()
        let rootView = RootView().environmentObject(store).environment(\.colorScheme, .dark)
            .frame(width: 560, height: 700)
        let host = NSHostingView(rootView: rootView)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        host.layoutSubtreeIfNeeded()
        guard window.isVisible, window.windowNumber > 0,
              window.windowNumber <= Int(UInt32.max), host.window === window else {
            try skip("synthetic_window_unavailable")
        }

        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.currentProcess
        } catch {
            try skip("shareable_content_unavailable")
        }
        let ownID = CGWindowID(window.windowNumber)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let ownWindow = shareable.windows.first(where: {
            $0.windowID == ownID && $0.owningApplication?.processID == ownPID
        }) else {
            try skip("own_window_not_shareable")
        }
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
        func configuration(ignoreShadow: Bool) -> SCStreamConfiguration {
            let value = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            value.width = max(1, Int(ceil(window.frame.width * scale)))
            value.height = max(1, Int(ceil(window.frame.height * scale)))
            value.showsCursor = false
            value.includeChildWindows = false
            value.shouldBeOpaque = false
            value.backgroundColor = NSColor.clear.cgColor
            value.ignoreShadowsSingleWindow = ignoreShadow
            value.ignoreGlobalClipSingleWindow = true
            return value
        }
        let withShadow: CGImage
        let withoutShadow: CGImage
        do {
            withShadow = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                     configuration: configuration(ignoreShadow: false))
            withoutShadow = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                        configuration: configuration(ignoreShadow: true))
        } catch {
            try skip("own_window_capture_unavailable")
        }
        guard withShadow.width > 0, withShadow.height > 0, withoutShadow.width > 0, withoutShadow.height > 0,
              let hostBitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            try skip("bitmap_unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: hostBitmap)
        let systemWithShadow = NSBitmapImageRep(cgImage: withShadow)
        let systemWithoutShadow = NSBitmapImageRep(cgImage: withoutShadow)
        func save(_ bitmap: NSBitmapImageRep, as name: String) throws {
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SyntheticShadowAudit", code: 2)
            }
            try data.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        func samples(_ bitmap: NSBitmapImageRep) -> [[String: Any]] {
            let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
            return [0, 4, 8, 16].flatMap { inset -> [[String: Any]] in
                guard width > inset * 2, height > inset * 2 else { return [] }
                return [(inset, inset), (width - 1 - inset, inset),
                        (inset, height - 1 - inset), (width - 1 - inset, height - 1 - inset)].map { point in
                    let (x, y) = point
                    var value: [String: Any] = ["x": x, "y": y]
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        value["rgba"] = [Double(color.redComponent), Double(color.greenComponent),
                                         Double(color.blueComponent), Double(color.alphaComponent)]
                    }
                    return value
                }
            }
        }
        try save(hostBitmap, as: "window-shadow-host.png")
        try save(systemWithShadow, as: "window-shadow-system-with.png")
        try save(systemWithoutShadow, as: "window-shadow-system-without.png")
        try writeReport([
            "status": "captured_for_review", "windowHasShadow": window.hasShadow,
            "windowSizePoints": [Double(window.frame.width), Double(window.frame.height)],
            "hostSizePixels": [hostBitmap.pixelsWide, hostBitmap.pixelsHigh],
            "systemWithShadowSizePixels": [systemWithShadow.pixelsWide, systemWithShadow.pixelsHigh],
            "systemWithoutShadowSizePixels": [systemWithoutShadow.pixelsWide, systemWithoutShadow.pixelsHigh],
            "filteredContentRect": [Double(filter.contentRect.minX), Double(filter.contentRect.minY),
                                    Double(filter.contentRect.width), Double(filter.contentRect.height)],
            "filterPointPixelScale": Double(filter.pointPixelScale),
            "backingScale": Double(window.backingScaleFactor),
            "hostCorners": samples(hostBitmap), "systemWithShadowCorners": samples(systemWithShadow),
            "systemWithoutShadowCorners": samples(systemWithoutShadow),
            "comparison": "Inspect alignment, alpha and clipping; capture alone does not verify the installed app."
        ])
        #else
        try skip("sdk_not_verified")
        #endif
    }
}
