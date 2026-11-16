import AppKit
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

final class CompactWindowCornerAuditTests: XCTestCase {
    private enum FixtureError: Error { case unsafeEnvironment, unsafeRoot, writeFailed, bitmap }

    private func makeOutput() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        guard env["CI"] == "true", env["GITHUB_ACTIONS"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              env["AITM_MACOS_TEST_SANDBOX"] == "1", env["HOME"] == nil, env["CODEX_HOME"] == nil,
              let root = env["AITM_SYNTHETIC_TEST_ROOT"], let marker = env["AITM_CI_DENIED_FILE"],
              marker.hasPrefix("/Users/runner/work/_temp/aitm-profile-deny.") else {
            throw FixtureError.unsafeEnvironment
        }
        let deniedDescriptor = marker.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        let denied = errno
        if deniedDescriptor >= 0 { close(deniedDescriptor) }
        guard deniedDescriptor < 0, denied == EACCES || denied == EPERM else {
            throw FixtureError.unsafeEnvironment
        }
        let url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let task = url.deletingLastPathComponent()
        guard url.path == root, url.resolvingSymlinksInPath().path == root, url.lastPathComponent == "temp",
              task.deletingLastPathComponent().path == "/Users/runner/work/_temp",
              task.lastPathComponent.range(of: #"^aitm-card-tests\.[A-Za-z0-9]{8}$"#, options: .regularExpression) != nil else {
            throw FixtureError.unsafeRoot
        }
        var current = ""
        for component in url.path.split(separator: "/") {
            current += "/" + String(component)
            var info = stat()
            guard current.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw FixtureError.unsafeRoot
            }
        }
        let output = url.appendingPathComponent("corner-audit-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        guard output.path.hasPrefix(root + "/"),
              output.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else { throw FixtureError.unsafeRoot }
        return output
    }

    private func write(_ data: Data, name: String, in output: URL) throws {
        guard name.range(of: #"^[a-z0-9-]+\.(png|json)$"#, options: .regularExpression) != nil else {
            throw FixtureError.unsafeRoot
        }
        let destination = output.appendingPathComponent(name).path
        guard destination.hasPrefix(output.path + "/") else { throw FixtureError.unsafeRoot }
        let descriptor = destination.withCString {
            open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw FixtureError.writeFailed }
        defer { close(descriptor) }
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), data.count - written)
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw FixtureError.writeFailed }
            written += count
        }
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String, in output: URL) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.bitmap }
        try write(png, name: name, in: output)
    }

    @MainActor private func onCyan(_ source: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let margin = 24
        let width = source.pixelsWide + margin * 2, height = source.pixelsHigh + margin * 2
        let result = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        result.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: result))
        let image = NSImage(size: NSSize(width: CGFloat(source.pixelsWide), height: CGFloat(source.pixelsHigh)))
        image.addRepresentation(source)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedRed: 0.0, green: 0.72, blue: 0.84, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        image.draw(in: NSRect(x: CGFloat(margin), y: CGFloat(margin), width: CGFloat(source.pixelsWide), height: CGFloat(source.pixelsHigh)),
                   from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return result
    }

    private func cornerSamples(_ bitmap: NSBitmapImageRep) -> [[String: Any]] {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        return [0, 2, 4, 8, 12, 16].flatMap { inset -> [[String: Any]] in
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

    @MainActor
    func testCaptureCompactWindowCorners() async throws {
        let output = try makeOutput()
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var report: [[String: Any]] = []
        for dark in [false, true] {
            let item = MonitoredTask(id: "deepseek:synthetic", provider: .deepseek,
                title: tr("Проверка задачи", "Synthetic task"),
                activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false,
                progress: nil, progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true)
            let store = TaskStore(codexReader: CodexTaskReader(codexHome: output.appendingPathComponent("fake-codex")),
                                  claudeReader: ClaudeTaskReader(eventFile: output.appendingPathComponent("fake-events")),
                                  previewTasks: [item])
            store.testSetExternalAvailability(previous: [item],
                unavailable: [.codex, .claude, .kimi, .deepseek, .hermes, .opencode],
                partiallyUnavailable: [.deepseek, .hermes, .opencode])
            store.isCompact = true
            let view = RootView().environmentObject(store).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 372, height: 206)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 372, height: 206),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = host
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            host.layoutSubtreeIfNeeded()
            let hostBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: hostBitmap)
            let mode = dark ? "dark" : "light"
            try save(hostBitmap, name: "host-\(mode)-transparent.png", in: output)
            try save(onCyan(hostBitmap), name: "host-\(mode)-cyan.png", in: output)
            var row: [String: Any] = [
                "mode": mode, "hostPixels": [hostBitmap.pixelsWide, hostBitmap.pixelsHigh],
                "windowSizePoints": [Double(window.frame.width), Double(window.frame.height)],
                "windowHasShadow": window.hasShadow, "windowIsOpaque": window.isOpaque,
                "hostCorners": cornerSamples(hostBitmap),
                "preflightScreenCaptureAccess": CGPreflightScreenCaptureAccess(),
                "windowCapture": "unavailable"
            ]
            #if compiler(>=6.2)
            if #available(macOS 14.4, *), CGPreflightScreenCaptureAccess(), window.windowNumber > 0 {
                do {
                    let available = try await SCShareableContent.currentProcess
                    let ownID = CGWindowID(window.windowNumber)
                    let ownPID = ProcessInfo.processInfo.processIdentifier
                    if let own = available.windows.first(where: {
                        $0.windowID == ownID && $0.owningApplication?.processID == ownPID
                    }) {
                        let filter = SCContentFilter(desktopIndependentWindow: own)
                        func capture(_ ignoreShadow: Bool) async throws -> NSBitmapImageRep {
                            let config = SCStreamConfiguration()
                            let scale = window.backingScaleFactor
                            config.width = max(1, Int(ceil(window.frame.width * scale)))
                            config.height = max(1, Int(ceil(window.frame.height * scale)))
                            config.showsCursor = false
                            config.includeChildWindows = false
                            config.shouldBeOpaque = false
                            config.backgroundColor = NSColor.clear.cgColor
                            config.ignoreShadowsSingleWindow = ignoreShadow
                            config.ignoreGlobalClipSingleWindow = true
                            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                            return NSBitmapImageRep(cgImage: image)
                        }
                        let withShadow = try await capture(false), withoutShadow = try await capture(true)
                        try save(withShadow, name: "window-\(mode)-system-shadow.png", in: output)
                        try save(withoutShadow, name: "window-\(mode)-no-system-shadow.png", in: output)
                        try save(onCyan(withShadow), name: "window-\(mode)-system-shadow-cyan.png", in: output)
                        try save(onCyan(withoutShadow), name: "window-\(mode)-no-system-shadow-cyan.png", in: output)
                        row["windowCapture"] = "captured"
                        row["windowCapturePixels"] = [withShadow.pixelsWide, withShadow.pixelsHigh]
                        row["systemWithShadowCorners"] = cornerSamples(withShadow)
                        row["systemWithoutShadowCorners"] = cornerSamples(withoutShadow)
                    } else {
                        row["windowCapture"] = "own_window_not_shareable"
                    }
                } catch {
                    row["windowCapture"] = "capture_failed"
                }
            } else if !CGPreflightScreenCaptureAccess() {
                row["windowCapture"] = "screen_capture_permission_unavailable"
            } else {
                row["windowCapture"] = "window_not_available"
            }
            #else
            row["windowCapture"] = "sdk_unavailable"
            #endif
            report.append(row)
            window.close()
        }
        let data = try JSONSerialization.data(withJSONObject: ["modes": report], options: [.prettyPrinted, .sortedKeys])
        try write(data, name: "corner-report.json", in: output)
        XCTAssertEqual(report.count, 2)
    }
}
