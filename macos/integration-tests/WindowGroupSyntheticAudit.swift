import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI

// CI-only helper: the application's real WindowGroup renders synthetic data.
enum SyntheticWindowGroupAudit {
    private enum FixtureError: Error { case unsafeEnvironment, unsafeRoot, writeFailed, bitmap }

    private static func makeOutput() throws -> URL {
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

    private static func write(_ data: Data, name: String, in output: URL) throws {
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

    private static func save(_ bitmap: NSBitmapImageRep, name: String, in output: URL) throws {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FixtureError.bitmap }
        try write(png, name: name, in: output)
    }

    @MainActor private static func onCyan(_ source: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let margin = 24
        let width = source.pixelsWide + margin * 2, height = source.pixelsHigh + margin * 2
        guard let result = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw FixtureError.bitmap }
        result.size = NSSize(width: CGFloat(width), height: CGFloat(height))
        guard let context = NSGraphicsContext(bitmapImageRep: result) else { throw FixtureError.bitmap }
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


    private static var output: URL?
    private static var scheduled = false

    @MainActor static func prepare() -> Bool {
        let mode = ProcessInfo.processInfo.environment["AITM_SYNTHETIC_APPEARANCE"]
        let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"]
        guard (mode == "light" || mode == "dark"), (variant == "baseline" || variant == "ignore-top") else { return false }
        do {
            output = try makeOutput()
            AppLanguage.previewOverride = .ru
            return true
        } catch {
            return false
        }
    }

    @MainActor static func makeStore() -> TaskStore {
        guard let output else { fatalError("Synthetic output not initialized") }
        let item = MonitoredTask(id: "deepseek:synthetic", provider: .deepseek,
            title: tr("Проверка задачи", "Synthetic task"),
            activity: tr("Статус не подтверждён", "Status unconfirmed"), isActive: false,
            progress: nil, progressKind: .none, steps: [], updatedAt: Date(), isUnconfirmed: true)
        let store = TaskStore(codexReader: CodexTaskReader(codexHome: output.appendingPathComponent("fake-codex")),
                              claudeReader: ClaudeTaskReader(eventFile: output.appendingPathComponent("fake-events")),
                              previewTasks: [item],
                              discoverDeepSeekContext: { nil }, discoverHermesContext: { nil })
        store.testSetExternalAvailability(previous: [item],
            unavailable: [.codex, .claude, .kimi, .deepseek, .hermes, .opencode],
            partiallyUnavailable: [.deepseek, .hermes, .opencode])
        store.isCompact = true
        return store
    }

    @MainActor static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            do {
                guard let output,
                      let mode = ProcessInfo.processInfo.environment["AITM_SYNTHETIC_APPEARANCE"] else {
                    throw FixtureError.unsafeEnvironment
                }
                let windows = NSApplication.shared.windows.filter {
                    $0.isVisible && $0.windowNumber > 0 && $0.frame.width >= 100 && $0.frame.height >= 80
                }
                guard windows.count == 1, let window = windows.first else { throw FixtureError.bitmap }
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let ownID = CGWindowID(window.windowNumber)
                FileHandle.standardError.write(Data("WindowGroup own-window capture: \(mode)\n".utf8))
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID, [.bestResolution]) else {
                    throw FixtureError.bitmap
                }
                let full = NSBitmapImageRep(cgImage: image)
                try save(full, name: "windowgroup-\(mode)-system-shadow.png", in: output)
                try save(onCyan(full), name: "windowgroup-\(mode)-system-shadow-cyan.png", in: output)
                let content = window.contentView
                let insets = content?.safeAreaInsets ?? NSEdgeInsetsZero
                let layout = window.contentLayoutRect
                var row: [String: Any] = ["mode": mode,
                    "variant": ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"] ?? "",
                    "windowHasShadow": window.hasShadow, "windowIsOpaque": window.isOpaque,
                    "backingScale": Double(window.backingScaleFactor),
                    "windowPoints": [Double(window.frame.width), Double(window.frame.height)],
                    "contentPoints": [Double(content?.bounds.width ?? 0), Double(content?.bounds.height ?? 0)],
                    "contentSafeInsets": [Double(insets.top), Double(insets.left), Double(insets.bottom), Double(insets.right)],
                    "contentLayoutRect": [Double(layout.minX), Double(layout.minY), Double(layout.width), Double(layout.height)],
                    "imagePixels": [full.pixelsWide, full.pixelsHigh]]
                if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID,
                                                       [.bestResolution, .boundsIgnoreFraming]) {
                    let bounded = NSBitmapImageRep(cgImage: image)
                    try save(bounded, name: "windowgroup-\(mode)-bounds.png", in: output)
                    try save(onCyan(bounded), name: "windowgroup-\(mode)-bounds-cyan.png", in: output)
                    row["boundsPixels"] = [bounded.pixelsWide, bounded.pixelsHigh]
                }
                let report = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
                try write(report, name: "windowgroup-\(mode)-report.json", in: output)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Synthetic WindowGroup capture failed.\n".utf8))
                exit(1)
            }
        }
    }
}
