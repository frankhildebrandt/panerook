import AppKit
import PaneRookCore
import XCTest
@testable import PaneRookApp

final class FileOperationUndoTests: XCTestCase {
    private final class KeyWindow: NSWindow { override var isKeyWindow: Bool { true } }

    @MainActor func testNativeManagerAndCommandsRespectTextAndTerminalFocus() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookUndoUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let commander = CommanderController()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = commander
        defer { window.close() }
        commander.left.setMode(.listing)
        commander.activate(commander.left)
        let operations = commander.fileOperations
        try operations.journal.createDirectory(named: "folder", in: root)
        XCTAssertTrue(operations.canUndoFiles)
        XCTAssertTrue(commander.undoManager === operations.fileUndoManager)
        XCTAssertTrue(commander.commandRegistry["files.undo"]?.enabled() == true)
        XCTAssertTrue(operations.fileUndoManager.undoMenuItemTitle.contains("folder"))
        XCTAssertTrue(operations.fileUndoManager.undoMenuItemTitle.contains("Ordner anlegen"))
        let item = NSMenuItem(title: "", action: #selector(CommanderController.undo(_:)), keyEquivalent: "z")
        XCTAssertTrue(commander.validateMenuItem(item))
        XCTAssertEqual(item.title, operations.fileUndoManager.undoMenuItemTitle)

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        text.isEditable = true; text.allowsUndo = true
        commander.view.addSubview(text)
        window.makeFirstResponder(text)
        XCTAssertFalse(operations.canUndoFiles)
        XCTAssertFalse(text.undoManager === operations.fileUndoManager)
        text.insertText("Textänderung", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(text.undoManager?.canUndo == true)
        text.undoManager?.undo()
        XCTAssertEqual(text.string, "")
        XCTAssertFalse(commander.validateMenuItem(item))
        commander.undo(nil) // A responder-chain fall-through also cannot mutate files.
        XCTAssertFalse(operations.isRestoringFiles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder").path))
        commander.left.setMode(.terminal)
        XCTAssertFalse(operations.canUndoFiles)
        XCTAssertFalse(commander.commandRegistry["files.undo"]?.enabled() == true)
    }

    @MainActor func testUndoRunsInTaskQueueAndReleasesBusyState() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookUndoQueue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let commander = CommanderController()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = commander
        defer { window.close() }
        commander.left.setMode(.listing); commander.activate(commander.left)
        let operations = commander.fileOperations
        try operations.journal.createDirectory(named: "folder", in: root)
        operations.fileUndoManager.undo()
        XCTAssertTrue(operations.isRestoringFiles)
        XCTAssertTrue(commander.tasks.hasActiveTasks)
        XCTAssertFalse(operations.canUndoFiles)
        let deadline = Date().addingTimeInterval(5)
        while operations.isRestoringFiles && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(operations.isRestoringFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder").path))
        XCTAssertNotNil(operations.journal.nextRedo)
    }

    @MainActor func testNewCommandsDoNotChangeExistingUndoBindings() throws {
        _ = NSApplication.shared
        let commander = CommanderController()
        let registry = commander.commandRegistry
        XCTAssertEqual(registry.defaultsByID["editing.undo"]?.label, "⌘Z")
        XCTAssertEqual(registry.defaultsByID["editing.redo"]?.label, "⇧⌘Z")
        XCTAssertEqual(registry.defaultsByID["connections.undo"]?.label, "⌘Z")
        XCTAssertEqual(registry["connections.undo"]?.scope, .connections)
        XCTAssertNil(registry.defaultsByID["files.undo"])
        XCTAssertNil(registry.defaultsByID["files.redo"])
        XCTAssertNotNil(registry["files.history"])
    }
}
