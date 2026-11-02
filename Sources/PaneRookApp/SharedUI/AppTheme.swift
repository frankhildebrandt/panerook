import AppKit

enum AppColorScheme: Int, CaseIterable {
    case system = 0, light = 1, dark = 2

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Hell"
        case .dark: return "Dunkel"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Shared surface roles used throughout the settings dialog.
enum SettingsColorRole: CaseIterable {
    case canvas, sidebar, group, border, sidebarSelection

    fileprivate var palette: (light: Int, dark: Int, lightTint: CGFloat, darkTint: CGFloat) {
        switch self {
        case .canvas: return (0xFC, 0x00, 0.035, 0.10)
        case .sidebar: return (0xF3, 0x11, 0.075, 0.14)
        case .group: return (0xFF, 0x03, 0.025, 0.10)
        case .border: return (0xE4, 0x1C, 0.20, 0.24)
        case .sidebarSelection: return (0xE6, 0x1D, 0.15, 0.22)
        }
    }
}

enum AppTheme: String, CaseIterable {
    case paneRook, rose, grove, ocean, ember, iris

    var title: String {
        switch self {
        case .paneRook: return "PaneRook"
        case .rose: return "Rose"
        case .grove: return "Grove"
        case .ocean: return "Ocean"
        case .ember: return "Ember"
        case .iris: return "Iris"
        }
    }

    func accentColor(for scheme: AppColorScheme) -> NSColor {
        accentColor(in: scheme.appearance ?? NSApplication.shared.effectiveAppearance)
    }

    func backgroundColor(for scheme: AppColorScheme) -> NSColor {
        surfaceColor(in: scheme.appearance ?? NSApplication.shared.effectiveAppearance)
    }

    fileprivate func accentColor(in appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let value: UInt32
        switch self {
        case .paneRook: return NSColor.controlAccentColor.resolved(in: appearance)
        case .rose: value = dark ? 0xF58BB2 : 0xB72E67
        case .grove: value = dark ? 0x72C7A0 : 0x21744E
        case .ocean: value = dark ? 0x73BEF2 : 0x126AAB
        case .ember: value = dark ? 0xEDA979 : 0xAD501E
        case .iris: value = dark ? 0xB7A0F5 : 0x7545BC
        }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    fileprivate func surfaceColor(in appearance: NSAppearance) -> NSColor {
        let base = NSColor.textBackgroundColor.resolved(in: appearance)
        guard self != .paneRook else { return base }
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return base.blended(withFraction: dark ? 0.08 : 0.025, of: accentColor(in: appearance)) ?? base
    }

    fileprivate func settingsColor(_ role: SettingsColorRole, in appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let palette = role.palette
        let value = CGFloat(dark ? palette.dark : palette.light) / 255
        let base = NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        guard self != .paneRook else { return base }
        return base.blended(withFraction: dark ? palette.darkTint : palette.lightTint,
                            of: accentColor(in: appearance)) ?? base
    }

}

/// Appearance uses the existing preference key. Theme colors remain dynamic so
/// system appearance and accessibility changes also reach already-open views.
enum ThemeManager {
    static let didChange = Notification.Name("PaneRook.ThemeDidChange")
    private(set) static var theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "") ?? .paneRook
    private(set) static var colorScheme = AppColorScheme(rawValue: UserDefaults.standard.integer(forKey: "appearance")) ?? .system

    static var accentColor: NSColor {
        NSColor(name: nil) { appearance in theme.accentColor(in: appearance) }
    }

    static var surfaceColor: NSColor {
        NSColor(name: nil) { appearance in theme.surfaceColor(in: appearance) }
    }

    /// Resolve the current theme lazily so existing settings views also follow
    /// palette changes without rebuilding their controls or layout.
    static func settingsColor(_ role: SettingsColorRole) -> NSColor {
        NSColor(name: nil) { appearance in theme.settingsColor(role, in: appearance) }
    }

    static func apply(defaults: UserDefaults = .standard) {
        let nextTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .paneRook
        let nextScheme = AppColorScheme(rawValue: defaults.integer(forKey: "appearance")) ?? .system
        let application = NSApplication.shared
        let nextAppearance = nextScheme.appearance
        let appearanceChanged = application.appearance?.name != nextAppearance?.name
        guard theme != nextTheme || colorScheme != nextScheme || appearanceChanged else { return }
        theme = nextTheme
        colorScheme = nextScheme
        // Changing only the palette does not require AppKit to re-style every control.
        if appearanceChanged { application.appearance = nextAppearance }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

private extension NSColor {
    func resolved(in appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance {
            color = usingColorSpace(.sRGB) ?? self
        }
        return color
    }
}
