import AppKit
import XCTest

@testable import PaneRookApp

final class CommandRegistryTests: XCTestCase {
    func testMenuDockAndKeyboardUseSameActionAndAvailability() throws {
        let defaults = UserDefaults(suiteName: "PaneRookCommands-\(UUID())")!
        let registry = CommandRegistry(defaults: defaults)
        var available = false
        var invocations = 0
        registry.add(
            .file, "Copy", id: "copy", order: 0, function: 5, dockTitle: { "Copy" },
            enabled: { available }
        ) { invocations += 1 }
        let alias = registry.alias(
            "copy", in: .command, title: "Copy shortcut", id: "copy.shortcut", order: 0, group: 0, key: "c")
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: AppKeyBinding.function(5).characters,
                charactersIgnoringModifiers: AppKeyBinding.function(5).characters, isARepeat: false, keyCode: 96))
        let menu = try XCTUnwrap(registry.commands(in: .file).first)
        XCTAssertTrue(menu === registry.dockCommands.first)
        XCTAssertTrue(menu === registry.matching(event))
        XCTAssertFalse(registry.matching(event)!.perform())
        XCTAssertFalse(alias.perform())
        XCTAssertEqual(invocations, 0)
        available = true
        XCTAssertTrue(menu.perform())
        XCTAssertTrue(registry.dockCommands[0].perform())
        XCTAssertTrue(registry.matching(event)!.perform())
        XCTAssertTrue(alias.perform())
        XCTAssertEqual(invocations, 4)
    }

    func testSavedFunctionBindingSurvivesAndNewActionsReceiveDefaults() throws {
        let suite = "PaneRookCommands-\(UUID())"
        let isolated = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { isolated.removePersistentDomain(forName: suite) }
        let remapped = AppKeyBinding(keyCode: 8, modifiers: NSEvent.ModifierFlags.option.rawValue, characters: "c")
        isolated.set(try JSONEncoder().encode(["copy": remapped]), forKey: "keyBindings")
        let registry = CommandRegistry(defaults: isolated)
        registry.add(.file, "Copy", id: "copy", order: 0, function: 5, enabled: { true }) {}
        registry.add(.file, "Move", id: "move", order: 1, function: 6, enabled: { true }) {}
        XCTAssertEqual(registry.bindings["copy"]?.keyCode, 8)
        XCTAssertEqual(registry.bindings["copy"]?.modifiers, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(registry.bindings["move"]?.keyCode, 97)
        isolated.set(Data("bad config".utf8), forKey: "keyBindings")
        XCTAssertEqual(registry.bindings["copy"]?.keyCode, 96)
    }

    func testCompositionPreservesExistingFunctionActionsAndMenus() {
        _ = NSApplication.shared
        let commander = CommanderController()
        let registry = commander.commandRegistry
        XCTAssertEqual(Set(registry.customizableCommands.map(\.id)), Set(registry.commands.map(\.id)))
        for id in ["help", "userMenu", "preview", "edit", "copy", "move", "mkdir", "trash", "menu", "exit"] {
            XCTAssertNotNil(registry[id], "Persisted command IDs must remain stable: \(id)")
        }
        for id in ["preferences.keyBindings", "preferences.layout", "preferences.appearance", "remote.preferences"] {
            XCTAssertNotNil(registry[id], "Settings pages must retain persisted shortcut IDs: \(id)")
        }
        XCTAssertEqual(registry.defaultsByID["preferences.configuration"]?.label, "⌘,")
        XCTAssertNil(registry.defaultsByID["preferences.keyBindings"])
        XCTAssertEqual(registry.dockCommands.map(\.id), ["preview", "edit", "copy", "move", "mkdir", "trash"])
        XCTAssertEqual(registry.commands(in: .file).count, 21)
        XCTAssertEqual(registry.commands(in: .command).count, 31)
        XCTAssertNotNil(registry["git.workspace"])
        XCTAssertNotNil(registry["git.initialize"])
        XCTAssertEqual(registry.commands(in: .options).count, 3)
        XCTAssertEqual(registry.commands(in: .left).count, registry.commands(in: .right).count)
        XCTAssertEqual(Set(registry.commands.map(\.id)).count, registry.commands.count)
    }

    func testCatalogDoesNotKeepCoordinatorAlive() {
        _ = NSApplication.shared
        weak var released: CommanderController?
        autoreleasepool {
            let commander = CommanderController()
            released = commander
            _ = commander.commandRegistry
        }
        XCTAssertNil(released)
    }
    func testAppViewAndMenuAssemblyWithoutShowingAWindow() {
        _ = NSApplication.shared
        let commander = CommanderController()
        let previousMenu = NSApp.mainMenu
        let previousHelp = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.helpMenu = previousHelp
        }
        _ = commander.view
        let menus = CommanderMenus(commander: commander)
        menus.install()
        XCTAssertEqual(
            NSApp.mainMenu?.items.map(\.title),
            ["PaneRook", "Links", "Datei", "Befehl", "Optionen", "Rechts", "Bearbeiten", "Hilfe"])
        XCTAssertEqual(
            NSApp.mainMenu?.items.first { $0.title == "Datei" }?.submenu?.items.filter { !$0.isSeparatorItem }.count, 21
        )
    }

}
