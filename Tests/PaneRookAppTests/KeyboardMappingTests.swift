import AppKit
import XCTest
@testable import PaneRookApp

final class KeyboardMappingTests: XCTestCase {
    private func isolatedRegistry() throws -> (CommandRegistry, UserDefaults, String) {
        let name = "KeyboardMappingTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (CommandRegistry(defaults: defaults), defaults, name)
    }
    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testEveryActionCanBeMappedIncludingActionsWithNoDefault() throws {
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        var performed = 0
        registry.add(.options, "Configuration", id: "configuration", order: 0, enabled: { true }) { performed += 1 }
        registry.add(.command, "Refresh", id: "refresh", order: 1, key: "r", enabled: { true }) {}
        XCTAssertEqual(Set(registry.customizableCommands.map(\.id)), ["configuration", "refresh"])
        XCTAssertNil(registry.bindings["configuration"])
        let binding = AppKeyBinding.physical(8, characters: "c", modifiers: [.command, .option])
        try registry.setBinding(binding, for: "configuration")
        XCTAssertTrue(try XCTUnwrap(registry.matching(key(8, "c", flags: [.command, .option]))).perform())
        XCTAssertEqual(performed, 1)
        let relaunched = CommandRegistry(defaults: defaults)
        relaunched.add(.options, "Configuration", id: "configuration", order: 0, enabled: { true }) {}
        XCTAssertEqual(relaunched.bindings["configuration"], binding)
    }

    func testRemovingDefaultPersistsAndResetRestoresOnlySelectedAction() throws {
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        registry.add(.file, "Copy", id: "copy", order: 0, function: 5, enabled: { true }) {}
        registry.add(.file, "Move", id: "move", order: 1, function: 6, enabled: { true }) {}
        try registry.setBinding(.character("m", modifiers: [.control]), for: "move")
        try registry.setBinding(nil, for: "copy")
        XCTAssertNil(registry.bindings["copy"])
        XCTAssertNil(try registry.matching(key(96, AppKeyBinding.function(5).characters)))
        let reloaded = CommandRegistry(defaults: defaults)
        reloaded.add(.file, "Copy", id: "copy", order: 0, function: 5, enabled: { true }) {}
        XCTAssertNil(reloaded.bindings["copy"])
        registry.resetBinding(for: "copy")
        XCTAssertEqual(registry.bindings["copy"], .function(5))
        XCTAssertEqual(registry.bindings["move"]?.label, "⌃M")
        registry.resetBindings()
        XCTAssertEqual(registry.bindings["move"], .function(6))
    }

    func testNativeCharacterShortcutsDoNotAllConflictOnPlaceholderKeyCodeZero() throws {
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        registry.add(.command, "Refresh", id: "refresh", order: 0, key: "r", enabled: { true }) {}
        registry.add(.command, "Home", id: "home", order: 1, key: "h", enabled: { true }) {}
        registry.add(.command, "Unbound", id: "new", order: 2, enabled: { true }) {}
        XCTAssertNil(registry.conflicts(for: .character("x"), assigningTo: "new"))
        XCTAssertEqual(registry.conflicts(for: .physical(15, characters: "r", modifiers: .command), assigningTo: "new")?.id, "refresh")
        XCTAssertThrowsError(try registry.setBinding(.physical(15, characters: "r", modifiers: .command), for: "new"))
        XCTAssertNil(registry.bindings["new"])
        XCTAssertEqual(try registry.matching(key(15, "r", flags: .command))?.id, "refresh")
        XCTAssertEqual(try registry.matching(key(4, "h", flags: .command))?.id, "home")
    }

    func testLegacyPreferencesKeepFunctionOverridesAndNativeCharacterDefaults() throws {
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        let saved = #"{"copy":{"keyCode":8,"modifiers":524288,"characters":"c"},"refresh":{"keyCode":0,"modifiers":1048576,"characters":"r"}}"#
        defaults.set(Data(saved.utf8), forKey: "keyBindings")
        registry.add(.file, "Copy", id: "copy", order: 0, function: 5, enabled: { true }) {}
        registry.add(.command, "Refresh", id: "refresh", order: 1, key: "r", enabled: { true }) {}
        registry.add(.file, "New feature", id: "new", order: 2, function: 7, enabled: { true }) {}
        XCTAssertEqual(try registry.matching(key(8, "c", flags: .option))?.id, "copy")
        XCTAssertEqual(try registry.matching(key(15, "r", flags: .command))?.id, "refresh")
        XCTAssertEqual(registry.bindings["new"], .function(7))
        XCTAssertNil(try registry.matching(key(0, "a", flags: .command)))
    }

    func testConflictDetectionRespectsWindowContextsAndNativeTextEditing() throws {
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        registry.add(.command, "Main", id: "main", order: 0, key: "r", enabled: { true }) {}
        registry.add(.command, "Panel", id: "panel", order: 1, scope: .panel, enabled: { true }) {}
        registry.add(.command, "Remote", id: "remote", order: 2, scope: .remote, enabled: { true }) {}
        registry.add(.edit, "Copy text", id: "text", order: 3, key: "c", scope: .textEditing, enabled: { true }) {}
        XCTAssertEqual(registry.conflicts(for: .character("r"), assigningTo: "panel")?.id, "main")
        XCTAssertNil(registry.conflicts(for: .character("r"), assigningTo: "remote"))
        XCTAssertEqual(registry.conflicts(for: .character("c"), assigningTo: "remote")?.id, "text")
        try registry.setBinding(.character("r"), for: "remote")
        XCTAssertEqual(try registry.matching(key(15, "r", flags: .command), scope: .remote)?.id, "remote")
    }

    func testRecordedAKeyIsPhysicalAndShiftCapsLockAndFnAreHandled() throws {
        let binding = try XCTUnwrap(AppKeyBinding(event: key(0, "A", flags: [.command, .shift, .capsLock, .function])))
        XCTAssertTrue(try binding.matches(key(0, "a", flags: [.command, .shift])))
        XCTAssertFalse(try binding.matches(key(0, "a", flags: .command)))
        XCTAssertFalse(try binding.matches(key(12, "a", flags: [.command, .shift])))
        XCTAssertEqual(binding.label, "⇧⌘A")
        XCTAssertFalse(AppKeyBinding.function(5).isTextInput)
        XCTAssertTrue(AppKeyBinding.physical(49, characters: " ").isTextInput)
        XCTAssertEqual(AppKeyBinding.physical(53, characters: "\u{1b}").label, "Esc")
        XCTAssertEqual(AppKeyBinding.physical(76, characters: "\u{3}").label, "⌤")
    }
    func testShiftedPunctuationConflictsWithCharacterBasedMenuDefaults() throws {
        let question = AppKeyBinding.physical(44, characters: "?", modifiers: [.command, .shift])
        XCTAssertTrue(question.conflicts(with: .character("?")))
        var greaterThan = AppKeyBinding.physical(47, characters: ">", modifiers: [.command, .shift])
        greaterThan.baseCharacters = "."
        XCTAssertTrue(greaterThan.conflicts(with: .character(".", modifiers: [.command, .shift])))
        XCTAssertFalse(greaterThan.conflicts(with: .character(".")))
    }

    func testMenuEquivalentsRefreshWhenMappingChangesOrIsRemoved() throws {
        _ = NSApplication.shared
        let (_, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        let commander = CommanderController()
        commander.commandRegistry = commander.makeCommandRegistry(defaults: defaults)
        let oldMenu = NSApp.mainMenu
        let oldHelp = NSApp.helpMenu
        defer { NSApp.mainMenu = oldMenu; NSApp.helpMenu = oldHelp }
        let menus = CommanderMenus(commander: commander)
        menus.install()
        let command = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Befehl" }?.submenu)
        let refresh = try XCTUnwrap(command.items.first { $0.identifier?.rawValue == "panels.refresh" })
        XCTAssertEqual(refresh.keyEquivalent, "r")
        try commander.commandRegistry.setBinding(.physical(15, characters: "r", modifiers: [.command, .option]), for: "panels.refresh")
        commander.hotkeysChanged()
        XCTAssertEqual(refresh.keyEquivalentModifierMask, [.command, .option])
        try commander.commandRegistry.setBinding(nil, for: "panels.refresh")
        commander.hotkeysChanged()
        XCTAssertEqual(refresh.keyEquivalent, "")
        commander.commandRegistry.resetBinding(for: "panels.refresh")
        commander.hotkeysChanged()
        XCTAssertEqual(refresh.keyEquivalent, "r")
        let edit = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Bearbeiten" }?.submenu)
        let copy = try XCTUnwrap(edit.items.first { $0.identifier?.rawValue == "editing.copy" })
        XCTAssertNil(copy.target, "Native editing must use AppKit's responder chain")
        try commander.commandRegistry.setBinding(nil, for: "editing.copy")
        commander.hotkeysChanged()
        XCTAssertEqual(copy.keyEquivalent, "")
    }

    func testCancellationAndNativeAppActionsCannotBeShadowedByContextMappings() throws {
        _ = NSApplication.shared
        let (_, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        let commander = CommanderController()
        let registry = commander.makeCommandRegistry(defaults: defaults)
        XCTAssertEqual(registry.conflicts(for: .physical(53, characters: "\u{1b}"), assigningTo: "git.stage")?.id, "dialog.cancel")
        XCTAssertEqual(registry.conflicts(for: .character("q"), assigningTo: "git.stage")?.id, "app.quit")
        XCTAssertEqual(registry.conflicts(for: .character("r"), assigningTo: "favorites.addCurrent")?.id, "panels.refresh")
        XCTAssertNil(registry.conflicts(for: .function(10), assigningTo: "remote.close"))
    }

    func testSettingsEditorRecordsAndRemovesAnUnassignedAction() throws {
        _ = NSApplication.shared
        let (_, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name); KeyboardCaptureState.isRecording = false }
        let commander = CommanderController()
        let registry = commander.makeCommandRegistry(defaults: defaults)
        var updates = 0
        let editor = KeyboardMappingController(registry: registry, didChange: { updates += 1 }, didClose: {})
        let content = try XCTUnwrap(editor.window?.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        let search = try XCTUnwrap(views.compactMap { $0 as? NSSearchField }.first)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let capture = try XCTUnwrap(views.compactMap { $0 as? KeyCapture }.first)
        func button(_ title: String) throws -> NSButton {
            try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == title })
        }
        XCTAssertEqual(table.numberOfRows, registry.commands.count)
        search.stringValue = "preferences.save"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        XCTAssertEqual(table.numberOfRows, 1)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try button("Belegen …").performClick(nil)
        XCTAssertTrue(KeyboardCaptureState.isRecording)
        capture.keyDown(with: try key(35, "p", flags: [.command, .control, .option]))
        XCTAssertTrue(try button("Speichern").isEnabled)
        try button("Speichern").performClick(nil)
        XCTAssertFalse(KeyboardCaptureState.isRecording)
        XCTAssertEqual(registry.bindings["preferences.save"]?.keyCode, 35)
        XCTAssertEqual(updates, 1)
        try button("Belegung entfernen").performClick(nil)
        XCTAssertNil(registry.bindings["preferences.save"])
        XCTAssertEqual(updates, 2)
    }

    func testRemappedListNavigationSuppressesTheOldNativeKey() throws {
        _ = NSApplication.shared
        let (registry, defaults, name) = try isolatedRegistry()
        defer { defaults.removePersistentDomain(forName: name) }
        registry.addContextDefinitions()
        final class Rows: NSObject, NSTableViewDataSource {
            func numberOfRows(in tableView: NSTableView) -> Int { 10 }
        }
        let rows = Rows()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.dataSource = rows
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try registry.setBinding(.physical(14, characters: "e", modifiers: .control), for: "table.end")
        XCTAssertTrue(try table.handleListNavigation(key(119, functionKey(NSEndFunctionKey)), defaults: defaults))
        XCTAssertEqual(table.selectedRow, 4)
        XCTAssertTrue(try table.handleListNavigation(key(14, "e", flags: .control), defaults: defaults))
        XCTAssertEqual(table.selectedRow, 9)
        try registry.setBinding(nil, for: "table.end")
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        XCTAssertTrue(try table.handleListNavigation(key(119, functionKey(NSEndFunctionKey)), defaults: defaults))
        XCTAssertEqual(table.selectedRow, 4)
    }

}
