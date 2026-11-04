import AppKit
import PaneRookCore
import XCTest
@testable import PaneRookApp

final class NativeFileExchangeTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    private final class DragInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = .copy
        var draggingLocation = NSPoint.zero
        var draggedImageLocation = NSPoint.zero
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }
    private final class Host: NativeFileExchangeHost, FileOperationsHost {
        var activePane: any PanelAccess
        let otherPane: any PanelAccess
        let presentationWindow: NSWindow?
        var canUseMenus = true
        var canUseSelection: Bool { !activePane.selectedFiles.isEmpty }
        var canUseLocalDirectory: Bool { true }
        var canUseNativeDirectory: Bool { true }
        var errors: [String] = []
        var refreshed = 0
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        lazy var operations = OperationRunner(tasks: tasks, refresh: {})
        lazy var fileOperations = FileOperations(owner: self)
        init(source: any PanelAccess, destination: any PanelAccess, window: NSWindow) {
            activePane = source; otherPane = destination; presentationWindow = window
        }
        func activate(_ pane: any PanelAccess) { activePane = pane; pane.focus() }
        func refreshAfterTask() { refreshed += 1 }
        func showError(_ error: Error, detail: String) { errors.append(error.localizedDescription) }
    }
    private var root: URL!
    private var source: URL!
    private var target: URL!
    private var alternate: URL!
    private var urls: [URL] = []
    private var clipboard: NSPasteboard!
    private var windows: [NSWindow] = []
    private var existingWindows = Set<ObjectIdentifier>()

    override func setUpWithError() throws {
        _ = NSApplication.shared
        existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PaneRook-exchange-" + UUID().uuidString)
        source = root.appendingPathComponent("Quelle ü", isDirectory: true)
        target = root.appendingPathComponent("Ziel", isDirectory: true)
        alternate = root.appendingPathComponent("anderer Ordner", isDirectory: true)
        for directory in [source!, target!, alternate!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        urls = [source.appendingPathComponent("Grüße #100% ? [x].txt"), source.appendingPathComponent("日本語\nzweite Zeile.txt")]
        for (index, url) in urls.enumerated() { try Data("Inhalt \(index)".utf8).write(to: url) }
        clipboard = try XCTUnwrap(NSPasteboard.withUniqueName(), "Native pasteboard service must be reachable for AppKit exchange tests")
    }
    override func tearDownWithError() throws {
        for window in windows { window.close() }
        windows = []
        // Close only windows created by this test, including independent task details.
        for window in NSApp.windows where !existingWindows.contains(ObjectIdentifier(window)) { window.close() }
        clipboard?.releaseGlobally()
        try FileManager.default.removeItem(at: root)
    }
    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func fixture() throws -> (PaneController, PaneController, Host, NativeFileExchange) {
        let left = PaneController(label: "Quelle", directory: source, capacityReader: { _ in nil })
        let right = PaneController(label: "Ziel", directory: target, capacityReader: { _ in nil })
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        let view = NSView(frame: window.contentView!.bounds)
        window.contentView = view
        left.view.frame = NSRect(x: 0, y: 0, width: 500, height: 600)
        right.view.frame = NSRect(x: 500, y: 0, width: 500, height: 600)
        view.addSubview(left.view); view.addSubview(right.view)
        eventually { left.canExportNativeFiles && right.fileExchangeDirectory == self.target }
        left.table.selectRowIndexes(IndexSet(left.entries.indices.filter { !left.entries[$0].isParent }), byExtendingSelection: false)
        let host = Host(source: left, destination: right, window: window)
        let exchange = NativeFileExchange(owner: host, pasteboard: clipboard)
        left.installFileExchange(exchange); right.installFileExchange(exchange)
        left.focus()
        return (left, right, host, exchange)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func confirmSheet(on window: NSWindow, title: String) throws {
        let sheet = try XCTUnwrap(window.attachedSheet)
        let button = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }.first { $0.title == title })
        button.performClick(nil)
    }

    func testPasteboardRoundTripPreservesMultipleUnicodeAndSpecialPaths() throws {
        XCTAssertTrue(clipboard.writeObjects(urls.map { $0 as NSURL }))
        XCTAssertEqual(try NativeFileURLs.read(from: clipboard), urls)
        let plan = try NativeFileURLs.plan(sources: NativeFileURLs.read(from: clipboard), destination: target, kind: .copy)
        try plan.execute()
        for url in urls {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(url.lastPathComponent)), try Data(contentsOf: url))
        }
    }

    func testRejectsTextMixedPayloadsRemoteURLsAndVirtualArchiveMembers() throws {
        clipboard.setString(source.path, forType: .string)
        XCTAssertThrowsError(try NativeFileURLs.read(from: clipboard))
        clipboard.clearContents()
        let file = NSPasteboardItem(); file.setString(urls[0].absoluteString, forType: .fileURL)
        let text = NSPasteboardItem(); text.setString("not a file", forType: .string)
        clipboard.writeObjects([file, text])
        XCTAssertThrowsError(try NativeFileURLs.read(from: clipboard))
        for value in ["sftp://host/a", "file://other-host/a", "https://host/a"] {
            XCTAssertThrowsError(try NativeFileURLs.validate([XCTUnwrap(URL(string: value))]))
        }
        let archive = root.appendingPathComponent("archive.zip")
        try Data().write(to: archive)
        XCTAssertNoThrow(try NativeFileURLs.validate([archive]), "The actual archive file remains transferable")
        XCTAssertThrowsError(try NativeFileURLs.validate([archive.appendingPathComponent("virtual.txt")]))
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: urls, destination: archive, kind: .copy))
    }

    func testRejectsSameLocationRecursiveSymlinkCollisionAndDuplicateNames() throws {
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: urls, destination: source, kind: .move))
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: [source], destination: source, kind: .copy))
        let child = source.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: [source], destination: child, kind: .move))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: [source], destination: alias, kind: .copy))
        try Data().write(to: target.appendingPathComponent(urls[0].lastPathComponent))
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: urls, destination: target, kind: .copy))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(urls[1].lastPathComponent).path))
        let duplicate = alternate.appendingPathComponent(urls[1].lastPathComponent)
        try Data().write(to: duplicate)
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: [urls[1], duplicate], destination: target, kind: .copy))
        XCTAssertThrowsError(try NativeFileURLs.plan(sources: [root.appendingPathComponent("missing")], destination: target, kind: .copy))
    }

    func testNativeDragOperationUsesModifiersAndSourceMask() {
        let mask: NSDragOperation = [.copy, .move]
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: mask, modifiers: []), .move)
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: mask, modifiers: .option), .copy)
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: mask, modifiers: .command), .move)
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: .copy, modifiers: []), .copy)
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: .copy, modifiers: .command), [])
        XCTAssertEqual(NativeFileURLs.dragOperation(sources: urls, destination: target, allowed: mask, modifiers: [.command, .option]), [])
    }

    @MainActor func testTableExportsOnlyRealRowsAndResolvesFolderAndBackgroundTargets() throws {
        let folder = target.appendingPathComponent("Unterordner")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data().write(to: target.appendingPathComponent("regular.txt"))
        let (left, right, host, exchange) = try fixture()
        _ = host; _ = exchange
        XCTAssertTrue(left.table.registeredDraggedTypes.contains(.fileURL))
        let parent = try XCTUnwrap(left.entries.firstIndex { $0.isParent })
        XCTAssertNil(left.tableView(left.table, pasteboardWriterForRow: parent))
        for row in left.entries.indices where !left.entries[row].isParent {
            XCTAssertEqual(left.tableView(left.table, pasteboardWriterForRow: row) as? NSURL, left.entries[row].url as NSURL)
        }
        let directoryRow = try XCTUnwrap(right.entries.firstIndex { $0.url.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path })
        let fileRow = try XCTUnwrap(right.entries.firstIndex { $0.name == "regular.txt" })
        XCTAssertEqual(right.fileDropDestination(row: directoryRow, operation: .on)?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertNil(right.fileDropDestination(row: fileRow, operation: .on))
        XCTAssertEqual(right.fileDropDestination(row: fileRow, operation: .above), target)
        XCTAssertEqual(right.fileDropDestination(row: -1, operation: .on), target)
        XCTAssertNil(right.fileDropDestination(row: 999, operation: .on))
        XCTAssertEqual(exchange.validateDrop(sources: urls, destination: source, pane: left, allowed: [.copy, .move], modifiers: []), [])
        left.navigate(to: alternate)
        XCTAssertFalse(left.canExportNativeFiles, "An in-flight navigation may not export stale rows")
        XCTAssertNil(left.fileDropDestination(row: -1, operation: .on))
        eventually { left.directory == self.alternate && left.canExportNativeFiles }
        left.panelize(urls)
        XCTAssertTrue(left.canExportNativeFiles)
        XCTAssertNil(left.fileExchangeDirectory, "Search-result backgrounds have no unambiguous target")
        left.setMode(.info)
        XCTAssertFalse(left.canExportNativeFiles)
    }

    @MainActor func testClipboardCopyAndPasteCaptureSourcesAndTargetBeforeContextChanges() throws {
        let (left, right, host, exchange) = try fixture()
        XCTAssertTrue(exchange.canCopy(from: left))
        left.table.copy(nil)
        XCTAssertEqual(Set(try NativeFileURLs.read(from: clipboard).map { $0.resolvingSymlinksInPath().path }),
                       Set(urls.map { $0.resolvingSymlinksInPath().path }))
        // Selection and active pane changes after Cmd-C cannot replace captured file URLs.
        left.table.deselectAll(nil)
        host.activate(right)
        XCTAssertTrue(exchange.canPaste(into: right))
        right.table.paste(nil)
        let window = try XCTUnwrap(host.presentationWindow)
        XCTAssertNotNil(window.attachedSheet)
        right.navigate(to: alternate)
        clipboard.clearContents(); clipboard.setString("New clipboard contents", forType: .string)
        host.activePane = left
        try confirmSheet(on: window, title: "Kopieren")
        eventually { host.refreshed == 1 }
        XCTAssertTrue(host.errors.isEmpty)
        for url in urls {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(url.lastPathComponent)), try Data(contentsOf: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: alternate.appendingPathComponent(url.lastPathComponent).path))
        }
        XCTAssertTrue(clipboard.string(forType: .string) == "New clipboard contents")
    }

    @MainActor func testDropUsesSharedConfirmationAndQueueWithExactMultiDirectorySources() throws {
        let (left, right, host, exchange) = try fixture()
        let extra = alternate.appendingPathComponent("extra ü.txt")
        try Data("extra".utf8).write(to: extra)
        let captured = [urls[0], extra]
        XCTAssertTrue(exchange.acceptDrop(sources: captured, destination: target, pane: right, operation: .move))
        let window = try XCTUnwrap(host.presentationWindow)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path), "Drop acceptance alone does not mutate files")
        host.activePane = left
        try confirmSheet(on: window, title: "Verschieben")
        eventually { host.refreshed == 1 }
        for url in captured {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(url.lastPathComponent).path))
        }
        XCTAssertEqual(host.fileOperations.journal.nextUndo?.title, "Verschieben")
        let inverse = try XCTUnwrap(host.fileOperations.journal.nextUndo)
        try host.fileOperations.journal.undo(expectedID: inverse.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[1].path), "Unselected files are never moved")
    }

    @MainActor func testTableDropDelegateCapturesHoveredFolderAndUsesTheSharedQueue() throws {
        let folder = target.appendingPathComponent("Drop-Ziel ü", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let (left, right, host, exchange) = try fixture()
        _ = exchange
        clipboard.writeObjects(urls.map { $0 as NSURL })
        let info = DragInfo(pasteboard: clipboard)
        info.draggingDestinationWindow = host.presentationWindow
        let row = try XCTUnwrap(right.entries.firstIndex { $0.name == "Drop-Ziel ü" })
        XCTAssertEqual(right.tableView(right.table, validateDrop: info, proposedRow: row, proposedDropOperation: .on), .copy)
        XCTAssertNil(host.presentationWindow?.attachedSheet, "Hover validation never presents a dialog")
        XCTAssertTrue(right.tableView(right.table, acceptDrop: info, row: row, dropOperation: .on))
        right.navigate(to: alternate)
        host.activePane = left
        try confirmSheet(on: XCTUnwrap(host.presentationWindow), title: "Kopieren")
        eventually { host.refreshed == 1 }
        for url in urls {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(url.lastPathComponent)), try Data(contentsOf: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(url.lastPathComponent).path))
        }
    }

    @MainActor func testCancelledPasteAndInvalidDropDoNotMutateOrConsumeClipboard() throws {
        let (_, right, host, exchange) = try fixture()
        clipboard.writeObjects(urls.map { $0 as NSURL })
        let revision = clipboard.changeCount
        host.activate(right)
        exchange.paste(into: right, kind: .move)
        let window = try XCTUnwrap(host.presentationWindow)
        try confirmSheet(on: window, title: "Abbrechen")
        eventually { window.attachedSheet == nil }
        XCTAssertEqual(clipboard.changeCount, revision)
        XCTAssertEqual(host.refreshed, 0)
        XCTAssertFalse(exchange.acceptDrop(sources: urls, destination: source, pane: right, operation: .move))
        XCTAssertFalse(exchange.acceptDrop(sources: urls, destination: target.appendingPathComponent("missing"), pane: right, operation: .copy))
        XCTAssertEqual(host.errors.count, 2)
        XCTAssertNil(window.attachedSheet)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    @MainActor func testTextFieldsSearchAndOtherViewsNeverRunFileClipboardCommands() throws {
        let (left, right, host, exchange) = try fixture()
        clipboard.writeObjects(urls.map { $0 as NSURL })
        let window = try XCTUnwrap(host.presentationWindow)
        let revision = clipboard.changeCount
        for field in [left.pathField, NSSearchField(frame: .zero), NSTextField(frame: .zero)] {
            if field.superview == nil { window.contentView?.addSubview(field) }
            field.stringValue = "Text bleibt Text"
            window.makeFirstResponder(field)
            XCTAssertTrue(window.firstResponder is NSTextView)
            XCTAssertFalse(exchange.canCopy(from: left))
            XCTAssertFalse(exchange.canPaste(into: left))
            exchange.copy(from: left); exchange.paste(into: left, kind: .move)
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(clipboard.changeCount, revision)
        }
        right.focus()
        XCTAssertFalse(exchange.canCopy(from: left), "Hidden/stale source selection cannot hijack the other responder")
        XCTAssertTrue(exchange.canPaste(into: right))
        host.canUseMenus = false
        XCTAssertFalse(exchange.canPaste(into: right))
    }

    @MainActor func testSharedTransferConfirmationPreservesRenameJournalTitle() throws {
        let (left, _, host, exchange) = try fixture()
        _ = exchange
        let window = try XCTUnwrap(host.presentationWindow)
        let original = try XCTUnwrap(urls.first)
        let renamed = source.appendingPathComponent("neuer Name.txt")
        host.fileOperations.confirmTransfer(sources: [original], sourceDirectory: source,
            destination: source, kind: .move, rename: true, focusPane: left, window: window)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let destination = try XCTUnwrap(descendants(try XCTUnwrap(sheet.contentView))
            .compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Zielpfad" })
        destination.stringValue = renamed.path
        try confirmSheet(on: window, title: "Verschieben")
        eventually { host.refreshed == 1 }
        XCTAssertEqual(host.fileOperations.journal.nextUndo?.title, "Umbenennen")
        XCTAssertEqual(try Data(contentsOf: renamed), Data("Inhalt 0".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    @MainActor func testRegistryPreservesNativeEditingIDsAndScopesMoveToPanels() throws {
        let (_, _, host, exchange) = try fixture()
        _ = host
        let name = "NativeExchangeCommands-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let commander = CommanderController()
        let registry = commander.makeCommandRegistry(defaults: defaults)
        XCTAssertEqual(registry["editing.copy"]?.scope, .textEditing)
        XCTAssertEqual(registry["editing.paste"]?.scope, .textEditing)
        XCTAssertEqual(registry.bindings["editing.copy"], .character("c", modifiers: .command))
        XCTAssertEqual(registry.bindings["editing.paste"], .character("v", modifiers: .command))
        XCTAssertEqual(registry["files.clipboard.move"]?.scope, .panel)
        XCTAssertEqual(registry.bindings["files.clipboard.move"], .character("v", modifiers: [.command, .option]))
        let local = CommandRegistry(defaults: defaults)
        exchange.registerCommands(in: local)
        XCTAssertNil(local.bindings["files.clipboard.copy"], "Cmd-C belongs to the native editing action")
        XCTAssertNoThrow(try registry.setBinding(.physical(35, characters: "p", modifiers: [.command, .control]), for: "files.clipboard.move"))
        XCTAssertEqual(registry.bindings["files.clipboard.move"]?.keyCode, 35)
    }
}
