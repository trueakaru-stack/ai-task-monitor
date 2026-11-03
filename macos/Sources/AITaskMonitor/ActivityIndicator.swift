import Foundation
import SwiftUI

struct ActivityIndicatorGeometry {
    let width: CGFloat
    let offsetX: CGFloat

    static func at(_ elapsed: TimeInterval) -> ActivityIndicatorGeometry {
        let period = 1.8
        let remainder = elapsed.truncatingRemainder(dividingBy: period)
        let position = remainder < 0 ? remainder + period : remainder
        let half = min(position, period - position)
        let expanding = half <= 0.45
        let progress = expanding ? half / 0.45 : (half - 0.45) / 0.45
        let eased = (1 - cos(.pi * progress)) / 2
        return ActivityIndicatorGeometry(
            width: CGFloat(expanding ? 4 + 12 * eased : 16 - 12 * eased),
            offsetX: CGFloat(expanding ? 0 : 12 * eased)
        )
    }
}

struct ActivityIndicator: View {
    let isActive: Bool

    var body: some View {
        Group {
            if isActive {
                TimelineView(.periodic(from: Date(), by: 1.0 / 30.0)) { context in
                    let geometry = ActivityIndicatorGeometry.at(context.date.timeIntervalSinceReferenceDate)
                    Canvas { context, _ in
                        let rect = CGRect(x: geometry.offsetX, y: 0, width: geometry.width, height: 4)
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.accentColor))
                    }
                    .frame(width: 16, height: 4)
                }
            } else {
                Circle().fill(isActive ? Color.accentColor : MonitorTheme.muted).frame(width: 4, height: 4)
            }
        }
        .frame(width: 16, height: 4, alignment: .leading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ActivityStatusRow: View {
    let text: String
    let isActive: Bool
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ActivityIndicator(isActive: isActive).padding(.top, 7)
            TruncatingText(text: text, font: .systemFont(ofSize: fontSize), color: .secondaryLabelColor)
                .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
        }
    }
}
