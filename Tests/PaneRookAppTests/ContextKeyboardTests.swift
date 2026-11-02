import AppKit
import XCTest
@testable import PaneRookApp

final class ContextKeyboardTests: XCTestCase {
    private func event(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testContextCatalogIncludesActionsBeforeFeatureWindowsOpen() {
        let registry = CommandRegistry()
        registry.addContextDefinitions()
        let ids = Set(registry.customizableCommands.map(\.id))
        for id in ["remote.download", "remote.upload", "connections.new", "git.stage", "git.stash.pop",
                   "git.branch.merge", "git.diff.sideBySide", "tasks.cancel", "favorites.addCurrent",
                   "results.panelize", "network.connect", "table.pageDown", "dialog.cancel"] {
            XCTAssertTrue(ids.contains(id), id)
            XCTAssertFalse(registry[id]?.visibleInMenu ?? true, id)
        }
        XCTAssertEqual(ids.count, ContextCommands.definitions.count)
    }

    func testContextRemappingAndRemovalAreUsedAtDispatch() throws {
        let name = "ContextKeyboardTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let registry = CommandRegistry(defaults: defaults)
        registry.addContextDefinitions()
        let f5 = try event(96, AppKeyBinding.function(5).characters)
        XCTAssertEqual(ContextCommands.matching(f5, scope: .remote, defaults: defaults), "remote.download")
        XCTAssertNil(ContextCommands.matching(f5, scope: .git, defaults: defaults))
        try registry.setBinding(.physical(15, characters: "r", modifiers: [.command, .option]), for: "remote.download")
        XCTAssertNil(ContextCommands.matching(f5, scope: .remote, defaults: defaults))
        XCTAssertEqual(try ContextCommands.matching(event(15, "r", flags: [.command, .option]), scope: .remote, defaults: defaults), "remote.download")
        try registry.setBinding(nil, for: "remote.download")
        XCTAssertNil(try ContextCommands.matching(event(15, "r", flags: [.command, .option]), scope: .remote, defaults: defaults))
    }

    func testRecordingSuppressesEveryContextShortcut() throws {
        let previous = KeyboardCaptureState.isRecording
        defer { KeyboardCaptureState.isRecording = previous }
        KeyboardCaptureState.isRecording = true
        XCTAssertFalse(try ContextCommands.isCancellation(event(53, "\u{1b}")))
        XCTAssertNil(try ContextCommands.matching(event(36, "\r"), scope: .connections))
    }

    func testPlainTextDoesNotTriggerFeatureCommandsWhileEditing() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        let text = NSTextView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        XCTAssertFalse(try ContextCommands.canHandle(event(0, "a"), in: window))
        XCTAssertFalse(try ContextCommands.canHandle(event(36, "\r"), in: window))
        XCTAssertTrue(try ContextCommands.canHandle(event(0, "a", flags: .command), in: window))
        XCTAssertTrue(try ContextCommands.canHandle(event(96, AppKeyBinding.function(5).characters), in: window))
    }
}
