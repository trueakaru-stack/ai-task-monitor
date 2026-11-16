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
    @MainActor private static var activeStore: TaskStore?
    @MainActor private static weak var observedWindow: NSWindow?
    @MainActor private static var resizeObserver: NSObjectProtocol?
    @MainActor private static var closeObserver: NSObjectProtocol?
    @MainActor private static var frameEvents: [[String: Any]] = []

    @MainActor static func recordWindow(_ event: String, _ window: NSWindow) {
        guard frameEvents.count < 256 else { return }
        frameEvents.append(["event": event, "time": ProcessInfo.processInfo.systemUptime,
                            "frame": [Double(window.frame.minX), Double(window.frame.minY),
                                      Double(window.frame.width), Double(window.frame.height)],
                            "minSize": [Double(window.minSize.width), Double(window.minSize.height)],
                            "maxSize": [Double(window.maxSize.width), Double(window.maxSize.height)]])
    }

    @MainActor static func observeWindow(_ window: NSWindow) {
        guard observedWindow !== window else { return }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        observedWindow = window
        recordWindow("observe", window)
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                                object: window, queue: .main) { [weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { recordWindow("resize", window) }
        }
    }


    @MainActor static func prepare() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let mode = env["AITM_SYNTHETIC_APPEARANCE"]
        let variant = env["AITM_WINDOWGROUP_VARIANT"]
        let scenario = env["AITM_WINDOWGROUP_SCENARIO"]
        guard (mode == "light" || mode == "dark"),
              (variant == "baseline" || variant == "corrected"),
              (scenario == "compact-to-full" || scenario == "full-to-compact") else { return false }
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
        store.isCompact = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_SCENARIO"] == "compact-to-full"
        activeStore = store
        return store
    }

    @MainActor private static func activeWindow() throws -> NSWindow {
        let windows = NSApplication.shared.windows.filter {
            $0.isVisible && $0.windowNumber > 0 && $0.frame.width >= 100 && $0.frame.height >= 80
        }
        guard windows.count == 1, let window = windows.first else { throw FixtureError.bitmap }
        return window
    }

    @MainActor private static func capture(_ stage: String, toggleMethod: String) throws {
        guard let output, let store = activeStore,
              let mode = ProcessInfo.processInfo.environment["AITM_SYNTHETIC_APPEARANCE"],
              let scenario = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_SCENARIO"],
              let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"] else {
            throw FixtureError.unsafeEnvironment
        }
        let window = try activeWindow()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let ownID = CGWindowID(window.windowNumber)
        FileHandle.standardError.write(Data("WindowGroup capture: \(variant) \(mode) \(scenario) \(stage)\n".utf8))
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID, [.bestResolution]) else {
            throw FixtureError.bitmap
        }
        let prefix = "windowgroup-\(stage)"
        let full = NSBitmapImageRep(cgImage: image)
        try save(full, name: "\(prefix)-system-shadow.png", in: output)
        try save(onCyan(full), name: "\(prefix)-system-shadow-cyan.png", in: output)
        let content = window.contentView
        let insets = content?.safeAreaInsets ?? NSEdgeInsetsZero
        let layout = window.contentLayoutRect
        var row: [String: Any] = ["mode": mode, "variant": variant, "scenario": scenario, "stage": stage,
            "isCompact": store.isCompact, "toggleMethod": toggleMethod, "frameEvents": frameEvents,
            "windowHasShadow": window.hasShadow, "windowIsOpaque": window.isOpaque,
            "windowLevel": window.level.rawValue, "movableByBackground": window.isMovableByWindowBackground,
            "canBecomeKey": window.canBecomeKey, "isKeyWindow": window.isKeyWindow,
            "backingScale": Double(window.backingScaleFactor),
            "windowFrame": [Double(window.frame.minX), Double(window.frame.minY),
                            Double(window.frame.width), Double(window.frame.height)],
            "minSize": [Double(window.minSize.width), Double(window.minSize.height)],
            "maxSize": [Double(window.maxSize.width), Double(window.maxSize.height)],
            "contentPoints": [Double(content?.bounds.width ?? 0), Double(content?.bounds.height ?? 0)],
            "contentSafeInsets": [Double(insets.top), Double(insets.left), Double(insets.bottom), Double(insets.right)],
            "contentLayoutRect": [Double(layout.minX), Double(layout.minY), Double(layout.width), Double(layout.height)],
            "imagePixels": [full.pixelsWide, full.pixelsHigh]]
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, ownID,
                                               [.bestResolution, .boundsIgnoreFraming]) {
            let bounded = NSBitmapImageRep(cgImage: image)
            try save(bounded, name: "\(prefix)-bounds.png", in: output)
            try save(onCyan(bounded), name: "\(prefix)-bounds-cyan.png", in: output)
            row["boundsPixels"] = [bounded.pixelsWide, bounded.pixelsHigh]
        }
        let report = try JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys])
        try write(report, name: "\(prefix)-report.json", in: output)
    }

    @MainActor private static func sendToggleToOwnWindow() throws {
        let window = try activeWindow()
        guard let view = window.contentView else { throw FixtureError.bitmap }
        let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"]
        let topInset = variant == "baseline" ? view.safeAreaInsets.top : 0
        let point = NSPoint(x: view.bounds.width - 68, y: view.bounds.height - topInset - 29)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: time, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 2, clickCount: 1, pressure: 0) else { throw FixtureError.bitmap }
        window.makeKeyAndOrderFront(nil)
        window.sendEvent(down)
        window.sendEvent(up)
    }

    @MainActor private static func titlePoint(_ window: NSWindow, fromRight: CGFloat) throws -> NSPoint {
        guard let view = window.contentView else { throw FixtureError.bitmap }
        let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"]
        let inset = variant == "baseline" ? view.safeAreaInsets.top : 0
        return NSPoint(x: view.bounds.width - fromRight, y: view.bounds.height - inset - 29)
    }

    @MainActor private static func sendClick(_ window: NSWindow, at point: NSPoint) throws {
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                            timestamp: time, windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 7, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                          timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 8, clickCount: 1, pressure: 0) else { throw FixtureError.bitmap }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    @MainActor private static func exerciseControls() {
        do {
            guard let output else { throw FixtureError.unsafeEnvironment }
            let window = try activeWindow()
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                do {
                    let key = window.isKeyWindow
                    let canBecomeKey = window.canBecomeKey
                    let origin = window.frame.origin
                    let point = try titlePoint(window, fromRight: window.frame.width - 180)
                    let end = NSPoint(x: point.x + 25, y: point.y + 15)
                    let time = ProcessInfo.processInfo.systemUptime
                    guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                        timestamp: time, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 11, clickCount: 1, pressure: 1),
                          let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: end, modifierFlags: [],
                                                        timestamp: time + 0.03, windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 12, clickCount: 1, pressure: 1),
                          let up = NSEvent.mouseEvent(with: .leftMouseUp, location: end, modifierFlags: [],
                                                      timestamp: time + 0.06, windowNumber: window.windowNumber, context: nil,
                                                      eventNumber: 13, clickCount: 1, pressure: 0) else { throw FixtureError.bitmap }
                    window.sendEvent(down)
                    window.sendEvent(drag)
                    window.sendEvent(up)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        do {
                            let moved = window.frame.origin != origin
                            try sendClick(window, at: titlePoint(window, fromRight: 104))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                do {
                                    let minimized = window.isMiniaturized
                                    if minimized { window.deminiaturize(nil) }
                                    let report: [String: Any] = [
                                        "mode": ProcessInfo.processInfo.environment["AITM_SYNTHETIC_APPEARANCE"] ?? "",
                                        "variant": ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"] ?? "",
                                        "scenario": ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_SCENARIO"] ?? "",
                                        "canBecomeKey": canBecomeKey, "isKeyWindow": key,
                                        "movableByBackground": window.isMovableByWindowBackground,
                                        "dragEventMovedWindow": moved, "minimizeEventMiniaturized": minimized
                                    ]
                                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                                    try write(data, name: "windowgroup-interactions.json", in: output)
                                    closeObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                                           object: nil, queue: nil) { _ in
                                        MainActor.assumeIsolated {
                                            try? write(Data("{\"closed\":true}".utf8), name: "windowgroup-close-completed.json", in: output)
                                        }
                                    }
                                    try sendClick(window, at: titlePoint(window, fromRight: 32))
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                        try? write(Data("{\"closed\":false}".utf8), name: "windowgroup-close-not-observed.json", in: output)
                                        exit(0)
                                    }
                                } catch {
                                    FileHandle.standardError.write(Data("Synthetic control probe failed.\n".utf8))
                                    exit(1)
                                }
                            }
                        } catch {
                            FileHandle.standardError.write(Data("Synthetic drag or minimize probe failed.\n".utf8))
                            exit(1)
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data("Synthetic focus or drag probe failed.\n".utf8))
                    exit(1)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Synthetic control setup failed.\n".utf8))
            exit(1)
        }
    }

    @MainActor static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            do {
                guard let store = activeStore else { throw FixtureError.unsafeEnvironment }
                let wasCompact = store.isCompact
                try capture("before", toggleMethod: "not-attempted")
                try sendToggleToOwnWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let method: String
                    if store.isCompact != wasCompact {
                        method = "button-event"
                    } else {
                        method = "direct-state-fallback"
                        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            store.isCompact.toggle()
                            store.showsSettings = false
                            store.showsJournal = false
                            store.showsAbout = false
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        do {
                            guard store.isCompact != wasCompact else { throw FixtureError.bitmap }
                            try capture("after", toggleMethod: method)
                            exerciseControls()
                        } catch {
                            FileHandle.standardError.write(Data("Synthetic transition capture failed.\n".utf8))
                            exit(1)
                        }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("Synthetic WindowGroup capture failed.\n".utf8))
                exit(1)
            }
        }
    }
}
