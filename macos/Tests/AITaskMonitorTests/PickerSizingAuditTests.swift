import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

private final class PickerAuditModel: ObservableObject {
    @Published var selections = [7, 10, 7, 10, 5, 10]
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
            let view = RootView().environmentObject(store)
                .environment(\.settingsPreviewEnd, true)
                .environment(\.settingsPreviewClaude, .connected)
                .environment(\.settingsPreviewCloud, .disconnected)
                .environment(\.settingsPreviewKimi, .disconnected)
                .environment(\.settingsPreviewHermes, .absent)
                .environment(\.settingsPreviewOpenCode, openCodePreview)
                .environment(\.colorScheme, theme == "dark" ? .dark : .light)
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
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(previewStateCalls, 0, "SettingsView must use the synthetic OpenCode state.")
            XCTAssertGreaterThan(previewPresenceCalls, 0, "SettingsView must use the synthetic OpenCode presence.")
            XCTAssertEqual(storeConnectionCalls, 0, "The synthetic store must not inspect OpenCode.")

            func capture(_ suffix: String) throws {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "SyntheticPickerAudit", code: 6)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "SyntheticPickerAudit", code: 7)
                }
                try png.write(to: destination.appendingPathComponent("settings-width-\(language)-\(theme)-\(suffix).png"),
                              options: .atomic)
            }
            try capture("initial")

            let fixture = PickerAuditView(model: PickerAuditModel(), language: language, sharedTextWidth: 0)
            let popupButtons = descendants(host).compactMap { $0 as? NSPopUpButton }
            var settingsButtons: [NSPopUpButton] = []
            for (row, values) in fixture.ranges.enumerated() {
                let expected = Set(values.map { fixture.label(row, $0) })
                let matches = popupButtons.filter {
                    Set($0.itemTitles.filter { !$0.isEmpty }) == expected
                }
                XCTAssertEqual(matches.count, 1, "Expected one actual SettingsView popup for row \(row + 1).")
                guard let button = matches.first, matches.count == 1 else {
                    throw NSError(domain: "SyntheticPickerAudit", code: 8)
                }
                settingsButtons.append(button)
            }

            var rows: [[String: Any]] = []
            var naturalWidths: [CGFloat] = []
            var actualFittingWidths: [CGFloat] = []
            var detachedFittingWidths: [CGFloat] = []
            var frameWidths: [CGFloat] = []
            var originalSelections: [Int] = []
            var widestTextSelections: [PickerWidthChoice] = []
            var widestCellSelections: [PickerWidthChoice] = []
            var widestFittingSelections: [PickerWidthChoice] = []
            for (row, button) in settingsButtons.enumerated() {
                let original = button.indexOfSelectedItem
                guard original >= 0, let cell = button.cell as? NSPopUpButtonCell else {
                    throw NSError(domain: "SyntheticPickerAudit", code: 9)
                }
                originalSelections.append(original)
                let rect = button.convert(button.bounds, to: host)
                let drawingRect = cell.drawingRect(forBounds: button.bounds)
                let visibleRect = button.visibleRect
                XCTAssertGreaterThanOrEqual(visibleRect.width, button.bounds.width - 1,
                                            "Each menu must be visible in the captured settings viewport.")
                XCTAssertGreaterThanOrEqual(visibleRect.height, button.bounds.height - 1,
                                            "Each menu must be visible in the captured settings viewport.")
                frameWidths.append(rect.width)
                let measure = NSPopUpButton(frame: .zero, pullsDown: false)
                measure.controlSize = .large
                measure.addItems(withTitles: fixture.ranges[row].map { fixture.label(row, $0) })
                var choices: [PickerWidthChoice] = []
                var fontUnavailable = false
                var attributedTitleMismatch = false
                for index in 0..<button.numberOfItems {
                    guard let item = button.item(at: index), !item.title.isEmpty else { continue }
                    button.selectItem(at: index)
                    measure.selectItem(withTitle: item.title)
                    guard button.selectedItem?.title == item.title, measure.selectedItem?.title == item.title else {
                        throw NSError(domain: "SyntheticPickerAudit", code: 12)
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
                        throw NSError(domain: "SyntheticPickerAudit", code: 11)
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
                    throw NSError(domain: "SyntheticPickerAudit", code: 13)
                }
                widestTextSelections.append(widestText)
                widestCellSelections.append(widestCellChoice)
                widestFittingSelections.append(widestFittingChoice)
                rows.append(["row": row + 1,
                             "frameInHost": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) },
                             "drawingRectInControl": [drawingRect.minX, drawingRect.minY,
                                                      drawingRect.width, drawingRect.height].map { Double($0) },
                             "frameWidth": Double(rect.width), "drawingWidth": Double(drawingRect.width),
                             "visibleWidth": Double(visibleRect.width),
                             "visibleHeight": Double(visibleRect.height),
                             "choiceMeasurements": choices.map(\.metrics),
                             "widestText": widestText.metrics, "widestCell": widestCellChoice.metrics,
                             "widestDetachedFitting": widestFittingChoice.metrics,
                             "selectedTitle": button.selectedItem?.title ?? "",
                             "enabled": button.isEnabled])
            }
            guard let widestCell = naturalWidths.max(), widestCell.isFinite, widestCell > 0,
                  let widestFitting = detachedFittingWidths.max(), widestFitting.isFinite, widestFitting > 0,
                  let firstFrame = frameWidths.first else {
                throw NSError(domain: "SyntheticPickerAudit", code: 10)
            }
            if !baseline {
                for width in frameWidths {
                    XCTAssertEqual(width, firstFrame, accuracy: 1, "Actual menu control frames must match.")
                    XCTAssertEqual(width, widestFitting, accuracy: 1,
                                   "Each actual control frame must match the measured AppKit fitting width.")
                }
            }

            // Change the native displayed selection without sending an action or altering app settings.
            // Binding updates and keyboard interaction require separate checks.
            for (suffix, useLastItem) in [("minimum", false), ("maximum", true)] {
                for (row, button) in settingsButtons.enumerated() {
                    let value = useLastItem ? fixture.ranges[row].upperBound : fixture.ranges[row].lowerBound
                    button.selectItem(withTitle: fixture.label(row, value))
                }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                for (row, button) in settingsButtons.enumerated() {
                    let expectedValue = useLastItem ? fixture.ranges[row].upperBound : fixture.ranges[row].lowerBound
                    XCTAssertEqual(button.selectedItem?.title, fixture.label(row, expectedValue))
                    if !baseline {
                        let width = button.convert(button.bounds, to: host).width
                        XCTAssertEqual(width, firstFrame, accuracy: 1, "Menu width must remain stable after selection changes.")
                    }
                }
                try capture(suffix)
                for (button, index) in zip(settingsButtons, originalSelections) {
                    button.selectItem(at: index)
                }
            }
            for (suffix, selections) in [("widest", widestTextSelections),
                                         ("widest-cell", widestCellSelections),
                                         ("widest-fitting", widestFittingSelections)] {
                for (button, selection) in zip(settingsButtons, selections) {
                    button.selectItem(withTitle: selection.title)
                }
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                for (button, selection) in zip(settingsButtons, selections) {
                    XCTAssertEqual(button.selectedItem?.title, selection.title,
                                   "The widest-option capture must show the measured title.")
                    if !baseline {
                        XCTAssertEqual(button.convert(button.bounds, to: host).width, firstFrame, accuracy: 1,
                                       "Menu width must remain stable for the widest option.")
                    }
                }
                try capture(suffix)
                for (button, index) in zip(settingsButtons, originalSelections) {
                    button.selectItem(at: index)
                }
            }
            XCTAssertEqual(store.diagnosticSettings, originalDiagnosticSettings,
                           "Synthetic native selection must not change diagnostic settings.")
            XCTAssertEqual(store.claudeRetentionPolicy, originalClaudeRetention,
                           "Synthetic native selection must not change retention settings.")
            XCTAssertEqual(storeConnectionCalls, 0, "The synthetic store must not inspect OpenCode.")

            let journalTitles = language == "ru" ? ["Открыть журнал", "Очистить"] : ["Open journal", "Clear"]
            let journalControls = descendants(host).compactMap { $0 as? NSButton }
            var journal: [[String: Any]] = []
            for title in journalTitles {
                let matches = journalControls.filter { $0.title == title || $0.accessibilityLabel() == title }
                XCTAssertEqual(matches.count, 1, "Expected one actual journal button named \(title).")
                guard let button = matches.first, matches.count == 1 else { continue }
                let rect = button.convert(button.bounds, to: host)
                XCTAssertGreaterThanOrEqual(button.visibleRect.width, button.bounds.width - 1,
                                            "Journal buttons must be visible in the captured settings viewport.")
                XCTAssertGreaterThanOrEqual(button.visibleRect.height, button.bounds.height - 1,
                                            "Journal buttons must be visible in the captured settings viewport.")
                journal.append(["title": title, "width": Double(rect.width), "height": Double(rect.height),
                                "frameInHost": [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) }])
            }

            let report: [String: Any] = ["language": language, "theme": theme, "baseline": baseline,
                                         "widestNaturalCell": Double(widestCell),
                                         "widestActualFitting": Double(actualFittingWidths.max() ?? 0),
                                         "widestDetachedFitting": Double(widestFitting), "menus": rows,
                                         "journalButtons": journal,
                                         "hostBounds": [host.bounds.minX, host.bounds.minY,
                                                        host.bounds.width, host.bounds.height].map { Double($0) },
                                         "hostFlipped": host.isFlipped,
                                         "windowBackingScale": Double(window.backingScaleFactor),
                                         "widestCapture": "Each menu shows its widest title measured with the observed control or item font.",
                                         "widestCellCapture": "Each menu shows the option with the largest actual cellSize; ties use title width.",
                                         "widestFittingCapture": "Each menu shows the option with the largest detached fittingSize; ties use title width.",
                                         "scope": "Cell and fitting sizes are distinct. Native frames and PNG require visual comparison to verify the painted outline."]
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
