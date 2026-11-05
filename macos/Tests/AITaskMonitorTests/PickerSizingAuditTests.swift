import AppKit
import SwiftUI
import XCTest
@testable import AITaskMonitor

private final class PickerAuditModel: ObservableObject {
    @Published var selections = [7, 10, 7, 10, 5, 10]
}

private struct PickerAuditView: View {
    @ObservedObject var model: PickerAuditModel
    let language: String
    let sharedTextWidth: CGFloat
    let variants: [Int]
    let fittedControlWidth: CGFloat?
    private let variantNames = ["baseline", "flexible frame", "framed option labels",
                                "buttonSizing flexible: 120 pt", "buttonSizing flexible: max fittingSize"]
    private let ranges = [1...7, 1...10, 1...30, 1...100, 3...10, 1...30]

    init(model: PickerAuditModel, language: String, sharedTextWidth: CGFloat,
         variants: [Int] = [0, 1, 2], fittedControlWidth: CGFloat? = nil) {
        self.model = model
        self.language = language
        self.sharedTextWidth = sharedTextWidth
        self.variants = variants
        self.fittedControlWidth = fittedControlWidth
    }

    private func label(_ row: Int, _ value: Int) -> String {
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
}
