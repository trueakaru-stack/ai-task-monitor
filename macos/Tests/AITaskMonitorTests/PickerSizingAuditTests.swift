import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

private final class PickerAuditModel: ObservableObject {
    @Published var selections = [7, 10, 7, 10, 5, 10]
    var journalFrames: [String: CGRect] = [:]
}

private struct SettingsPickerAuditRoot: View {
    @ObservedObject var model: PickerAuditModel
    let store: TaskStore
    let openCodePreview: SettingsPreviewOpenCode
    let scheme: ColorScheme
    let defaults: UserDefaults

    private func binding(_ index: Int) -> Binding<Int> {
        Binding(get: { model.selections[index] }, set: { model.selections[index] = $0 })
    }

    var body: some View {
        RootView().environmentObject(store)
            .environment(\.settingsPreviewClaude, .connected)
            .environment(\.settingsPreviewCloud, .disconnected)
            .environment(\.settingsPreviewKimi, .disconnected)
            .environment(\.settingsPreviewHermes, .absent)
            .environment(\.settingsPreviewOpenCode, openCodePreview)
            .environment(\.settingsPreviewMenuBindings, SettingsPreviewMenuBindings(
                retentionDays: binding(0), maximumMB: binding(1),
                claudeRetentionDays: binding(2), claudeMaximumMB: binding(3),
                loopThreshold: binding(4), loopWindowMinutes: binding(5)))
            .environment(\.settingsPreviewJournalFrames, true)
            .environment(\.colorScheme, scheme)
            .defaultAppStorage(defaults)
            .coordinateSpace(name: SettingsPreviewJournalFrameKey.coordinateSpace)
            .onPreferenceChange(SettingsPreviewJournalFrameKey.self) { model.journalFrames = $0 }
    }
}

private struct PickerWidthChoice {
    let title: String
    let textWidth: CGFloat
    let cellWidth: CGFloat
    let actualFittingWidth: CGFloat
    let detachedFittingWidth: CGFloat
    let fontName: String
    let fontPointSize: CGFloat
    let fontVerified: Bool

    var metrics: [String: Any] {
        ["title": title, "textWidth": Double(textWidth), "cellWidth": Double(cellWidth),
         "actualFittingWidth": Double(actualFittingWidth), "detachedFittingWidth": Double(detachedFittingWidth),
         "fontName": fontName, "fontPointSize": Double(fontPointSize), "fontVerified": fontVerified]
    }
}

private struct PickerAuditView: View {
    @ObservedObject var model: PickerAuditModel
    let language: String
    let sharedTextWidth: CGFloat
    let variants: [Int]
    let fittedControlWidth: CGFloat?
    private let variantNames = ["baseline", "flexible frame", "framed option labels",
                                "buttonSizing flexible: 120 pt", "buttonSizing flexible: max fittingSize"]
    let ranges = [1...7, 1...10, 1...30, 1...100, 3...10, 1...30]

    init(model: PickerAuditModel, language: String, sharedTextWidth: CGFloat,
         variants: [Int] = [0, 1, 2], fittedControlWidth: CGFloat? = nil) {
        self.model = model
        self.language = language
        self.sharedTextWidth = sharedTextWidth
        self.variants = variants
        self.fittedControlWidth = fittedControlWidth
    }

    func label(_ row: Int, _ value: Int) -> String {
        if row == 0 || row == 2 {
            if language == "en" { return "\(value) " + (value == 1 ? "day" : "days") }
            let last = value % 10, lastTwo = value % 100
            return "\(value) " + ((11...14).contains(lastTwo) ? "дней" : last == 1 ? "день" : (2...4).contains(last) ? "дня" : "дней")
        }
        if row == 1 || row == 3 { return "\(value) " + (language == "en" ? "MB" : "МБ") }
        if row == 5 { return "\(value) " + (language == "en" ? "min" : "мин") }
        return "\(value)"
    }

    @ViewBuilder private func options(_ row: Int, framed: Bool) -> some View {
        ForEach(Array(ranges[row]), id: \.self) { value in
            if framed {
                Text(label(row, value)).frame(minWidth: sharedTextWidth, alignment: .leading).tag(value)
            } else {
                Text(label(row, value)).tag(value)
            }
        }
    }

    @ViewBuilder private func originalPicker(_ row: Int, variant: Int) -> some View {
        let selection = Binding(get: { model.selections[row] }, set: { model.selections[row] = $0 })
        if variant == 1 {
            Picker("Synthetic option", selection: selection) { options(row, framed: false) }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity).frame(width: 120)
        } else {
            Picker("Synthetic option", selection: selection) { options(row, framed: variant == 2) }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
        }
    }

    @ViewBuilder private func picker(_ row: Int, variant: Int) -> some View {
        #if compiler(>=6.2)
        let targetWidth = variant == 3 ? CGFloat(120) : fittedControlWidth
        if #available(macOS 26.0, *), (variant == 3 || variant == 4), let targetWidth {
            let selection = Binding(get: { model.selections[row] }, set: { model.selections[row] = $0 })
            Picker("Synthetic option", selection: selection) { options(row, framed: false) }
                .labelsHidden().pickerStyle(.menu)
                .buttonSizing(.flexible)
                .frame(width: targetWidth)
        } else {
            originalPicker(row, variant: variant)
        }
        #else
        originalPicker(row, variant: variant)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(variants, id: \.self) { variant in
                Text(variantNames[variant]).font(.system(size: 12, weight: .semibold))
                ForEach(0..<6, id: \.self) { row in
                    HStack {
                        Text("Synthetic row \(row + 1)").font(.system(size: 13))
                        Spacer()
                        picker(row, variant: variant)
                    }
                    .frame(height: 25)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 560, height: 700, alignment: .top)
        .background(MonitorTheme.surface)
        .controlSize(.large)
    }

    @MainActor static func textWidth(language: String) -> CGFloat {
        let model = PickerAuditModel()
        let view = PickerAuditView(model: model, language: language, sharedTextWidth: 0)
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large))
        return view.ranges.enumerated().flatMap { row, values in
            values.map { value in (view.label(row, value) as NSString).size(withAttributes: [.font: font]).width }
        }.max() ?? 0
    }
}

final class PickerSizingAuditTests: XCTestCase {
    @MainActor func testNativePickerSizingVariants() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("Picker audit runs only on an ephemeral GitHub-hosted runner.")
        }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticPickerAudit", code: 1)
        }
        let destination = URL(fileURLWithPath: root, isDirectory: true)
        _ = NSApplication.shared
        var metadata: [[String: Any]] = []
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func controlMetrics(_ host: NSView) -> [[String: Any]] {
            descendants(host).compactMap { $0 as? NSPopUpButton }.map { control in
                let bounds = control.convert(control.bounds, to: host)
                return ["frame": [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)],
                        "fittingWidth": Double(control.fittingSize.width),
                        "intrinsicWidth": Double(control.intrinsicContentSize.width),
                        "cellWidth": Double(control.cell?.cellSize.width ?? 0),
                        "selectedTitle": control.selectedItem?.title ?? ""]
            }
        }
        func openWindow(_ host: NSView, theme: String) -> NSWindow {
            host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            return window
        }
        func capture(_ host: NSView, name: String) throws {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "SyntheticPickerAudit", code: 2)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SyntheticPickerAudit", code: 3)
            }
            try png.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
        for language in ["ru", "en"] {
            for theme in ["light", "dark"] {
                let width = PickerAuditView.textWidth(language: language)
                let model = PickerAuditModel()
                let root = PickerAuditView(model: model, language: language, sharedTextWidth: width)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                let host = NSHostingView(rootView: root)
                let window = openWindow(host, theme: theme)
                try capture(host, name: "picker-\(language)-\(theme)-current.png")
                let currentControls = controlMetrics(host)
                model.selections = [7, 10, 30, 100, 10, 30]
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                try capture(host, name: "picker-\(language)-\(theme)-maximum.png")
                let maximumControls = controlMetrics(host)
                window.close()

                var record: [String: Any] = ["language": language, "theme": theme,
                                             "sharedTextWidth": Double(width),
                                             "nsPopUpButtonCount": maximumControls.count,
                                             "currentControls": currentControls,
                                             "maximumControls": maximumControls,
                                             "buttonSizingAvailable": false]
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) {
                    record["buttonSizingAvailable"] = true
                    var scenarios: [[String: Any]] = []
                    for (state, selections) in [("current", [7, 10, 7, 10, 5, 10]),
                                                ("maximum", [7, 10, 30, 100, 10, 30])] {
                        let referenceModel = PickerAuditModel()
                        referenceModel.selections = selections
                        let referenceRoot = PickerAuditView(model: referenceModel, language: language,
                                                            sharedTextWidth: width, variants: [0])
                            .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                        let referenceHost = NSHostingView(rootView: referenceRoot)
                        let referenceWindow = openWindow(referenceHost, theme: theme)
                        let referenceControls = controlMetrics(referenceHost)
                        XCTAssertEqual(referenceControls.count, 6, "Expected six native reference controls.")
                        let fittingWidths = referenceControls.compactMap { $0["fittingWidth"] as? Double }
                            .filter { $0.isFinite && $0 > 0 && $0 < 500 }
                        XCTAssertEqual(fittingWidths.count, 6, "Expected six usable native fitting widths.")
                        let fittingWidth = fittingWidths.max().map { CGFloat($0) }
                        referenceWindow.close()

                        let comparisonModel = PickerAuditModel()
                        comparisonModel.selections = selections
                        let variants = fittingWidth == nil ? [0, 3] : [0, 3, 4]
                        let comparisonRoot = PickerAuditView(model: comparisonModel, language: language,
                                                             sharedTextWidth: width, variants: variants,
                                                             fittedControlWidth: fittingWidth)
                            .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                        let comparisonHost = NSHostingView(rootView: comparisonRoot)
                        let comparisonWindow = openWindow(comparisonHost, theme: theme)
                        let filename = "picker-button-sizing-\(language)-\(theme)-\(state).png"
                        try capture(comparisonHost, name: filename)
                        let comparisonControls = controlMetrics(comparisonHost)
                        comparisonWindow.close()
                        scenarios.append(["state": state, "file": filename,
                                          "maxReferenceFittingWidth": fittingWidth.map { Double($0) } as Any? ?? NSNull(),
                                          "referenceControls": referenceControls,
                                          "comparisonControls": comparisonControls])
                    }
                    record["buttonSizingScenarios"] = scenarios
                }
                #endif
                metadata.append(record)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("picker-geometry.json"), options: .atomic)
    }

    @MainActor func testSyntheticAppKitAndSwiftUIFittingMeasurements() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("Picker audit runs only on an ephemeral GitHub-hosted runner.")
        }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticPickerAudit", code: 4)
        }
        _ = NSApplication.shared
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var records: [[String: Any]] = []
        for language in ["ru", "en"] {
            for theme in ["light", "dark"] {
                for (state, selections) in [("minimum", [1, 1, 1, 1, 3, 1]),
                                            ("current", [7, 10, 7, 10, 5, 10]),
                                            ("maximum", [7, 10, 30, 100, 10, 30])] {
                    let model = PickerAuditModel()
                    model.selections = selections
                    let fixture = PickerAuditView(model: model, language: language, sharedTextWidth: 0, variants: [0])
                    let rootView = fixture.environment(\.colorScheme, theme == "dark" ? .dark : .light)
                    let host = NSHostingView(rootView: rootView)
                    host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
                    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    window.makeKeyAndOrderFront(nil)
                    defer { window.close() }
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.7))
                    let reference = descendants(host).compactMap { $0 as? NSPopUpButton }.sorted {
                        $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY
                    }
                    XCTAssertEqual(reference.count, 6, "Expected six synthetic SwiftUI-backed pickers.")
                    guard reference.count == 6 else { continue }
                    let appKitContainer = NSView(frame: NSRect(x: 600, y: 0, width: 1, height: 1))
                    host.addSubview(appKitContainer)
                    var rows: [[String: Any]] = []
                    for row in 0..<6 {
                        let button = NSPopUpButton(frame: .zero, pullsDown: false)
                        button.controlSize = .large
                        button.addItems(withTitles: fixture.ranges[row].map { fixture.label(row, $0) })
                        button.selectItem(at: selections[row] - fixture.ranges[row].lowerBound)
                        let detachedDefaultWidth = button.fittingSize.width
                        button.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                        let detachedMatchedWidth = button.fittingSize.width
                        appKitContainer.addSubview(button)
                        let swiftButton = reference[row]
                        let swiftWidth = swiftButton.fittingSize.width
                        let appKitWidth = button.fittingSize.width
                        let expectedTitle = fixture.label(row, selections[row])
                        XCTAssertEqual(swiftButton.selectedItem?.title, expectedTitle)
                        XCTAssertEqual(button.selectedItem?.title, expectedTitle)
                        XCTAssertGreaterThan(swiftWidth, 0)
                        XCTAssertGreaterThan(appKitWidth, 0)
                        XCTAssertGreaterThan(detachedDefaultWidth, 0)
                        XCTAssertGreaterThan(detachedMatchedWidth, 0)
                        rows.append(["row": row + 1, "selection": expectedTitle,
                                     "swiftUIWidth": Double(swiftWidth), "appKitWidth": Double(appKitWidth),
                                     "matchesWithinHalfPoint": abs(swiftWidth - appKitWidth) <= 0.5,
                                     "detachedDefaultWidth": Double(detachedDefaultWidth),
                                     "detachedMatchedWidth": Double(detachedMatchedWidth),
                                     "detachedDefaultMatches": abs(swiftWidth - detachedDefaultWidth) <= 0.5,
                                     "detachedMatchedMatches": abs(swiftWidth - detachedMatchedWidth) <= 0.5,
                                     "swiftUIFont": swiftButton.font?.fontName ?? "",
                                     "swiftUIFontSize": Double(swiftButton.font?.pointSize ?? 0),
                                     "appKitFont": button.font?.fontName ?? "",
                                     "appKitFontSize": Double(button.font?.pointSize ?? 0)])
                    }
                    records.append(["language": language, "theme": theme, "state": state, "rows": rows,
                                    "swiftUIMax": rows.compactMap { $0["swiftUIWidth"] as? Double }.max() ?? 0,
                                    "appKitMax": rows.compactMap { $0["appKitWidth"] as? Double }.max() ?? 0,
                                    "detachedDefaultMax": rows.compactMap { $0["detachedDefaultWidth"] as? Double }.max() ?? 0,
                                    "detachedMatchedMax": rows.compactMap { $0["detachedMatchedWidth"] as? Double }.max() ?? 0])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("picker-appkit-measurement.json"), options: .atomic)
    }

    @MainActor func testActualSettingsMenusUseTheWidestNativeControl() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AITM_LAYOUT_SYNTHETIC_CI"] == "1" else {
            throw XCTSkip("Settings menu audit runs only on an ephemeral GitHub-hosted runner.")
        }
        guard env["GITHUB_ACTIONS"] == "true", env["CI"] == "true",
              env["RUNNER_ENVIRONMENT"] == "github-hosted", env["RUNNER_OS"] == "macOS",
              let temporary = env["RUNNER_TEMP"], let root = env["AITM_LAYOUT_SYNTHETIC_ROOT"],
              root.hasPrefix(temporary + "/aitm-layout-") else {
            throw NSError(domain: "SyntheticPickerAudit", code: 5)
        }
        let destination = URL(fileURLWithPath: root, isDirectory: true)
        let baseline = env["AITM_SETTINGS_WIDTH_BASELINE"] == "1"
        _ = NSApplication.shared
        defer { AppLanguage.previewOverride = nil }

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func rectArray(_ rect: NSRect) -> [Double] {
            [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }
        }
        func auditError(_ code: Int, _ message: String) -> NSError {
            NSError(domain: "SyntheticPickerAudit", code: code,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }

        // Check the complete capture/coordinate pipeline separately from the
        // product view. The first SwiftUI colour is visually at the top.
        func calibrateBitmap() throws -> [String: Any] {
            let view = VStack(spacing: 0) {
                Color(red: 1, green: 0, blue: 0).frame(height: 32)
                Color(red: 0, green: 0, blue: 1).frame(height: 32)
            }.frame(width: 64, height: 64)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
            guard host.isFlipped else {
                throw auditError(31, "The calibration host uses an unexpected coordinate system.")
            }
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 64, height: 64),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw auditError(32, "The calibration bitmap is unavailable.")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let x = bitmap.pixelsWide / 2
            let topY = bitmap.pixelsHigh / 4
            let bottomY = bitmap.pixelsHigh * 3 / 4
            guard bitmap.pixelsWide >= 4, bitmap.pixelsHigh >= 4,
                  let top = bitmap.colorAt(x: x, y: topY)?.usingColorSpace(.deviceRGB),
                  let bottom = bitmap.colorAt(x: x, y: bottomY)?.usingColorSpace(.deviceRGB),
                  top.redComponent > top.blueComponent + 0.5,
                  bottom.blueComponent > bottom.redComponent + 0.5 else {
                throw auditError(33, "Bitmap colorAt orientation could not be established.")
            }
            // Apple documents getPixel's origin as top-left; record both raw
            // samples as a separate check of the same synthetic bitmap.
            var topPixel = [Int](repeating: 0, count: max(5, bitmap.samplesPerPixel))
            var bottomPixel = [Int](repeating: 0, count: max(5, bitmap.samplesPerPixel))
            topPixel.withUnsafeMutableBufferPointer { buffer in
                bitmap.getPixel(buffer.baseAddress!, atX: x, y: topY)
            }
            bottomPixel.withUnsafeMutableBufferPointer { buffer in
                bitmap.getPixel(buffer.baseAddress!, atX: x, y: bottomY)
            }
            guard topPixel != bottomPixel else {
                throw auditError(34, "Bitmap getPixel returned indistinguishable calibration samples.")
            }
            return ["method": "Synthetic NSHostingView captured with cacheDisplay",
                    "origin": "top-left", "hostFlipped": host.isFlipped,
                    "pixelSize": [bitmap.pixelsWide, bitmap.pixelsHigh],
                    "topColor": [Double(top.redComponent), Double(top.greenComponent), Double(top.blueComponent)],
                    "bottomColor": [Double(bottom.redComponent), Double(bottom.greenComponent), Double(bottom.blueComponent)],
                    "topRawSamples": topPixel, "bottomRawSamples": bottomPixel]
        }
        let bitmapCalibration = try calibrateBitmap()

        func inspect(language: String, theme: String) throws {
            AppLanguage.previewOverride = language == "ru" ? .ru : .en
            var previewStateCalls = 0
            var previewPresenceCalls = 0
            var storeConnectionCalls = 0
            let openCodePreview = SettingsPreviewOpenCode(
                state: { previewStateCalls += 1; return .disconnected },
                present: { previewPresenceCalls += 1; return false }
            )
            let store = TaskStore(
                codexReader: CodexTaskReader(codexHome: destination.appendingPathComponent("synthetic-codex", isDirectory: true)),
                claudeReader: ClaudeTaskReader(eventFile: destination.appendingPathComponent("synthetic-claude.jsonl")),
                previewTasks: [], openCodeConnection: {
                    storeConnectionCalls += 1
                    return .disconnected
                }
            )
            store.showsSettings = true
            let originalDiagnosticSettings = store.diagnosticSettings
            let originalClaudeRetention = store.claudeRetentionPolicy
            XCTAssertNotNil(originalClaudeRetention, "Synthetic storage controls must be enabled.")
            let suiteName = "AITM.PickerAudit." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                throw auditError(6, "The isolated preferences suite was not created.")
            }
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(theme, forKey: "appearanceMode")
            defaults.set(language, forKey: "languageMode")
            let model = PickerAuditModel()
            let view = SettingsPickerAuditRoot(model: model, store: store, openCodePreview: openCodePreview,
                                               scheme: theme == "dark" ? .dark : .light, defaults: defaults)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 700)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 560, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // Allow the existing preview navigation and its delayed scroll to finish.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(previewStateCalls, 0, "SettingsView must use the synthetic OpenCode state.")
            XCTAssertGreaterThan(previewPresenceCalls, 0, "SettingsView must use the synthetic OpenCode presence.")
            XCTAssertEqual(storeConnectionCalls, 0, "The synthetic store must not inspect OpenCode.")
            guard host.isFlipped else {
                throw auditError(7, "The preview geometry cannot be compared with the unflipped host.")
            }

            let fixture = PickerAuditView(model: PickerAuditModel(), language: language, sharedTextWidth: 0)
            func menus() throws -> [NSPopUpButton] {
                let popups = descendants(host).compactMap { $0 as? NSPopUpButton }
                return try fixture.ranges.enumerated().map { row, values in
                    let expected = Set(values.map { fixture.label(row, $0) })
                    let matches = popups.filter { Set($0.itemTitles.filter { !$0.isEmpty }) == expected }
                    guard matches.count == 1, let button = matches.first else {
                        throw auditError(8, "Expected exactly one settings menu for row \(row + 1); found \(matches.count).")
                    }
                    return button
                }
            }
            let probes = descendants(host).compactMap { $0 as? OverlayScrollerProbe.Probe }
                .filter { !$0.alwaysVisible && $0.enclosingScrollView != nil }
            guard probes.count == 1, let scroll = probes.first?.enclosingScrollView,
                  let document = scroll.documentView else {
                throw auditError(9, "The settings scroll view is unavailable or ambiguous.")
            }

            // Compare actual frames against the scroll viewport and host in a common
            // coordinate system. A menu's visibleRect does not establish visibility.
            func scrollToMenus() throws {
                let all = try menus().map { $0.convert($0.bounds, to: document) }
                guard let first = all.first else { throw auditError(10, "No menu frames.") }
                let combined = all.dropFirst().reduce(first) { $0.union($1) }
                let height = scroll.contentView.bounds.height
                guard height > 0, combined.height <= height - 8 else {
                    throw auditError(11, "All six menus do not fit in the settings viewport.")
                }
                let minY = document.bounds.minY
                let maxY = max(minY, document.bounds.maxY - height)
                let y = min(maxY, max(minY, combined.midY - height / 2))
                scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }

            typealias Capture = (bitmap: NSBitmapImageRep, frames: [NSRect], journal: [[String: Any]], record: [String: Any])
            func capture(_ suffix: String, selections: [Int], updateModel: Bool = true) throws -> Capture {
                guard selections.count == fixture.ranges.count else {
                    throw auditError(12, "Selection count differs from the menu count.")
                }
                if updateModel {
                    // Set the synthetic SwiftUI bindings, not only AppKit's selection.
                    model.selections = selections
                } else if model.selections != selections {
                    throw auditError(35, "The unchanged-model capture has different selections.")
                }
                var current: [NSPopUpButton] = []
                for _ in 0..<20 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    current = try menus()
                    if current.enumerated().allSatisfy({ row, button in
                        button.selectedItem?.title == fixture.label(row, selections[row])
                    }) { break }
                }
                guard current.enumerated().allSatisfy({ row, button in
                    button.selectedItem?.title == fixture.label(row, selections[row])
                }) else {
                    throw auditError(13, "SwiftUI did not render the requested selections for \(suffix).")
                }
                try scrollToMenus()
                // Scrolling and rendering may recreate controls. Re-discover and recheck them.
                current = try menus()
                let clip = scroll.contentView.convert(scroll.contentView.bounds, to: host)
                guard clip.width > 0, clip.height > 0, host.bounds.insetBy(dx: -1, dy: -1).contains(clip) else {
                    throw auditError(14, "The settings viewport is not within the host.")
                }
                let expandedClip = clip.insetBy(dx: -1, dy: -1)
                let expandedHost = host.bounds.insetBy(dx: -1, dy: -1)
                var frames: [NSRect] = []
                var menuRecords: [[String: Any]] = []
                for (row, button) in current.enumerated() {
                    let frame = button.convert(button.bounds, to: host)
                    let expected = fixture.label(row, selections[row])
                    guard button.selectedItem?.title == expected, frame.width > 0, frame.height > 0,
                          expandedClip.contains(frame), expandedHost.contains(frame) else {
                        throw auditError(15, "Menu \(row + 1) is not fully visible with its requested value in \(suffix).")
                    }
                    frames.append(frame)
                    menuRecords.append(["row": row + 1, "value": selections[row], "selectedTitle": expected,
                                        "enabled": button.isEnabled, "frameInHost": rectArray(frame)])
                }
                let journalTitles = language == "ru" ? ["Открыть журнал", "Очистить"] : ["Open journal", "Clear"]
                var axElements: [any NSAccessibilityProtocol] = []
                var axVisited: Set<ObjectIdentifier> = []
                func collectAccessibility(_ value: Any, depth: Int = 0) {
                    guard depth < 40, let item = value as? any NSAccessibilityProtocol,
                          axVisited.insert(ObjectIdentifier(item as AnyObject)).inserted else { return }
                    axElements.append(item)
                    for child in item.accessibilityChildren() ?? [] {
                        collectAccessibility(child, depth: depth + 1)
                    }
                }
                collectAccessibility(host)
                var journal: [[String: Any]] = []
                for (index, key) in ["open", "clear"].enumerated() {
                    guard let frame = model.journalFrames[key], frame.width > 0, frame.height > 0,
                          frame.origin.x.isFinite, frame.origin.y.isFinite,
                          expandedClip.contains(frame), expandedHost.contains(frame),
                          frame.midY > frames[1].maxY, frame.midY < frames[2].minY else {
                        throw auditError(16, "The actual \(key) journal button frame is unavailable or outside the viewport.")
                    }
                    let title = journalTitles[index]
                    let axMatches = axElements.filter {
                        $0.accessibilityRole() == .button &&
                        ($0.accessibilityLabel() == title || $0.accessibilityTitle() == title)
                    }
                    var ax: [String: Any] = ["matchCount": axMatches.count]
                    if axMatches.count == 1, let match = axMatches.first {
                        let candidate = host.convert(window.convertFromScreen(match.accessibilityFrame()), from: nil)
                        if candidate.origin.x.isFinite, candidate.origin.y.isFinite,
                           candidate.width.isFinite, candidate.height.isFinite {
                            ax["frameInHost"] = rectArray(candidate)
                            ax["insideViewport"] = expandedClip.contains(candidate) && expandedHost.contains(candidate)
                        }
                    }
                    journal.append(["title": title, "width": Double(frame.width),
                                    "height": Double(frame.height), "frameInHost": rectArray(frame),
                                    "source": "GeometryReader on the actual SwiftUI Button", "accessibility": ax])
                }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw auditError(17, "The host cannot provide a bitmap.")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // cacheDisplay may trigger view work. Verify the binding, native
                // selections and crop geometry again after the image is captured.
                let afterCapture = try menus()
                guard model.selections == selections, afterCapture.count == frames.count else {
                    throw auditError(36, "The model changed while the frame was being captured.")
                }
                for (row, button) in afterCapture.enumerated() {
                    let frame = button.convert(button.bounds, to: host)
                    let previous = frames[row]
                    guard button.selectedItem?.title == fixture.label(row, selections[row]),
                          abs(frame.minX - previous.minX) < 0.5, abs(frame.minY - previous.minY) < 0.5,
                          abs(frame.width - previous.width) < 0.5, abs(frame.height - previous.height) < 0.5,
                          expandedClip.contains(frame), expandedHost.contains(frame) else {
                        throw auditError(37, "A menu changed during the \(suffix) capture.")
                    }
                }
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw auditError(18, "The captured bitmap cannot be encoded.")
                }
                let file = "settings-width-\(language)-\(theme)-\(suffix).png"
                try png.write(to: destination.appendingPathComponent(file), options: .atomic)
                let record: [String: Any] = ["file": file, "clipInHost": rectArray(clip), "menus": menuRecords,
                                             "journalButtons": journal]
                return (bitmap, frames, journal, record)
            }

            let settingsButtons = try menus()
            var rows: [[String: Any]] = []
            var naturalWidths: [CGFloat] = []
            var actualFittingWidths: [CGFloat] = []
            var detachedFittingWidths: [CGFloat] = []
            var widestTextSelections: [PickerWidthChoice] = []
            var widestCellSelections: [PickerWidthChoice] = []
            var widestFittingSelections: [PickerWidthChoice] = []
            for (row, button) in settingsButtons.enumerated() {
                let original = button.indexOfSelectedItem
                guard original >= 0, let cell = button.cell as? NSPopUpButtonCell else {
                    throw auditError(19, "The native menu cell is unavailable.")
                }
                let measure = NSPopUpButton(frame: .zero, pullsDown: false)
                measure.controlSize = .large
                measure.addItems(withTitles: fixture.ranges[row].map { fixture.label(row, $0) })
                var choices: [PickerWidthChoice] = []
                var fontUnavailable = false
                var attributedTitleMismatch = false
                for index in 0..<button.numberOfItems {
                    guard let item = button.item(at: index), !item.title.isEmpty else { continue }
                    // Native selection is used only for measurement, never for a capture.
                    button.selectItem(at: index)
                    measure.selectItem(withTitle: item.title)
                    guard button.selectedItem?.title == item.title, measure.selectedItem?.title == item.title else {
                        throw auditError(20, "A native measurement selection failed.")
                    }
                    let cellWidth = cell.cellSize.width
                    let fittingWidth = button.fittingSize.width
                    let detachedWidth = measure.fittingSize.width
                    let attributedTitle = item.attributedTitle
                    let attributedFont = attributedTitle.flatMap {
                        $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
                    }
                    let observedFont = button.font ?? cell.font ?? attributedFont
                    let font = observedFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
                    if observedFont == nil { fontUnavailable = true }
                    let styled = NSMutableAttributedString(string: item.title, attributes: [.font: font])
                    if let attributedTitle, attributedTitle.string == item.title {
                        attributedTitle.enumerateAttributes(in: NSRange(location: 0, length: attributedTitle.length),
                                                            options: []) { attributes, range, _ in
                            styled.addAttributes(attributes, range: range)
                        }
                    } else if attributedTitle != nil { attributedTitleMismatch = true }
                    let textWidth = styled.size().width
                    guard cellWidth.isFinite && fittingWidth.isFinite && detachedWidth.isFinite &&
                          textWidth.isFinite && textWidth > 0 else {
                        throw auditError(21, "A native width measurement was invalid.")
                    }
                    naturalWidths.append(cellWidth)
                    actualFittingWidths.append(fittingWidth)
                    detachedFittingWidths.append(detachedWidth)
                    choices.append(PickerWidthChoice(title: item.title, textWidth: textWidth, cellWidth: cellWidth,
                                                     actualFittingWidth: fittingWidth, detachedFittingWidth: detachedWidth,
                                                     fontName: font.fontName, fontPointSize: font.pointSize,
                                                     fontVerified: observedFont != nil &&
                                                        (attributedTitle == nil || attributedTitle?.string == item.title)))
                }
                button.selectItem(at: original)
                XCTAssertFalse(fontUnavailable, "Popup \(row + 1) font is unavailable; title width is estimated.")
                XCTAssertFalse(attributedTitleMismatch, "Popup \(row + 1) has an inconsistent attributed title.")
                guard let widestText = choices.max(by: { $0.textWidth < $1.textWidth }),
                      let widestCellChoice = choices.max(by: {
                          $0.cellWidth == $1.cellWidth ? $0.textWidth < $1.textWidth : $0.cellWidth < $1.cellWidth
                      }),
                      let widestFittingChoice = choices.max(by: {
                          $0.detachedFittingWidth == $1.detachedFittingWidth
                              ? $0.textWidth < $1.textWidth : $0.detachedFittingWidth < $1.detachedFittingWidth
                      }) else {
                    throw auditError(22, "The widest option was not measured.")
                }
                widestTextSelections.append(widestText)
                widestCellSelections.append(widestCellChoice)
                widestFittingSelections.append(widestFittingChoice)
                rows.append(["row": row + 1, "choiceMeasurements": choices.map(\.metrics),
                             "widestText": widestText.metrics, "widestCell": widestCellChoice.metrics,
                             "widestDetachedFitting": widestFittingChoice.metrics])
            }
            guard let widestCell = naturalWidths.max(), widestCell.isFinite, widestCell > 0,
                  let widestFitting = detachedFittingWidths.max(), widestFitting.isFinite, widestFitting > 0 else {
                throw auditError(23, "The overall native width was not measured.")
            }
            func values(for choices: [PickerWidthChoice]) throws -> [Int] {
                try choices.enumerated().map { row, choice in
                    guard let value = fixture.ranges[row].first(where: { fixture.label(row, $0) == choice.title }) else {
                        throw auditError(24, "The measured widest title has no matching binding value.")
                    }
                    return value
                }
            }
            let initialValues = [7, 10, 7, 10, 5, 10]
            let widestValues = try values(for: widestTextSelections)
            var captureRecords: [[String: Any]] = []
            let initial = try capture("initial", selections: initialValues)
            captureRecords.append(initial.record)
            guard let firstFrame = initial.frames.first else { throw auditError(25, "No captured menu frames.") }
            for (row, frame) in initial.frames.enumerated() {
                rows[row]["frameInHost"] = rectArray(frame)
                rows[row]["frameWidth"] = Double(frame.width)
                rows[row]["selectedTitle"] = fixture.label(row, initialValues[row])
            }
            if !baseline {
                for frame in initial.frames {
                    XCTAssertEqual(frame.width, firstFrame.width, accuracy: 1, "Actual menu frames must have equal width.")
                    XCTAssertEqual(frame.maxX, firstFrame.maxX, accuracy: 1, "Actual menu right edges must align.")
                }
            }

            // The synthetic calibration above established top-left bitmap coordinates
            // for a flipped NSHostingView. Do not accept changes in a reflected crop.
            func changedPixels(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep,
                               frame: NSRect) throws -> Int {
                guard before.pixelsWide == after.pixelsWide, before.pixelsHigh == after.pixelsHigh else {
                    throw auditError(26, "Capture pixel dimensions changed.")
                }
                let scaleX = CGFloat(before.pixelsWide) / host.bounds.width
                let scaleY = CGFloat(before.pixelsHigh) / host.bounds.height
                let label = NSRect(x: frame.minX + 4, y: frame.minY, width: max(0, frame.width - 32), height: frame.height)
                let x0 = max(0, Int(floor((label.minX - host.bounds.minX) * scaleX)))
                let x1 = min(before.pixelsWide, Int(ceil((label.maxX - host.bounds.minX) * scaleX)))
                let y0 = max(0, Int(floor((label.minY - host.bounds.minY) * scaleY)))
                let y1 = min(before.pixelsHigh, Int(ceil((label.maxY - host.bounds.minY) * scaleY)))
                guard x1 > x0, y1 > y0 else { throw auditError(27, "The menu label crop was empty.") }
                var changed = 0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                              let b = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                            throw auditError(28, "A captured pixel could not be compared.")
                        }
                        if abs(a.redComponent - b.redComponent) > 0.03 ||
                           abs(a.greenComponent - b.greenComponent) > 0.03 ||
                           abs(a.blueComponent - b.blueComponent) > 0.03 ||
                           abs(a.alphaComponent - b.alphaComponent) > 0.03 { changed += 1 }
                    }
                }
                return changed
            }
            func requireSameFrame(_ frame: NSRect, _ reference: NSRect) throws {
                guard abs(reference.minX - frame.minX) < 1, abs(reference.minY - frame.minY) < 1,
                      abs(reference.width - frame.width) < 1, abs(reference.height - frame.height) < 1 else {
                    throw auditError(29, "Menu position changed between comparable crops.")
                }
            }
            var pixelChecks: [[String: Any]] = []
            // A fresh rendering with the same model is a negative control for
            // capture noise; the binding is deliberately not assigned again.
            let repeated = try capture("initial-repeat", selections: initialValues, updateModel: false)
            captureRecords.append(repeated.record)
            var negativeCounts: [Int] = []
            for row in 0..<initialValues.count {
                try requireSameFrame(repeated.frames[row], initial.frames[row])
                let count = try changedPixels(initial.bitmap, repeated.bitmap, frame: initial.frames[row])
                guard count <= 2 else {
                    throw auditError(38, "The unchanged capture is unstable for menu \(row + 1).")
                }
                negativeCounts.append(count)
                pixelChecks.append(["capture": "initial-repeat", "row": row + 1,
                                    "changedPixels": count, "control": "model unchanged"])
            }
            for row in 0..<initialValues.count {
                let initialTitle = fixture.label(row, initialValues[row])
                let widestTitle = fixture.label(row, widestValues[row])
                if initialTitle == widestTitle {
                    pixelChecks.append(["capture": "widest-row-\(row + 1)", "row": row + 1,
                                        "skipped": "Initial and widest titles are identical."])
                    continue
                }
                var selections = initialValues
                selections[row] = widestValues[row]
                let captured = try capture("widest-row-\(row + 1)", selections: selections)
                captureRecords.append(captured.record)
                try requireSameFrame(captured.frames[row], initial.frames[row])
                let count = try changedPixels(initial.bitmap, captured.bitmap, frame: initial.frames[row])
                guard count > negativeCounts[row] + 2 else {
                    throw auditError(30, "The rendered crop did not change for menu \(row + 1).")
                }
                pixelChecks.append(["capture": "widest-row-\(row + 1)", "row": row + 1,
                                    "initialTitle": initialTitle, "selectedTitle": widestTitle,
                                    "changedPixels": count, "negativeControlPixels": negativeCounts[row]])
            }

            for (suffix, selections) in [
                ("minimum", fixture.ranges.map(\.lowerBound)),
                ("maximum", fixture.ranges.map(\.upperBound)),
                ("widest", widestValues),
                ("widest-cell", try values(for: widestCellSelections)),
                ("widest-fitting", try values(for: widestFittingSelections))
            ] {
                let captured = try capture(suffix, selections: selections)
                captureRecords.append(captured.record)
                if ["minimum", "maximum", "widest"].contains(suffix) {
                    for row in 0..<initialValues.count {
                        let initialTitle = fixture.label(row, initialValues[row])
                        let selectedTitle = fixture.label(row, selections[row])
                        guard initialTitle != selectedTitle else {
                            pixelChecks.append(["capture": suffix, "row": row + 1,
                                                "skipped": "Initial and selected titles are identical."])
                            continue
                        }
                        try requireSameFrame(captured.frames[row], initial.frames[row])
                        let count = try changedPixels(initial.bitmap, captured.bitmap, frame: initial.frames[row])
                        guard count > negativeCounts[row] + 2 else {
                            throw auditError(39, "The \(suffix) crop did not change for menu \(row + 1).")
                        }
                        pixelChecks.append(["capture": suffix, "row": row + 1, "initialTitle": initialTitle,
                                            "selectedTitle": selectedTitle, "changedPixels": count,
                                            "negativeControlPixels": negativeCounts[row]])
                    }
                }
                if !baseline {
                    for frame in captured.frames {
                        XCTAssertEqual(frame.width, firstFrame.width, accuracy: 1, "Menu width must remain stable.")
                        XCTAssertEqual(frame.maxX, firstFrame.maxX, accuracy: 1, "Menu right edges must remain aligned.")
                    }
                }
            }
            XCTAssertEqual(store.diagnosticSettings, originalDiagnosticSettings,
                           "Synthetic selections must not change diagnostic settings.")
            XCTAssertEqual(store.claudeRetentionPolicy, originalClaudeRetention,
                           "Synthetic selections must not change retention settings.")
            XCTAssertEqual(storeConnectionCalls, 0, "The synthetic store must not inspect OpenCode.")

            let report: [String: Any] = ["language": language, "theme": theme, "baseline": baseline,
                                         "widestNaturalCell": Double(widestCell),
                                         "widestActualFitting": Double(actualFittingWidths.max() ?? 0),
                                         "widestDetachedFitting": Double(widestFitting), "menus": rows,
                                         "journalButtons": initial.journal, "captures": captureRecords,
                                         "pixelChecks": pixelChecks, "bitmapCalibration": bitmapCalibration,
                                         "hostBounds": rectArray(host.bounds),
                                         "hostFlipped": host.isFlipped,
                                         "windowBackingScale": Double(window.backingScaleFactor),
                                         "widestCapture": "Every menu shows its widest text title via its synthetic SwiftUI binding.",
                                         "widestCellCapture": "Each menu shows its largest cellSize option; ties use title width.",
                                         "widestFittingCapture": "Each menu shows its largest detached fittingSize option; ties use title width.",
                                         "scope": "Native frame, cellSize and detached fittingSize are distinct. Button frames are SwiftUI layout bounds, not painted outlines. PNG and titles still require visual comparison."]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination.appendingPathComponent("settings-width-\(language)-\(theme).json"),
                           options: .atomic)
        }

        for language in ["ru", "en"] {
            for theme in ["light", "dark"] {
                try inspect(language: language, theme: theme)
            }
        }
    }
}
