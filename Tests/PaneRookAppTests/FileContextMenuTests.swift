import AppKit
import PaneRookCore
import PaneRookRemote
import XCTest
@testable import PaneRookApp

final class FileContextMenuTests: XCTestCase {
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
    }
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    func testSecondaryClickTargetsRowAndPreservesExistingMultiSelection() {
        _ = NSApplication.shared
        let source = Rows(), table = FileTable()
        table.dataSource = source
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.reloadData()
        var selected = IndexSet()
        table.makeContextMenu = { selected = table.selectedRowIndexes; return NSMenu() }
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        XCTAssertNotNil(table.prepareContextMenu(at: 2))
        XCTAssertEqual(selected, IndexSet([0, 2]))
        XCTAssertNotNil(table.prepareContextMenu(at: 1))
        XCTAssertEqual(selected, IndexSet(integer: 1))
        XCTAssertNil(table.prepareContextMenu(at: -1))
        XCTAssertTrue(table.selectedRowIndexes.isEmpty)
        table.isEnabled = false
        XCTAssertNil(table.prepareContextMenu(at: 1))
    }

    func testMenuRechecksCommandPolicyAndRejectsStaleContext() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-context-policy-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = CommandRegistry(defaults: defaults)
        var allowed = true, current = true, calls = 0
        let command = registry.add(.file, "Action", id: "action", order: 0,
                                   enabled: { allowed }) { calls += 1 }
        let menu = FileContextMenu(contextIsCurrent: { current })
        menu.add(command, title: "Action", binding: nil)
        let item = try XCTUnwrap(menu.items.first)
        menu.performCommand(item)
        XCTAssertEqual(calls, 1)
        allowed = false
        XCTAssertFalse(menu.validateMenuItem(item))
        menu.performCommand(item)
        allowed = true; current = false
        XCTAssertFalse(menu.validateMenuItem(item))
        menu.performCommand(item)
        XCTAssertEqual(calls, 1)
    }

    func testContextMenuActivatesClickedPanelAndUsesRemotePolicies() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-context-integration-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        try Data("file".utf8).write(to: directory.appendingPathComponent("file.txt"))
        defaults.set(directory.path, forKey: "leftDirectory")
        defaults.set(directory.path, forKey: "rightDirectory")
        let commander = CommanderController(defaults: defaults)
        commander.tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = commander
        defer { window.close() }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            commander.right.entries.contains { $0.name == "file.txt" }
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        commander.activate(commander.left)
        let row = try XCTUnwrap(commander.right.entries.firstIndex { $0.name == "file.txt" })
        let local = try XCTUnwrap(commander.right.table.prepareContextMenu(at: row) as? FileContextMenu)
        XCTAssertTrue(commander.active === commander.right)
        XCTAssertEqual(commander.right.selectedFiles.map(\.lastPathComponent), ["file.txt"])
        XCTAssertTrue(local.items.contains { $0.identifier?.rawValue == "trash" && $0.title == "In den Papierkorb" })
        let remote = RemoteBrowser(connection: try RemoteConnection(kind: .shell, host: "test.invalid", port: 22, user: "test"),
            peer: commander.left, tasks: commander.tasks, runner: { _, _ in Data() })
        remote.directory = "/remote"
        remote.allEntries = [RemoteEntry(name: "remote.txt", isDirectory: false, size: 10)]
        commander.right.showRemoteContent(remote)
        remote.rebuildListing()
        let remoteRow = try XCTUnwrap(remote.entries.firstIndex { $0.name == "remote.txt" })
        let remoteMenu = try XCTUnwrap(remote.table.prepareContextMenu(at: remoteRow) as? FileContextMenu)
        XCTAssertEqual(FileContextActions.paths(in: commander.right), ["/remote/remote.txt"])
        let delete = try XCTUnwrap(remoteMenu.items.first { $0.identifier?.rawValue == "trash" })
        XCTAssertEqual(delete.title, "Endgültig löschen …")
        XCTAssertTrue(remoteMenu.validateMenuItem(delete))
        let clipboard = try XCTUnwrap(remoteMenu.items.first { $0.identifier?.rawValue == "files.clipboard.copy" })
        XCTAssertFalse(remoteMenu.validateMenuItem(clipboard))
        remote.cancellation = RemoteCancellation()
        XCTAssertFalse(remoteMenu.validateMenuItem(delete), "A busy connection cannot start an action from an old menu")
        remote.cancellation = nil
        commander.activate(commander.left)
        XCTAssertFalse(remoteMenu.validateMenuItem(delete), "An old menu must not act on the newly active panel")
    }
}
