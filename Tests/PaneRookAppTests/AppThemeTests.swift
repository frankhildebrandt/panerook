import AppKit
import XCTest

@testable import PaneRookApp

final class AppThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        suite = "PaneRook.ThemeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        ThemeManager.apply()
        NSApplication.shared.appearance = previousAppearance
        defaults = nil
        super.tearDown()
    }

    func testExistingAppearancePreferenceAndThemeAreAppliedTogether() {
        defaults.set(2, forKey: "appearance")
        defaults.set("grove", forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)

        XCTAssertEqual(ThemeManager.colorScheme, .dark)
        XCTAssertEqual(ThemeManager.theme, .grove)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        XCTAssertEqual(defaults.integer(forKey: "appearance"), 2)
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "grove")
    }

    func testMissingAndUnknownValuesUseSystemAppearanceAndDefaultTheme() {
        for invalid in [false, true] {
            if invalid {
                defaults.set(123, forKey: "appearance")
                defaults.set("removed-theme", forKey: "appTheme")
            }
            ThemeManager.apply(defaults: defaults)
            XCTAssertEqual(ThemeManager.colorScheme, .system)
            XCTAssertEqual(ThemeManager.theme, .paneRook)
            XCTAssertNil(NSApplication.shared.appearance)
        }
    }

    func testApplyingThemeNotifiesExistingSurfacesAndUpdatesTheirColors() throws {
        ThemeManager.apply(defaults: defaults)
        let surface = PaneSurface()
        surface.isActive = true
        surface.appearance = NSAppearance(named: .aqua)
        let initial = surface.layer?.borderColor
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: nil) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        defaults.set("ember", forKey: "appTheme")
        defaults.set(1, forKey: "appearance")
        ThemeManager.apply(defaults: defaults)

        XCTAssertEqual(notifications, 1)
        XCTAssertNotEqual(surface.layer?.borderColor, initial)
        let background = try XCTUnwrap(surface.layer?.backgroundColor)
        let expected = try XCTUnwrap(AppTheme.ember.backgroundColor(for: .light).usingColorSpace(.sRGB))
        let actual = try XCTUnwrap(NSColor(cgColor: background)?.usingColorSpace(.sRGB))
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
    }

    func testDynamicColorsResolveForBothAppearancesWithoutReapplyingTheme() throws {
        defaults.set("ocean", forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        let color = ThemeManager.surfaceColor
        var light: NSColor!
        var dark: NSColor!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = color.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = color.usingColorSpace(.sRGB) }
        XCTAssertGreaterThan(try XCTUnwrap(light).redComponent, try XCTUnwrap(dark).redComponent)
        XCTAssertNil(NSApplication.shared.appearance)
    }

    func testRepeatedApplicationDoesNotNotifyOrReplaceTheNativeAppearance() {
        defaults.set(2, forKey: "appearance")
        defaults.set("ocean", forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        let appearance = NSApplication.shared.appearance
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        ThemeManager.apply(defaults: defaults)
        ThemeManager.apply(defaults: defaults)
        XCTAssertEqual(notifications, 0)
        XCTAssertTrue(NSApplication.shared.appearance === appearance)

        defaults.set("iris", forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(NSApplication.shared.appearance === appearance)
    }

    func testStoredSchemeIsRestoredEvenIfTheNativeAppearanceWasChangedSeparately() {
        defaults.set(2, forKey: "appearance")
        ThemeManager.apply(defaults: defaults)
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        ThemeManager.apply(defaults: defaults)
        XCTAssertEqual(ThemeManager.colorScheme, .dark)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
    }

    func testDefaultSettingsPalettePreservesNeutralReferenceSurfaces() throws {
        defaults.set(AppTheme.paneRook.rawValue, forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        let expected: [(SettingsColorRole, Int, Int)] = [
            (.canvas, 0xFC, 0x00), (.sidebar, 0xF3, 0x11), (.group, 0xFF, 0x03),
            (.border, 0xE4, 0x1C), (.sidebarSelection, 0xE6, 0x1D)
        ]
        for (role, light, dark) in expected {
            for (appearance, value) in [(NSAppearance.Name.aqua, light), (.darkAqua, dark)] {
                let color = try resolve(ThemeManager.settingsColor(role), in: appearance)
                XCTAssertEqual(color.redComponent, CGFloat(value) / 255, accuracy: 0.001)
                XCTAssertEqual(color.greenComponent, color.redComponent, accuracy: 0.001)
                XCTAssertEqual(color.blueComponent, color.redComponent, accuracy: 0.001)
            }
        }
    }

    func testSettingsSurfacesFollowEachThemeAndRemainReadableInBothSchemes() throws {
        var canvases = Set<String>()
        for theme in AppTheme.allCases {
            defaults.set(theme.rawValue, forKey: "appTheme")
            ThemeManager.apply(defaults: defaults)
            for role in SettingsColorRole.allCases {
                let light = try resolve(ThemeManager.settingsColor(role), in: .aqua)
                let dark = try resolve(ThemeManager.settingsColor(role), in: .darkAqua)
                XCTAssertGreaterThan(min(light.redComponent, light.greenComponent, light.blueComponent), 0.70, "\(theme): \(role)")
                XCTAssertLessThan(max(dark.redComponent, dark.greenComponent, dark.blueComponent), 0.40, "\(theme): \(role)")
                XCTAssertEqual(light.alphaComponent, 1, accuracy: 0.001)
                XCTAssertEqual(dark.alphaComponent, 1, accuracy: 0.001)
                if role == .canvas {
                    canvases.insert(String(format: "%.4f/%.4f/%.4f", dark.redComponent, dark.greenComponent, dark.blueComponent))
                }
            }
        }
        XCTAssertEqual(canvases.count, AppTheme.allCases.count)
    }

    func testExistingSettingsColorObjectResolvesTheNewThemeWithoutBeingReplaced() throws {
        defaults.set(AppTheme.ocean.rawValue, forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        let color = ThemeManager.settingsColor(.sidebar)
        let ocean = try resolve(color, in: .darkAqua)
        defaults.set(AppTheme.ember.rawValue, forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        let ember = try resolve(color, in: .darkAqua)
        XCTAssertNotEqual(ocean, ember)
        XCTAssertGreaterThan(ocean.blueComponent, ocean.redComponent)
        XCTAssertGreaterThan(ember.redComponent, ember.blueComponent)
    }

    private func resolve(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        var resolved: NSColor?
        try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    func testEveryThemeProvidesReadableSurfacesAndDistinctLightAndDarkPreviews() throws {
        for theme in AppTheme.allCases {
            let light = try XCTUnwrap(theme.backgroundColor(for: .light).usingColorSpace(.sRGB))
            let dark = try XCTUnwrap(theme.backgroundColor(for: .dark).usingColorSpace(.sRGB))
            XCTAssertGreaterThan(light.redComponent, 0.85, theme.title)
            XCTAssertLessThan(dark.redComponent, 0.3, theme.title)
            XCTAssertEqual(light.alphaComponent, 1, theme.title)
            XCTAssertEqual(dark.alphaComponent, 1, theme.title)
            if theme != .paneRook {
                XCTAssertNotEqual(theme.accentColor(for: .light), theme.accentColor(for: .dark), theme.title)
            }
        }
    }
}
