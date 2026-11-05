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
    private let variants = ["baseline", "flexible frame", "framed option labels"]
    private let ranges = [1...7, 1...10, 1...30, 1...100, 3...10, 1...30]

    init(model: PickerAuditModel, language: String, sharedTextWidth: CGFloat) {
        self.model = model
        self.language = language
        self.sharedTextWidth = sharedTextWidth
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

    @ViewBuilder private func picker(_ row: Int, variant: Int) -> some View {
        let selection = Binding(get: { model.selections[row] }, set: { model.selections[row] = $0 })
        if variant == 1 {
            Picker("Synthetic option", selection: selection) { options(row, framed: false) }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity).frame(width: 120)
        } else {
            Picker("Synthetic option", selection: selection) { options(row, framed: variant == 2) }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(variants.enumerated()), id: \.offset) { variant, title in
                Text(title).font(.system(size: 12, weight: .semibold))
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
        for language in ["ru", "en"] {
            for theme in ["light", "dark"] {
                let width = PickerAuditView.textWidth(language: language)
                let model = PickerAuditModel()
                let root = PickerAuditView(model: model, language: language, sharedTextWidth: width)
                    .environment(\.colorScheme, theme == "dark" ? .dark : .light)
                let host = NSHostingView(rootView: root)
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
                func capture(_ state: String) throws {
                    host.layoutSubtreeIfNeeded()
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        throw NSError(domain: "SyntheticPickerAudit", code: 2)
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "SyntheticPickerAudit", code: 3)
                    }
                    try png.write(to: destination.appendingPathComponent("picker-\(language)-\(theme)-\(state).png"), options: .atomic)
                }
                try capture("current")
                model.selections = [7, 10, 30, 100, 10, 30]
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                try capture("maximum")
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                let nativeControls = descendants(host).filter { $0 is NSPopUpButton }.count
                metadata.append(["language": language, "theme": theme,
                                 "sharedTextWidth": Double(width), "nsPopUpButtonCount": nativeControls])
                window.close()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("picker-geometry.json"), options: .atomic)
    }
}
