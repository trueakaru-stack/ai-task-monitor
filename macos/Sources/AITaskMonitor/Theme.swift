import SwiftUI

enum MonitorTheme {
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let track = Color(nsColor: .separatorColor).opacity(0.72)
    static let tooltip = Color(nsColor: .underPageBackgroundColor)
}

struct Squircle: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.18, style: .continuous)
    }
}
