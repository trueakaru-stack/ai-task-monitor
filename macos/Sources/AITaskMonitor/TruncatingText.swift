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
    private var hintPanel: NSPanel?
    private var tracking: NSTrackingArea?
    private var isTruncated = false

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, let font else { isTruncated = false; return }
        let width = (fullText as NSString).size(withAttributes: [.font: font]).width
        isTruncated = maximumNumberOfLines == 1 && width > bounds.width + 1
        setAccessibilityHelp(isTruncated ? fullText : nil)
        if !isTruncated { closeHint() }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isTruncated, hintPanel == nil, let owner = window else { return }
        let panel = makeHintPanel(text: fullText)
        let local = convert(bounds, to: nil)
        let anchor = owner.convertToScreen(local)
        let screen = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - panel.frame.height - 4)
        if origin.y < screen.minY + 4 { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - panel.frame.width - 4)
        panel.setFrameOrigin(origin)
        owner.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        hintPanel = panel
    }

    override func mouseExited(with event: NSEvent) {
        closeHint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeHint() }
    }

    func makeHintPanel(text: String) -> NSPanel {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = isDarkAppearance ? NSColor(calibratedWhite: 0.94, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
        label.maximumNumberOfLines = 0
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: 336, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font!]
        ).integral.size
        let size = NSSize(width: min(360, max(120, textSize.width + 24)), height: textSize.height + 20)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = hintBackground.cgColor
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        label.frame = NSRect(x: 12, y: 10, width: size.width - 24, height: size.height - 20)
        content.addSubview(label)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.contentView = content
        return panel
    }

    private var hintBackground: NSColor {
        isDarkAppearance ? NSColor(calibratedWhite: 0.09, alpha: 1) : NSColor(calibratedWhite: 0.88, alpha: 1)
    }

    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func closeHint() {
        guard let panel = hintPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        hintPanel = nil
    }
}
