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

    @MainActor private func syntheticWindow(_ output: URL, dark: Bool) async throws -> (NSWindow, NSHostingView<AnyView>) {
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
        let view = AnyView(RootView().environmentObject(store).environment(\.colorScheme, dark ? .dark : .light))
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
        return (window, host)
    }

    @MainActor
    func testRenderCompactHostOnContrastingBackground() async throws {
        let output = try makeOutput()
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var rows: [[String: Any]] = []
        for dark in [false, true] {
            let (window, host) = try await syntheticWindow(output, dark: dark)
            let mode = dark ? "dark" : "light"
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try save(bitmap, name: "host-\(mode)-transparent.png", in: output)
            try save(onCyan(bitmap), name: "host-\(mode)-cyan.png", in: output)
            rows.append(["mode": mode, "hostPixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
                         "windowSizePoints": [Double(window.frame.width), Double(window.frame.height)],
                         "windowHasShadow": window.hasShadow, "windowIsOpaque": window.isOpaque,
                         "backingScale": Double(window.backingScaleFactor)])
            window.close()
        }
        let data = try JSONSerialization.data(withJSONObject: ["modes": rows], options: [.prettyPrinted, .sortedKeys])
        try write(data, name: "host-report.json", in: output)
        XCTAssertEqual(rows.count, 2)
    }

    @MainActor
    func testCaptureOnlyOwnCompactWindow() async throws {
        let output = try makeOutput()
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppLanguage.previewOverride = .ru
        defer { AppLanguage.previewOverride = nil }
        var rows: [[String: Any]] = []
        for dark in [false, true] {
            let (window, _) = try await syntheticWindow(output, dark: dark)
            let mode = dark ? "dark" : "light"
            var row: [String: Any] = ["mode": mode, "windowHasShadow": window.hasShadow,
                                      "windowCapture": "not_attempted"]
            let attempt = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try write(attempt, name: "legacy-attempt-\(mode).json", in: output)
            guard window.windowNumber > 0 else {
                row["windowCapture"] = "own_window_not_available"
                rows.append(row)
                window.close()
                break
            }
            // Only the ID of the window created above is used; never query or
            // capture the desktop or another process's windows.
            let ownID = CGWindowID(window.windowNumber)
            FileHandle.standardError.write(Data("Legacy own-window capture attempt: \(mode)\n".utf8))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID, [.bestResolution]) else {
                row["windowCapture"] = "unavailable"
                rows.append(row)
                window.close()
                break
            }
            let full = NSBitmapImageRep(cgImage: image)
            try save(full, name: "legacy-\(mode)-system-shadow.png", in: output)
            try save(onCyan(full), name: "legacy-\(mode)-system-shadow-cyan.png", in: output)
            row["windowCapture"] = "captured"
            row["windowCapturePixels"] = [full.pixelsWide, full.pixelsHigh]
            if let cropped = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID,
                                                      [.bestResolution, .boundsIgnoreFraming]) {
                let noFrame = NSBitmapImageRep(cgImage: cropped)
                try save(noFrame, name: "legacy-\(mode)-window-bounds.png", in: output)
                try save(onCyan(noFrame), name: "legacy-\(mode)-window-bounds-cyan.png", in: output)
                row["windowBoundsPixels"] = [noFrame.pixelsWide, noFrame.pixelsHigh]
            }
            rows.append(row)
            window.close()
        }
        let data = try JSONSerialization.data(withJSONObject: ["modes": rows], options: [.prettyPrinted, .sortedKeys])
        try write(data, name: "legacy-capture-report.json", in: output)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { ($0["windowCapture"] as? String) == "captured" })
    }
}
