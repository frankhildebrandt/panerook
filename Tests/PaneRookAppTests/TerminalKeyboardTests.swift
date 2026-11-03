import AppKit
import XCTest
@testable import PaneRookApp

final class TerminalKeyboardTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private final class KeyRecorder: NSView {
        var received: [UInt16] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
    }

    private final class TerminalStub: NSViewController, TerminalPanelContent {
        let recorder = KeyRecorder()
        var currentDirectory: URL?
        var onActivate: (() -> Void)?
        var onDirectoryChanged: ((URL) -> Void)?
        var onClose: (() -> Void)?
        var isRunning = false
        var viewController: NSViewController { self }
        var hasKeyboardFocus: Bool { view.window?.firstResponder === recorder }
        override func loadView() { view = recorder }
        func start(directory: URL) { currentDirectory = directory; isRunning = true }
        func stop() { isRunning = false }
        func focus() { view.window?.makeFirstResponder(recorder) }
        func setVisible(_ visible: Bool) { view.isHidden = !visible }
    }

    private func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @MainActor func testTerminalPaneSwitchHasADistinctCustomizableShortcut() throws {
        _ = NSApplication.shared
        let suite = "TerminalKeyboardTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController()
        let registry = commander.makeCommandRegistry(defaults: defaults)
        let command = try XCTUnwrap(registry["panels.switch.terminal"])
        XCTAssertTrue(command.visibleInMenu)
        XCTAssertEqual(command.scope, .application)
        XCTAssertEqual(try registry.matching(key(48, "\t", flags: [.command, .option]))?.id, command.id)
        XCTAssertNil(try registry.matching(key(48, "\t")))
        XCTAssertEqual(try registry.matching(key(48, "\t"), scope: .panel)?.id, "panels.switch")
        let changed = AppKeyBinding.physical(48, characters: "\t", modifiers: [.control, .shift])
        try registry.setBinding(changed, for: command.id)
        XCTAssertEqual(try registry.matching(key(48, "\t", flags: [.control, .shift]))?.id, command.id)
        XCTAssertNil(try registry.matching(key(48, "\t", flags: [.command, .option])))
    }

    @MainActor func testTerminalModeKeepsExistingPanelModeIdentifiers() throws {
        _ = NSApplication.shared
        let commander = CommanderController()
        let registry = commander.makeCommandRegistry()
        for side in ["left", "right"] {
            XCTAssertEqual(registry["\(side).mode.0"]?.title, "Dateiliste")
            XCTAssertEqual(registry["\(side).mode.5"]?.title, "Git-Diff und Verlauf")
            XCTAssertEqual(registry["\(side).mode.6"]?.title, "Ghostty-Terminal")
        }
    }

    @MainActor func testShellKeysBypassFileCommandsAndCustomControlShortcuts() throws {
        _ = NSApplication.shared
        let suite = "TerminalKeyboardRoutingTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let commander = CommanderController()
        commander.commandRegistry = commander.makeCommandRegistry(defaults: defaults)
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = commander
        defer { window.close() }

        let terminal = TerminalStub()
        let pane = PaneController(label: "Terminal", directory: FileManager.default.homeDirectoryForCurrentUser,
            terminalContent: terminal)
        commander.addChild(pane)
        pane.view.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        commander.view.addSubview(pane.view)
        pane.setMode(.terminal)
        commander.activate(pane)
        XCTAssertTrue(pane.hasTerminalKeyboardFocus)

        // A user remapping must not replace Ctrl-C inside the shell.
        try commander.commandRegistry.setBinding(.physical(8, characters: "c", modifiers: .control), for: "panels.refresh")
        func terminalEvent(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        let shellKeys: [(UInt16, String, NSEvent.ModifierFlags)] = [
            (48, "\t", []), (48, "\t", .option), (31, "o", .control),
            (8, "c", .control), (2, "d", .control), (109, AppKeyBinding.function(10).characters, [])
        ]
        for (code, text, flags) in shellKeys {
            XCTAssertTrue(try commander.handleGlobalKey(terminalEvent(code, text, flags)))
            XCTAssertEqual(commander.active.mode, .terminal)
            XCTAssertFalse(commander.panelsHidden)
        }
        XCTAssertEqual(terminal.recorder.received, shellKeys.map { $0.0 })
        XCTAssertTrue(try commander.handleGlobalKey(terminalEvent(48, "\t", [.command, .option])))
        XCTAssertTrue(commander.active === commander.left)
        XCTAssertEqual(terminal.recorder.received.count, shellKeys.count)
        XCTAssertFalse(window.isVisible)
    }
}
