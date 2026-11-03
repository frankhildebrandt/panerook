import AppKit
import PaneRookCore
import PaneRookPanels
import XCTest

@testable import PaneRookApp

final class TerminalPanelTests: XCTestCase {
    private final class Terminal: NSViewController, TerminalPanelContent {
        var viewController: NSViewController { self }
        var currentDirectory: URL?
        var hasKeyboardFocus = false
        var isRunning = false
        var onActivate: (() -> Void)?
        var onDirectoryChanged: ((URL) -> Void)?
        var onClose: (() -> Void)?
        var sessionsStarted = 0
        var stops = 0
        var focused = 0
        var visible = false

        init() { super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func loadView() { view = NSView() }
        func start(directory: URL) {
            guard !isRunning else { return }
            currentDirectory = directory
            isRunning = true
            sessionsStarted += 1
        }
        func stop() { isRunning = false; stops += 1 }
        func focus() { focused += 1 }
        func setVisible(_ visible: Bool) { self.visible = visible }
        func changeDirectory(to directory: URL) {
            currentDirectory = directory
            onDirectoryChanged?(directory)
        }
    }

    private final class Remote: NSViewController, RemotePanelContent {
        var viewController: NSViewController { self }
        var onKey: ((NSEvent) -> Bool)?
        var isActive = false
        var isBusy = false
        var hasSelection = false
        var canDownload = false
        var canUpload = false
        init() { super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func loadView() { view = NSView() }
        func focus() {}
        func focusPath() {}
        func refresh() {}
        func goUp() {}
        func openSelection() {}
        func download() {}
        func upload() {}
        func makeDirectory() {}
        func deleteSelected() {}
        func disconnect() {}
    }

    private final class Host: FileOperationsHost {
        var activePane: any PanelAccess
        let otherPane: any PanelAccess
        let presentationWindow: NSWindow?
        let canUseMenus = true
        var canUseSelection: Bool { !activePane.selectedFiles.isEmpty }
        var canUseLocalDirectory: Bool { activePane.remoteContent == nil }
        var canUseNativeDirectory: Bool { canUseLocalDirectory && !activePane.isArchiveDirectory }
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        lazy var operations = OperationRunner(tasks: tasks, refresh: {})
        var refreshed = 0
        init(source: any PanelAccess, destination: any PanelAccess, window: NSWindow) {
            activePane = source; otherPane = destination; presentationWindow = window
        }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func refreshAfterTask() { refreshed += 1 }
    }

    private var root: URL!
    private var files: URL!
    private var shell: URL!
    private var changed: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PaneRook-terminal-" + UUID().uuidString)
        files = root.appendingPathComponent("file pane", isDirectory: true)
        shell = root.appendingPathComponent("terminal pane", isDirectory: true)
        changed = root.appendingPathComponent("terminal cd ü", isDirectory: true)
        for directory in [files!, shell!, changed!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("selected file contents".utf8).write(to: files.appendingPathComponent("selected.txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "Terminal pane did not reach expected state", file: file, line: line)
    }

    private func selectFile(in pane: PaneController) throws {
        _ = pane.view
        eventually { pane.entries.contains { $0.name == "selected.txt" } }
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == "selected.txt" })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @MainActor func testShellDirectoryIsThePeerDestinationAndHiddenSelectionCannotBecomeASource() throws {
        let terminal = Terminal()
        let pane = PaneController(label: "Terminal", directory: files, terminalContent: terminal)
        let other = PaneController(label: "Files", directory: shell)
        try selectFile(in: pane)
        _ = other.view
        var directoryChanges = 0
        pane.onDirectoryChanged = { directoryChanges += 1 }

        pane.setMode(.terminal)
        XCTAssertEqual(terminal.currentDirectory, files)
        XCTAssertTrue(pane.selectedFiles.isEmpty)
        XCTAssertTrue(pane.selectedEntries.isEmpty)
        XCTAssertFalse(pane.canApplyTaskResult(in: files))

        terminal.changeDirectory(to: changed)
        XCTAssertEqual(pane.directory, changed)
        XCTAssertEqual(other.directory, shell)
        XCTAssertGreaterThan(directoryChanges, 0)
        XCTAssertEqual(pane.mode, .terminal)

        pane.setMode(.listing)
        XCTAssertEqual(pane.directory, files)
        XCTAssertEqual(pane.selectedFiles.map(\.lastPathComponent), ["selected.txt"])
        XCTAssertFalse(terminal.visible)
        XCTAssertTrue(terminal.isRunning)
        let changesAfterClosing = directoryChanges
        terminal.changeDirectory(to: shell)
        XCTAssertEqual(pane.directory, files)
        XCTAssertEqual(directoryChanges, changesAfterClosing)

        pane.setMode(.info)
        terminal.onClose?()
        XCTAssertEqual(pane.mode, .info, "A hidden shell exiting must not replace another panel mode")

        pane.setMode(.terminal)
        XCTAssertTrue(terminal.visible)
        XCTAssertEqual(terminal.sessionsStarted, 1)
        XCTAssertEqual(pane.directory, shell)
    }

    @MainActor func testRefreshPreservesShellAndExplicitNavigationReturnsToTheFileList() throws {
        let terminal = Terminal()
        let pane = PaneController(label: "Terminal", directory: files, terminalContent: terminal)
        try selectFile(in: pane)
        pane.setMode(.terminal)
        terminal.changeDirectory(to: changed)
        pane.refresh()
        pane.refreshAfterTask()
        pane.focus()
        XCTAssertEqual(pane.mode, .terminal)
        XCTAssertEqual(pane.directory, changed)
        XCTAssertEqual(terminal.sessionsStarted, 1)
        XCTAssertEqual(terminal.stops, 0)
        XCTAssertGreaterThan(terminal.focused, 0)

        pane.navigate(to: shell)
        eventually { pane.mode == .listing && pane.directory == self.shell }
        XCTAssertFalse(terminal.visible)
        XCTAssertTrue(terminal.isRunning)
    }

    @MainActor func testRemoteReplacementStopsShellAndIgnoresItsLateDirectoryCallback() throws {
        let terminal = Terminal()
        let pane = PaneController(label: "Terminal", directory: files, terminalContent: terminal)
        try selectFile(in: pane)
        pane.setMode(.terminal)
        let lateCallback = terminal.onDirectoryChanged
        terminal.changeDirectory(to: changed)
        pane.showRemoteContent(Remote())
        XCTAssertFalse(terminal.isRunning)
        XCTAssertGreaterThan(terminal.stops, 0)
        var notifications = 0
        pane.onDirectoryChanged = { notifications += 1 }
        lateCallback?(shell)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(pane.directory, files)
        XCTAssertTrue(pane.selectedFiles.isEmpty)
        pane.showRemoteContent(nil)
        XCTAssertEqual(pane.mode, .listing)
        XCTAssertEqual(pane.selectedFiles.map(\.lastPathComponent), ["selected.txt"])
    }

    @MainActor func testCopyAndMoveCaptureTerminalDirectoryWhenTransferDialogOpens() throws {
        let source = PaneController(label: "Files", directory: files)
        try selectFile(in: source)
        let terminal = Terminal()
        let destination = PaneController(label: "Terminal", directory: shell, terminalContent: terminal)
        destination.setMode(.terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = Host(source: source, destination: destination, window: window)
        let operations = FileOperations(owner: host)
        let expectedContents = try Data(contentsOf: files.appendingPathComponent("selected.txt"))

        for copying in [true, false] {
            terminal.changeDirectory(to: shell)
            if copying { operations.copySelection() } else { operations.moveSelection() }
            let sheet = try XCTUnwrap(window.attachedSheet)
            defer { if sheet.sheetParent != nil { window.endSheet(sheet, returnCode: .cancel) } }
            let content = try XCTUnwrap(sheet.contentView)
            let fields = descendants(of: content).compactMap { $0 as? NSTextField }
            let target = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "Zielpfad" })
            XCTAssertEqual(target.stringValue, shell.path + "/")
            terminal.changeDirectory(to: changed)
            XCTAssertEqual(target.stringValue, shell.path + "/")
            let submit = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }
                .first { $0.title == (copying ? "Kopieren" : "Verschieben") })
            XCTAssertTrue(submit.sendAction(submit.action, to: submit.target))
            eventually { window.attachedSheet == nil && host.refreshed == (copying ? 1 : 2) }
            let transferred = shell.appendingPathComponent("selected.txt")
            XCTAssertEqual(try Data(contentsOf: transferred), expectedContents)
            XCTAssertFalse(FileManager.default.fileExists(atPath: changed.appendingPathComponent("selected.txt").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: files.appendingPathComponent("selected.txt").path), copying)
            XCTAssertEqual(destination.mode, .terminal)
            XCTAssertEqual(terminal.sessionsStarted, 1)
            if copying { try FileManager.default.removeItem(at: transferred) }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
