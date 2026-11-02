import AppKit

/// Settings share the app palette, including their reading surfaces and accents.
enum SettingsStyle {
    static let canvasColor = ThemeManager.settingsColor(.canvas)
    static let sidebarColor = ThemeManager.settingsColor(.sidebar)
    static let groupColor = ThemeManager.settingsColor(.group)
    static let borderColor = ThemeManager.settingsColor(.border)
    static let sidebarSelectionColor = ThemeManager.settingsColor(.sidebarSelection)
    static var secondaryTextColor: NSColor { .secondaryLabelColor }
    static var accentColor: NSColor { ThemeManager.accentColor }

    static func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 16, weight: .medium)
        return field
    }

    static func section(_ title: String, rows: [NSView]) -> NSView {
        let section = NSView()
        let heading = heading(title)
        let group = group(rows)
        for child in [heading, group] {
            child.translatesAutoresizingMaskIntoConstraints = false
            section.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: section.leadingAnchor, constant: 16),
            heading.topAnchor.constraint(equalTo: section.topAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: section.trailingAnchor, constant: -16),
            group.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            group.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            group.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            group.bottomAnchor.constraint(equalTo: section.bottomAnchor)
        ])
        return section
    }

    static func group(_ rows: [NSView]) -> NSView {
        let box = SettingsSurfaceView(color: groupColor, rounded: true)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = SettingsDivider()
                stack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    static func row(_ title: String, detail: String, control: NSView) -> NSView {
        let row = NSView()
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        text.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        if !detail.isEmpty {
            let description = NSTextField(wrappingLabelWithString: detail)
            description.font = .systemFont(ofSize: 12, weight: .regular)
            description.textColor = secondaryTextColor
            text.addArrangedSubview(description)
            description.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        control.setAccessibilityLabel(title)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        for child in [text, control] {
            child.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(child)
        }
        let verticalInset: CGFloat = detail.isEmpty ? 14 : 15
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: verticalInset),
            text.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -verticalInset),
            text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -24),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: detail.isEmpty ? 50 : 66)
        ])
        return row
    }
}

final class SettingsSurfaceView: NSView {
    private let color: NSColor
    private let rounded: Bool
    private var themeObserver: NSObjectProtocol?

    init(color: NSColor, rounded: Bool = false) {
        self.color = color
        self.rounded = rounded
        super.init(frame: .zero)
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        if rounded {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
            path.fill()
            SettingsStyle.borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        } else { bounds.fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

final class SettingsDivider: NSView {
    private var themeObserver: NSObjectProtocol?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    override func draw(_ dirtyRect: NSRect) { SettingsStyle.borderColor.setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A quiet full-width navigation row with the same hit area as its painted surface.
final class SettingsNavigationButton: NSButton {
    init(title: String, symbol: String) {
        super.init(frame: .zero)
        cell = SettingsNavigationCell(textCell: title)
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7)
        if selected || cell?.isHighlighted == true {
            SettingsStyle.sidebarSelectionColor.setFill()
            shape.fill()
        }
        let color: NSColor
        if selected { color = ThemeManager.theme == .paneRook ? .labelColor : SettingsStyle.accentColor }
        else { color = SettingsStyle.secondaryTextColor }
        image?.withSymbolConfiguration(.init(paletteColors: [color]))?
            .draw(in: NSRect(x: 10, y: bounds.midY - 8, width: 16, height: 16))
        (title as NSString).draw(in: NSRect(x: 34, y: bounds.midY - 8, width: bounds.width - 42, height: 17), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular), .foregroundColor: color
        ])
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set(); shape.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

private final class SettingsNavigationCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard isEnabled, cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        return [.contentArea, .trackableArea]
    }
}

/// Preserve the native search/cancel controls without a separate, unthemed bezel.
final class SettingsSearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        let text = super.searchTextRect(forBounds: rect)
        let leading = searchButtonRect(forBounds: rect).maxX + 6
        return NSRect(x: leading, y: text.minY, width: max(0, text.maxX - leading), height: text.height)
    }
}
