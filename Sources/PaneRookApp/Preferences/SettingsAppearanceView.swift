import AppKit

/// The appearance page keeps native radio-button behavior while drawing useful
/// previews of the selected scheme and each theme's light and dark palettes.
final class SettingsAppearanceView: NSView {
    private let defaults: UserDefaults
    private let onChange: () -> Void
    private var cards: [AppearanceCard] = []
    private var themeObserver: NSObjectProtocol?

    init(defaults: UserDefaults, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init(frame: .zero)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        content.addArrangedSubview(heading("Farbschema"))
        let schemes = row(AppColorScheme.allCases.map { card(.scheme($0)) }, height: 144)
        content.addArrangedSubview(schemes)
        schemes.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        content.setCustomSpacing(32, after: schemes)
        content.addArrangedSubview(heading("Themes"))

        let themes = AppTheme.allCases
        for start in stride(from: 0, to: themes.count, by: 3) {
            let items = themes[start..<min(start + 3, themes.count)].map { card(.theme($0)) }
            let themeRow = row(items, height: 118)
            content.addArrangedSubview(themeRow)
            themeRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        let hint = NSTextField(wrappingLabelWithString: "Farbschema und Theme werden sofort angewendet und für den nächsten Start gespeichert. „System“ folgt dem Erscheinungsbild von macOS.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = SettingsStyle.secondaryTextColor
        content.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        refreshSelection()
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSelection()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }

    private func heading(_ text: String) -> NSView {
        let container = NSView()
        let label = SettingsStyle.heading(text)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func card(_ choice: AppearanceCard.Choice) -> AppearanceCard {
        let card = AppearanceCard(choice: choice)
        card.target = self
        card.action = #selector(selectCard(_:))
        cards.append(card)
        return card
    }

    private func row(_ cards: [AppearanceCard], height: CGFloat) -> NSView {
        // Explicit edges keep the cards filling the supplied page width rather
        // than inheriting the radio cells' much narrower title fitting sizes.
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: height).isActive = true
        for (index, card) in cards.enumerated() {
            card.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: row.topAnchor),
                card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                card.widthAnchor.constraint(greaterThanOrEqualToConstant: 140)
            ])
            if index == 0 {
                card.leadingAnchor.constraint(equalTo: row.leadingAnchor).isActive = true
            } else {
                card.leadingAnchor.constraint(equalTo: cards[index - 1].trailingAnchor, constant: 12).isActive = true
                card.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true
            }
            if index == cards.count - 1 { card.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true }
        }
        return row
    }

    @objc private func selectCard(_ sender: AppearanceCard) {
        let changed: Bool
        switch sender.choice {
        case .scheme(let scheme):
            changed = scheme != (AppColorScheme(rawValue: defaults.integer(forKey: "appearance")) ?? .system)
            if changed { defaults.set(scheme.rawValue, forKey: "appearance") }
        case .theme(let theme):
            changed = theme != (AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .paneRook)
            if changed { defaults.set(theme.rawValue, forKey: "appTheme") }
        }
        refreshSelection()
        if changed { onChange() }
    }

    private func refreshSelection() {
        let scheme = AppColorScheme(rawValue: defaults.integer(forKey: "appearance")) ?? .system
        let theme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .paneRook
        for card in cards {
            switch card.choice {
            case .scheme(let value): card.state = value == scheme ? .on : .off
            case .theme(let value): card.state = value == theme ? .on : .off
            }
            card.previewTheme = theme
            card.needsDisplay = true
        }
    }
}

private final class AppearanceCard: NSButton {
    enum Choice {
        case scheme(AppColorScheme)
        case theme(AppTheme)

        var title: String {
            switch self {
            case .scheme(let scheme): return scheme.title
            case .theme(let theme): return theme.title
            }
        }
    }

    let choice: Choice
    var previewTheme = AppTheme.paneRook

    init(choice: Choice) {
        self.choice = choice
        super.init(frame: .zero)
        // Native radio cells otherwise track only their small glyph/title area,
        // even though this button draws a full-size preview card.
        cell = AppearanceCardCell(textCell: choice.title)
        title = choice.title
        setButtonType(.radio)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityLabel(choice.title)
        setAccessibilityRole(.radioButton)
        switch choice {
        case .scheme(let scheme): identifier = .init("appearance.scheme.\(scheme)")
        case .theme(let theme): identifier = .init("appearance.theme.\(theme.rawValue)")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let accent = SettingsStyle.accentColor
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 12, yRadius: 12)
        let background = SettingsStyle.groupColor
        (cell?.isHighlighted == true ? background.blended(withFraction: 0.06, of: accent) ?? background : background).setFill()
        outline.fill()
        (selected ? accent : SettingsStyle.borderColor).setStroke()
        outline.lineWidth = selected ? 2 : 1
        outline.stroke()

        switch choice {
        case .scheme(let scheme): drawScheme(scheme)
        case .theme(let theme): drawTheme(theme)
        }

        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            outline.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawScheme(_ scheme: AppColorScheme) {
        let preview = NSRect(x: 10, y: 34, width: bounds.width - 20, height: bounds.height - 44)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: preview, xRadius: 7, yRadius: 7).addClip()
        drawMiniature(in: preview, dark: scheme == .dark)
        if scheme == .system {
            NSBezierPath(rect: NSRect(x: preview.midX, y: preview.minY, width: preview.width / 2, height: preview.height)).addClip()
            drawMiniature(in: preview, dark: true)
        }
        NSGraphicsContext.restoreGraphicsState()
        let textRect = NSRect(x: 8, y: 11, width: bounds.width - 16, height: 16)
        drawLabel(choice.title, in: textRect, centered: true)
    }

    private func drawMiniature(in rect: NSRect, dark: Bool) {
        let scheme: AppColorScheme = dark ? .dark : .light
        let background = previewTheme.backgroundColor(for: scheme)
        let accent = previewTheme.accentColor(for: scheme)
        let ink = dark ? NSColor.white : NSColor.black
        background.setFill()
        rect.fill()
        let toolbar = NSRect(x: rect.minX, y: rect.maxY - 17, width: rect.width, height: 17)
        ink.withAlphaComponent(dark ? 0.06 : 0.035).setFill()
        toolbar.fill()
        for index in 0..<3 {
            fillRounded(NSRect(x: rect.minX + 7 + CGFloat(index) * 6, y: toolbar.midY - 1.5, width: 3, height: 3), radius: 1.5, color: ink.withAlphaComponent(0.23))
        }
        fillRounded(NSRect(x: rect.midX - rect.width * 0.12, y: toolbar.midY - 2, width: rect.width * 0.24, height: 4), radius: 2, color: ink.withAlphaComponent(0.13))

        let gap: CGFloat = 7
        let panelWidth = (rect.width - gap * 3) / 2
        for panel in 0..<2 {
            let x = rect.minX + gap + CGFloat(panel) * (panelWidth + gap)
            let top = toolbar.minY - 10
            fillRounded(NSRect(x: x, y: top, width: panelWidth * 0.78, height: 4), radius: 2, color: ink.withAlphaComponent(0.17))
            for line in 0..<4 {
                let y = top - 11 - CGFloat(line) * 10
                if line == 1 && panel == 0 {
                    fillRounded(NSRect(x: x - 2, y: y - 3, width: panelWidth + 2, height: 9), radius: 2, color: accent.withAlphaComponent(dark ? 0.28 : 0.16))
                }
                fillRounded(NSRect(x: x + 1, y: y, width: 4, height: 4), radius: 1, color: accent.withAlphaComponent(0.7))
                let widths: [CGFloat] = [0.63, 0.49, 0.69, 0.42]
                fillRounded(NSRect(x: x + 9, y: y, width: max(6, panelWidth * widths[line] - 9), height: 4), radius: 2, color: ink.withAlphaComponent(0.16))
            }
        }
        fillRounded(NSRect(x: rect.midX - 0.25, y: rect.minY + 15, width: 0.5, height: rect.height - 37), radius: 0, color: ink.withAlphaComponent(0.12))
        fillRounded(NSRect(x: rect.minX + 7, y: rect.minY + 6, width: rect.width - 14, height: 6), radius: 3, color: ink.withAlphaComponent(0.07))
        fillRounded(NSRect(x: rect.maxX - 16, y: rect.minY + 6, width: 6, height: 6), radius: 3, color: accent)
    }

    private func drawTheme(_ theme: AppTheme) {
        let diameter: CGFloat = 43
        let gap: CGFloat = 17
        let left = bounds.midX - diameter - gap / 2
        let y: CGFloat = 45
        drawOrb(in: NSRect(x: left, y: y, width: diameter, height: diameter), theme: theme, scheme: .light)
        drawOrb(in: NSRect(x: left + diameter + gap, y: y, width: diameter, height: diameter), theme: theme, scheme: .dark)
        drawLabel(choice.title, in: NSRect(x: 13, y: 13, width: bounds.width - 44, height: 17), centered: false)
        if state == .on {
            let check = NSRect(x: bounds.maxX - 28, y: 14, width: 15, height: 15)
            SettingsStyle.accentColor.setFill()
            NSBezierPath(ovalIn: check).fill()
            let mark = NSBezierPath()
            mark.move(to: NSPoint(x: check.minX + 4, y: check.midY))
            mark.line(to: NSPoint(x: check.minX + 6.5, y: check.minY + 4.5))
            mark.line(to: NSPoint(x: check.maxX - 3.5, y: check.maxY - 4))
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            NSColor.white.setStroke()
            mark.stroke()
        }
    }

    private func drawOrb(in rect: NSRect, theme: AppTheme, scheme: AppColorScheme) {
        let accent = theme.accentColor(for: scheme)
        let light = scheme == .light
        let highlight = accent.blended(withFraction: light ? 0.83 : 0.12, of: .white) ?? accent
        let shadow = accent.blended(withFraction: light ? 0.08 : 0.72, of: .black) ?? accent
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.22)
        drop.shadowBlurRadius = 3
        drop.shadowOffset = NSSize(width: 0, height: -1)
        drop.set()
        shadow.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors: [highlight, accent, shadow])?.draw(in: circle, angle: -45)
        let glow = NSGradient(starting: NSColor.white.withAlphaComponent(light ? 0.75 : 0.22), ending: NSColor.white.withAlphaComponent(0))
        glow?.draw(in: circle, relativeCenterPosition: NSPoint(x: -0.4, y: 0.5))
        NSColor.black.withAlphaComponent(0.12).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
    }

    private func drawLabel(_ label: String, in rect: NSRect, centered: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: state == .on ? .medium : .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }

    private func fillRounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }
}

/// Keep native button tracking, keyboard activation and accessibility, while
/// making the entire painted card respond to a single mouse click.
private final class AppearanceCardCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        let point = controlView.convert(event.locationInWindow, from: nil)
        guard isEnabled, cellFrame.contains(point) else { return [] }
        return [.contentArea, .trackableArea]
    }
}
