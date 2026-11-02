import AppKit
import SwiftUI

struct TruncatingText: NSViewRepresentable {
    let text: String
    var font: NSFont
    var color: NSColor
    var lineLimit = 1

    func makeNSView(context: Context) -> TruncatingTextField {
        let field = TruncatingTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = lineLimit
        field.cell?.truncatesLastVisibleLine = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: TruncatingTextField, context: Context) {
        field.stringValue = text
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lineLimit
        field.fullText = text
        field.needsLayout = true
    }
}

final class TruncatingTextField: NSTextField {
    var fullText = ""

    override func layout() {
        super.layout()
        guard bounds.width > 0, let font else { toolTip = nil; return }
        let width = (fullText as NSString).size(withAttributes: [.font: font]).width
        toolTip = maximumNumberOfLines == 1 && width > bounds.width + 1 ? fullText : nil
    }
}
