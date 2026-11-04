import AppKit
import XCTest

@testable import PaneRookApp

final class SettingsDialogTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    func testSettingsRemainModelessAndRestoreLastSectionAndWindowSize() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-modeless-settings-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController(defaults: defaults)
        commander.tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let parent = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                               styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentViewController = commander
        defer { parent.close() }
        let preferences = commander.preferences
        preferences.showSettings(section: .panels)
        let first = try XCTUnwrap(preferences.settingsDialog)
        let settings = try XCTUnwrap(first.window)
        XCTAssertNil(parent.attachedSheet)
        XCTAssertNil(settings.sheetParent)
        XCTAssertTrue(commander.canUseMenus, "The main window remains usable when it has focus")
        first.show(.keyboard)
        settings.setContentSize(NSSize(width: 900, height: 600))
        commander.activate(commander.right)
        settings.performClose(nil)
        XCTAssertNil(preferences.settingsDialog)
        XCTAssertFalse(settings.isVisible)
        XCTAssertTrue(commander.active === commander.right, "Closing settings must preserve the panel used in the meantime")
        preferences.showSettings()
        let second = try XCTUnwrap(preferences.settingsDialog)
        XCTAssertEqual(second.selectedSection, .keyboard)
        XCTAssertEqual(try XCTUnwrap(second.window?.contentView).bounds.width, 900, accuracy: 1)
        XCTAssertNil(parent.attachedSheet)
        second.window?.performClose(nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testSearchFindsSettingLabelsAcrossCategories() {
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("Zeilenhöhe") }, [.panels])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("Theme dunkel") }, [.appearance])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("F5") }, [.keyboard])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("VFS Timeout") }, [.connections])
        XCTAssertEqual(SettingsSection.allCases.filter { $0.matches("unbekannter Suchbegriff") }, [])
    }

    func testSearchAcceptsTypingAndClearsTheFilterWithItsCancelButton() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-SettingsSearch-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController()
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .general, defaults: defaults,
                                    updaterView: { NSView() }, onClose: {})
        let window = try XCTUnwrap(dialog.window)
        let root = try XCTUnwrap(window.contentView)
        root.superview?.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(descendants(root).compactMap { $0 as? NSSearchField }.first)
        XCTAssertTrue(search.isEditable)
        XCTAssertTrue(search.isSelectable)
        XCTAssertTrue(window.makeFirstResponder(search))
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        editor.insertText("Zeilenhöhe", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(search.stringValue, "Zeilenhöhe")
        XCTAssertEqual(dialog.selectedSection, .panels)
        XCTAssertTrue(window.firstResponder === editor)
        let navigation = descendants(root).compactMap { $0 as? SettingsNavigationButton }
        XCTAssertEqual(navigation.filter { !$0.isHidden }.map(\.title), ["Panels"])

        editor.insertText("unbekannter Suchbegriff", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(navigation.allSatisfy(\.isHidden))
        XCTAssertTrue(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Keine Einstellungen gefunden" })

        let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
        let cancel = try XCTUnwrap(cell.cancelButtonCell)
        cancel.performClick(search)
        XCTAssertEqual(search.stringValue, "")
        XCTAssertTrue(navigation.allSatisfy { !$0.isHidden })
        XCTAssertEqual(dialog.selectedSection, .panels)
        XCTAssertFalse(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Keine Einstellungen gefunden" })
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
        for style: NSScroller.Style in [.legacy, .overlay] {
            try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }.first).scrollerStyle = style
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

    func testKeyboardSettingsOpensTheSharedEditorAndPreservesConflictChecks() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-KeyboardSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); KeyboardCaptureState.isRecording = false }
        let commander = CommanderController()
        _ = commander.view
        let registry = CommandRegistry(defaults: defaults)
        registry.add(.file, "Kopieren", id: "copy", order: 0, function: 5, enabled: { true }) {}
        registry.add(.file, "Verschieben", id: "move", order: 1, function: 6, enabled: { true }) {}
        commander.commandRegistry = registry
        let preferences = PreferencesTools(owner: commander, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .keyboard, defaults: defaults, updaterView: { NSView() }, onClose: {})
        let parent = try XCTUnwrap(dialog.window)
        defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) } }
        let root = try XCTUnwrap(parent.contentView)
        let open = try XCTUnwrap(descendants(root).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "settings.keyboardMapping" })
        open.performClick(nil)
        let sheet = try XCTUnwrap(preferences.keyboardMapping?.window)
        let content = try XCTUnwrap(sheet.contentView)
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        let capture = try XCTUnwrap(descendants(content).compactMap { $0 as? KeyCapture }.first)
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        let copy = try XCTUnwrap(registry.customizableCommands.firstIndex { $0.id == "copy" })
        table.selectRowIndexes(IndexSet(integer: copy), byExtendingSelection: false)
        try button("Belegen …").performClick(nil)
        XCTAssertTrue(KeyboardCaptureState.isRecording)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertTrue(capture.performKeyEquivalent(with: event))
        try button("Speichern").performClick(nil)
        XCTAssertFalse(KeyboardCaptureState.isRecording)
        XCTAssertEqual(registry.bindings["copy"]?.keyCode, 8)
        let move = try XCTUnwrap(registry.customizableCommands.firstIndex { $0.id == "move" })
        table.selectRowIndexes(IndexSet(integer: move), byExtendingSelection: false)
        try button("Belegen …").performClick(nil)
        XCTAssertTrue(capture.performKeyEquivalent(with: event))
        XCTAssertFalse(try button("Speichern").isEnabled)
        XCTAssertEqual(registry.bindings["move"]?.keyCode, AppKeyBinding.function(6).keyCode)
        try button("Abbrechen").performClick(nil)
        XCTAssertFalse(KeyboardCaptureState.isRecording)
        XCTAssertTrue(preferences.keyboardMapping?.window === sheet)
        XCTAssertEqual(dialog.selectedSection, .keyboard)
        try button("Fertig").performClick(nil)
        XCTAssertNil(preferences.keyboardMapping)
    }

}
