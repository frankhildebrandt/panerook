import AppKit
import XCTest

@testable import PaneRookApp

final class SettingsDialogTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testBorderlessSearchKeepsTextClearOfItsMagnifyingGlass() throws {
        let cell = SettingsSearchFieldCell(textCell: "")
        cell.isBordered = false
        let bounds = NSRect(x: 0, y: 0, width: 208, height: 28)
        XCTAssertGreaterThan(cell.searchTextRect(forBounds: bounds).minX, cell.searchButtonRect(forBounds: bounds).maxX)
        XCTAssertGreaterThan(cell.searchTextRect(forBounds: bounds).width, 100)
    }

    func testSearchFindsSettingLabelsAcrossCategories() {
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("Zeilenhöhe") }, [.panels])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("Theme dunkel") }, [.appearance])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("F5") }, [.keyboard])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("VFS Timeout") }, [.connections])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("unbekannter Suchbegriff") }, [])
    }

    func testEverySettingsPageFitsTheResizableDialogAndSearchNavigates() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-Settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
        let commander = CommanderController()
        _ = commander.view
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .appearance, defaults: defaults,
                                    updaterView: { NSTextField(labelWithString: "Update-Einstellungen") }, onClose: {})
        let window = try XCTUnwrap(dialog.window)
        let root = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 1180, height: 800), NSSize(width: 1020, height: 700), NSSize(width: 860, height: 560)] {
            window.setContentSize(size)
            for section in SettingsSection.allCases {
                dialog.show(section)
                root.superview?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(root.bounds.width, size.width, accuracy: 1, section.title)
                let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.frame.height, 50, section.title)
                XCTAssertEqual(document.frame.width, scroll.contentView.bounds.width, accuracy: 1, section.title)
                for control in descendants(document).compactMap({ $0 as? NSControl }) {
                    XCTAssertGreaterThan(control.frame.width, 0, "\(section.title): \(control)")
                    XCTAssertGreaterThan(control.frame.height, 0, "\(section.title): \(control)")
                }
                if let directory = ProcessInfo.processInfo.environment["PANEROOK_SETTINGS_SNAPSHOT_DIR"], size.width == 1180 {
                    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(section.rawValue + ".png"))
                    if section == .appearance || section == .general || section == .layout || section == .panels {
                        root.appearance = NSAppearance(named: .darkAqua)
                        root.displayIfNeeded()
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(section.rawValue + "-dark.png"))
                        root.appearance = nil
                    }
                }
            }
        }
        let search = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "Zeilenhöhe"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(dialog.selectedSection, .panels)
        search.stringValue = "kein Treffer"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Keine Einstellungen gefunden" })
        search.stringValue = ""
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(dialog.selectedSection, .panels)
    }

    func testThemeControlsPersistImmediatelyAndKeepBothSelections() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-Appearance-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
        var changes = 0
        let appearance = SettingsAppearanceView(defaults: defaults) {
            changes += 1
            ThemeManager.apply(defaults: defaults)
        }
        let buttons = descendants(appearance).compactMap { $0 as? NSButton }
        let dark = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.scheme.dark" })
        let ocean = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.theme.ocean" })
        dark.performClick(nil)
        ocean.performClick(nil)
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(defaults.integer(forKey: "appearance"), 2)
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "ocean")
        XCTAssertEqual(dark.state, .on)
        XCTAssertEqual(ocean.state, .on)
        XCTAssertEqual(buttons.filter { $0.state == .on }.count, 2)
        XCTAssertEqual(ThemeManager.theme, .ocean)
        XCTAssertEqual(ThemeManager.colorScheme, .dark)
    }

    func testGeneralSwitchPersistsAndDisablingHistoryClearsSavedCommands() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-General-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
        defaults.set(["ls -la"], forKey: "commandHistory")
        let commander = CommanderController()
        _ = commander.view
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .general, defaults: defaults, updaterView: { NSView() }, onClose: {})
        let root = try XCTUnwrap(dialog.window?.contentView)
        let history = try XCTUnwrap(descendants(root).compactMap { $0 as? SettingsToggle }.first { $0.accessibilityLabel() == "Befehlschronik speichern" })
        history.state = .off
        history.sendAction(history.action, to: history.target)
        XCTAssertEqual(defaults.object(forKey: "rememberCommands") as? Bool, false)
        XCTAssertNil(defaults.array(forKey: "commandHistory"))
        dialog.show(.appearance)
        dialog.show(.general)
        let rebuilt = try XCTUnwrap(descendants(root).compactMap { $0 as? SettingsToggle }.first { $0.accessibilityLabel() == "Befehlschronik speichern" })
        XCTAssertEqual(rebuilt.state, .off)
    }
    func testOpenSettingsSurfacesRedrawWithTheThemeWithoutRebuildingControls() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-SettingsTheme-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
        let commander = CommanderController()
        _ = commander.view
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        defaults.set(AppTheme.ocean.rawValue, forKey: "appTheme")
        defaults.set(AppColorScheme.dark.rawValue, forKey: "appearance")
        preferences.applyAppearance()
        let dialog = SettingsDialog(preferences: preferences, section: .general, defaults: defaults,
                                    updaterView: { NSView() }, onClose: {})
        let root = try XCTUnwrap(dialog.window?.contentView)
        root.superview?.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let surfaces = ([root] + descendants(root)).compactMap { $0 as? SettingsSurfaceView }
        let toggles = descendants(root).compactMap { $0 as? SettingsToggle }
        XCTAssertGreaterThanOrEqual(surfaces.count, 4)
        for surface in surfaces { surface.needsDisplay = false }
        for toggle in toggles { toggle.needsDisplay = false }
        defaults.set(AppTheme.ember.rawValue, forKey: "appTheme")
        preferences.applyAppearance()
        XCTAssertTrue(surfaces.allSatisfy(\.needsDisplay))
        XCTAssertTrue(toggles.allSatisfy(\.needsDisplay))
        let after = descendants(root).compactMap { $0 as? SettingsToggle }
        XCTAssertEqual(toggles.count, after.count)
        for (before, after) in zip(toggles, after) { XCTAssertTrue(before === after) }

        if let directory = ProcessInfo.processInfo.environment["PANEROOK_SETTINGS_SNAPSHOT_DIR"] {
            for theme in [AppTheme.ocean, .ember, .iris] {
                defaults.set(theme.rawValue, forKey: "appTheme")
                for scheme in [AppColorScheme.light, .dark] {
                    defaults.set(scheme.rawValue, forKey: "appearance")
                    preferences.applyAppearance()
                    root.appearance = scheme.appearance
                    root.displayIfNeeded()
                    let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("general-" + theme.rawValue + "-" + String(scheme.rawValue) + ".png"))
                }
            }
            root.appearance = nil
        }
    }

    func testConnectionTimeoutAcceptsCustomValuesAndClampsAtSupportedLimits() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-ConnectionSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController()
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .connections, defaults: defaults, updaterView: { NSView() }, onClose: {})
        let root = try XCTUnwrap(dialog.window?.contentView)
        let timeout = try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "settings.remoteTimeout" })
        for (text, expected) in [("17", 17), ("999", 300), ("0", 3), ("invalid", 20)] {
            timeout.stringValue = text
            dialog.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: timeout))
            XCTAssertEqual(defaults.integer(forKey: "remoteTimeout"), expected)
            XCTAssertEqual(timeout.integerValue, expected)
        }
    }

    func testShortcutCapturePersistsNewBindingAndRejectsDuplicates() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-KeyboardSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController()
        _ = commander.view
        let registry = CommandRegistry(defaults: defaults)
        registry.add(.file, "Kopieren", id: "copy", order: 0, function: 5, enabled: { true }) {}
        registry.add(.file, "Verschieben", id: "move", order: 1, function: 6, enabled: { true }) {}
        commander.commandRegistry = registry
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .keyboard, defaults: defaults, updaterView: { NSView() }, onClose: {})
        let root = try XCTUnwrap(dialog.window?.contentView)
        func captureButton(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == title })
        }
        func input() throws -> NSTextField {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Tastenkombination drücken …" })
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        try captureButton("Kopieren").performClick(nil)
        XCTAssertTrue(try input().performKeyEquivalent(with: event))
        XCTAssertEqual(registry.bindings["copy"]?.keyCode, 8)
        XCTAssertEqual(registry.bindings["copy"]?.modifiers, NSEvent.ModifierFlags.option.rawValue)
        try captureButton("Verschieben").performClick(nil)
        XCTAssertTrue(try input().performKeyEquivalent(with: event))
        XCTAssertEqual(registry.bindings["move"]?.keyCode, AppKeyBinding.function(6).keyCode)
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Bereits mit „Kopieren“ belegt") })
        dialog.show(.general)
        XCTAssertFalse(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Tastenkombination drücken …" })
    }

}
