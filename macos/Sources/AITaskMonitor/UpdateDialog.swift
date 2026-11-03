import AppKit
import SwiftUI

struct UpdateDialog: View {
    @EnvironmentObject private var store: TaskStore
    let update: AvailableUpdate

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text("Доступна новая версия").font(.system(size: 19, weight: .semibold))
                Text("Версия \(update.version) доступна для скачивания")
                    .font(.system(size: 13)).padding(.top, 14)
                Text("Скачайте приложение, полностью закройте старую версию и переустановите новую.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                if store.updateOpenError {
                    Text("Не удалось открыть страницу загрузки.").font(.system(size: 12))
                        .foregroundStyle(MonitorTheme.secondary).padding(.top, 10)
                }
                HStack(spacing: 12) {
                    Button("Позже") { store.dismissUpdate() }
                        .keyboardShortcut(.cancelAction)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(Squircle(radius: 7).fill(MonitorTheme.track))
                    Button("Скачать") { openDownload() }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .foregroundStyle(accentForeground)
                        .background(Squircle(radius: 7).fill(Color.accentColor))
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .padding(.top, 22)
            }
            .padding(24)
            .frame(width: 368, alignment: .leading)
            .background(Squircle(radius: 16).fill(MonitorTheme.raised))
            .overlay(Squircle(radius: 16).stroke(MonitorTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.48), radius: 13, y: 8)
            .accessibilityElement(children: .contain)
        }
    }

    private var accentForeground: Color {
        guard let rgb = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.61 ? .black : .white
    }

    private func openDownload() {
        let components = update.url.path.split(separator: "/").map(String.init)
        guard components.count == 6,
              ReleaseSelector.trustedURL(update.url.absoluteString, tag: components[4], asset: components[5], platform: "macos") != nil,
              NSWorkspace.shared.open(update.url) else { store.updateOpenError = true; return }
        store.dismissUpdate()
    }
}
