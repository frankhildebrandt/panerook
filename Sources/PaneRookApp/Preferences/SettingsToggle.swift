import AppKit

/// A compact themed switch using AppKit's native checkbox tracking and keyboard behavior.
final class SettingsToggle: NSButton {
    private var themeObserver: NSObjectProtocol?

    convenience init() { self.init(frame: .zero) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = SettingsToggleCell(textCell: "")
        setButtonType(.switch)
        title = ""
        isBordered = false
        allowsMixedState = false
        focusRingType = .exterior
        setAccessibilityRole(.checkBox)
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 22) }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let track = NSRect(x: bounds.midX - 15, y: bounds.midY - 8, width: 30, height: 16)
        let path = NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8)
        let trackColor = on ? SettingsStyle.accentColor : SettingsStyle.borderColor
        trackColor.withAlphaComponent(alpha).setFill()
        path.fill()
        if cell?.isHighlighted == true {
            NSColor.black.withAlphaComponent(0.12).setFill()
            path.fill()
        }
        let knob = NSRect(x: on ? track.maxX - 14 : track.minX + 2,
                          y: track.minY + 2, width: 12, height: 12)
        NSColor(white: on ? 1 : 0.64, alpha: alpha).setFill()
        NSBezierPath(ovalIn: knob).fill()
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

private final class SettingsToggleCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}
