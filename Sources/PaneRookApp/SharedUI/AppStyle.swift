import AppKit

/// Presentation only. Controls retain their targets, key equivalents and responder behavior.
enum AppStyle {
    static func background(material: NSVisualEffectView.Material = .underWindowBackground) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    static func glass(around content: NSView, cornerRadius: CGFloat = 18) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            // Xcode 27 adds this SDK property; keep builds with Xcode 26 working.
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            #endif
            return glass
        }
        let effect = background(material: .headerView)
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        ])
        return effect
    }

    static func configureField(_ field: NSTextField) {
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    static func configureButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if #available(macOS 26.0, *) {
            button.borderShape = .capsule
        }
    }
}

/// An opaque reading surface; system colors follow appearance and increased contrast.
final class PaneSurface: NSView {
    var isActive = false { didSet { updateColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderWidth = isActive ? 1 : 0.5
            layer?.borderColor = (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.4) : .separatorColor).cgColor
        }
    }
}
