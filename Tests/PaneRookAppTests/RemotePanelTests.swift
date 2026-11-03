import AppKit
import PaneRookCore
import PaneRookRemote
import XCTest

@testable import PaneRookApp

final class RemotePanelTests: XCTestCase {
    private final class RemoteContent: NSViewController, RemotePanelContent {
        var viewController: NSViewController { self }
        var onKey: ((NSEvent) -> Bool)?
        var isActive = false
        var isBusy = false
        var hasSelection = true
        var canDownload: Bool { !isBusy && hasSelection }
        var canUpload: Bool { !isBusy }
        var focused = 0
        var pathFocused = 0
        var refreshed = 0
        var movedUp = 0
        var opened = 0
        var downloaded = 0
        var uploaded = 0
        var movedLocal = 0
        var createdDirectories = 0
        var deleted = 0
        var disconnected = 0

        init() { super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func loadView() { view = NSView() }
        func focus() { focused += 1 }
        func focusPath() { pathFocused += 1 }
        func refresh() { refreshed += 1 }
        func goUp() { movedUp += 1 }
        func openSelection() { opened += 1 }
        func download() { downloaded += 1 }
        func upload() { uploaded += 1 }
        func moveLocalSelection() { movedLocal += 1 }
        func makeDirectory() { createdDirectories += 1 }
        func deleteSelected() { deleted += 1 }
        func disconnect() { disconnected += 1 }
    }

    private final class Host: FileOperationsHost, RemoteHost {
        var activePane: any PanelAccess
        let leftPane: any PanelAccess
        let rightPane: any PanelAccess
        var otherPane: any PanelAccess { activePane === leftPane ? rightPane : leftPane }
        var presentationWindow: NSWindow? { nil }
        var canUseMenus = true
        var isPerformingOperation: Bool { false }
        var errors: [String] = []
        var canUseSelection: Bool { activePane.remoteContent == nil && !activePane.selectedFiles.isEmpty }
        var canUseLocalDirectory: Bool { activePane.remoteContent == nil && activePane.mode != .network }
        var canUseNativeDirectory: Bool { canUseLocalDirectory && !activePane.isArchiveDirectory }
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        lazy var operations = OperationRunner(tasks: tasks, refresh: {})

        init(active: any PanelAccess, other: any PanelAccess) {
            activePane = active
            leftPane = active
            rightPane = other
        }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func refreshAfterTask() {}
        func showError(_ error: Error, detail: String) { errors.append(error.localizedDescription) }
    }

    private func fixture() throws -> (URL, URL, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let left = root.appendingPathComponent("left", isDirectory: true)
        let right = root.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try Data("Local file must remain untouched".utf8).write(to: left.appendingPathComponent("local.txt"))
        return (root, left, right)
    }

    private func loadAndSelectFile(in pane: PaneController) throws {
        _ = pane.view
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            pane.entries.contains { $0.name == "local.txt" }
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == "local.txt" })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(pane.selectedEntries.map(\.name), ["local.txt"])
    }

    func testConnectionOccupiesChosenPaneAndRestoresItsLocalSelection() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneController(label: "Left", directory: leftDirectory)
        let other = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: pane)
        _ = other.view
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let remote = RemoteContent()

        pane.showRemoteContent(remote)

        XCTAssertTrue(pane.remoteContent === remote)
        XCTAssertTrue(remote.parent === pane)
        XCTAssertTrue(remote.view.isDescendant(of: pane.view))
        XCTAssertNil(other.remoteContent)
        XCTAssertEqual(other.directory, rightDirectory)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertFalse(pane.canExportNativeFiles, "Remote contents must not expose the retained local selection as file URLs")
        XCTAssertNil(pane.fileExchangeDirectory)
        XCTAssertTrue(pane.selectedEntries.isEmpty)
        XCTAssertTrue(pane.selectedFiles.isEmpty)
        XCTAssertFalse(pane.canApplyTaskResult(in: leftDirectory))

        let previousFocus = remote.focused
        pane.focus()
        pane.goUp()
        pane.openSelection()
        pane.refresh()
        pane.refreshAfterTask()
        XCTAssertEqual(remote.focused, previousFocus + 1)
        XCTAssertEqual(remote.movedUp, 1)
        XCTAssertEqual(remote.opened, 1)
        XCTAssertGreaterThanOrEqual(remote.refreshed, 1)
        XCTAssertTrue(pane.remoteContent === remote)
        XCTAssertEqual(pane.directory, leftDirectory)

        pane.showRemoteContent(nil)
        XCTAssertNil(pane.remoteContent)
        XCTAssertNil(remote.parent)
        XCTAssertNil(remote.view.superview)
        XCTAssertEqual(pane.directory, leftDirectory)
        XCTAssertEqual(pane.selectedEntries.map(\.name), ["local.txt"])
    }

    func testSharedCommandsUseRemoteSelectionAndLeaveHiddenLocalFilesUntouched() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneController(label: "Left", directory: leftDirectory)
        let other = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: pane)
        let remote = RemoteContent()
        pane.showRemoteContent(remote)
        let host = Host(active: pane, other: other)
        let operations = FileOperations(owner: host)
        let registry = CommandRegistry()
        operations.registerCommands(in: registry)

        XCTAssertTrue(try XCTUnwrap(registry["copy"]).perform())
        XCTAssertTrue(try XCTUnwrap(registry["mkdir"]).perform())
        XCTAssertTrue(try XCTUnwrap(registry["trash"]).perform())
        XCTAssertTrue(try XCTUnwrap(registry["files.mkdirShortcut"]).perform())
        XCTAssertTrue(try XCTUnwrap(registry["files.trashShortcut"]).perform())
        XCTAssertEqual(remote.downloaded, 1)
        XCTAssertEqual(remote.createdDirectories, 2)
        XCTAssertEqual(remote.deleted, 2)
        XCTAssertFalse(try XCTUnwrap(registry["move"]).perform())
        XCTAssertFalse(try XCTUnwrap(registry["files.createSparse"]).perform())
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDirectory.appendingPathComponent("local.txt").path))
        XCTAssertFalse(host.tasks.hasActiveTasks)

        remote.isBusy = true
        for id in ["copy", "mkdir", "trash", "files.mkdirShortcut", "files.trashShortcut"] {
            XCTAssertFalse(try XCTUnwrap(registry[id]).perform(), id)
        }
        XCTAssertEqual(remote.downloaded, 1)
        XCTAssertEqual(remote.createdDirectories, 2)
        XCTAssertEqual(remote.deleted, 2)
    }

    func testRemappedCopyHotkeyDownloadsWithoutLeavingASecondF5Binding() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PaneRook-RemoteHotkeys-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pane = PaneController(label: "Left", directory: leftDirectory)
        let other = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: pane)
        let remote = RemoteContent()
        pane.showRemoteContent(remote)
        let host = Host(active: pane, other: other)
        let operations = FileOperations(owner: host)
        let registry = CommandRegistry(defaults: defaults)
        operations.registerCommands(in: registry)
        registry.addContextDefinitions()
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
        }
        try registry.setBinding(.physical(2, characters: "d", modifiers: [.control, .option]), for: "copy")
        let f5 = try key(96, AppKeyBinding.function(5).characters)
        XCTAssertNil(registry.matching(f5))
        XCTAssertNil(ContextCommands.matching(f5, scope: .remote, defaults: defaults))
        XCTAssertTrue(try XCTUnwrap(registry.matching(key(2, "d", flags: [.control, .option]))).perform())
        XCTAssertEqual(remote.downloaded, 1)
        XCTAssertThrowsError(try registry.setBinding(.function(7), for: "remote.download"),
                             "Remote shortcuts share the main window and must not shadow New Folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDirectory.appendingPathComponent("local.txt").path))
    }

    func testCopyAndMoveFromLocalPaneRouteToOppositeConnection() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = PaneController(label: "Left", directory: leftDirectory)
        let remotePane = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: local)
        let remote = RemoteContent()
        remotePane.showRemoteContent(remote)
        let host = Host(active: local, other: remotePane)
        let operations = FileOperations(owner: host)
        let registry = CommandRegistry()
        operations.registerCommands(in: registry)

        XCTAssertTrue(try XCTUnwrap(registry["copy"]).perform())
        XCTAssertEqual(remote.uploaded, 1)
        XCTAssertEqual(remote.downloaded, 0)
        XCTAssertTrue(try XCTUnwrap(registry["move"]).perform())
        XCTAssertEqual(remote.movedLocal, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rightDirectory.appendingPathComponent("local.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDirectory.appendingPathComponent("local.txt").path))
        XCTAssertEqual(local.selectedEntries.map(\.name), ["local.txt"])
        XCTAssertFalse(host.tasks.hasActiveTasks)

        remote.isBusy = true
        XCTAssertFalse(try XCTUnwrap(registry["copy"]).perform())
        XCTAssertEqual(remote.uploaded, 1)
        XCTAssertFalse(try XCTUnwrap(registry["move"]).perform())
        XCTAssertEqual(remote.movedLocal, 1)
    }

    func testSSHAndSFTPConnectionsUseChosenPaneWithoutOpeningWindows() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneController(label: "Left", directory: leftDirectory)
        let right = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: left)
        _ = right.view
        let host = Host(active: left, other: right)
        let tools = RemoteTools(owner: host)
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let listing = Data("-rw-r--r-- 1 501 20 12 Nov  1 10:00 remote.txt\n".utf8)

        for (kind, target, peer) in [(RemoteProtocol.shell, left, right), (.sftp, right, left)] {
            let connection = try RemoteConnection(kind: kind, host: "host.test", port: 22, user: "me")
            tools.openBrowser(connection, directory: "/home/me", pane: target, runner: { _, _ in listing })
            let browser = try XCTUnwrap(target.remoteContent)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !browser.isBusy && browser.hasSelection
            }, object: nil)
            wait(for: [loaded], timeout: 10)

            XCTAssertTrue(host.activePane === target)
            XCTAssertTrue(browser.viewController.parent === target)
            XCTAssertNil(peer.remoteContent)
            XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
            XCTAssertTrue(target.selectedFiles.isEmpty)
            browser.disconnect()
            XCTAssertNil(target.remoteContent)
            XCTAssertNil(browser.viewController.parent)
        }
        XCTAssertEqual(left.selectedEntries.map(\.name), ["local.txt"])
        XCTAssertTrue(host.errors.isEmpty)
    }

    func testDownloadTargetsOppositeLocalPane() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneController(label: "Left", directory: leftDirectory)
        let right = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: left)
        _ = right.view
        let host = Host(active: left, other: right)
        let tools = RemoteTools(owner: host)
        let connection = try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "me")
        let contents = Data("Remote contents".utf8)
        tools.openBrowser(connection, directory: "/home/me", pane: left, runner: { invocation, _ in
            if let output = invocation.outputFile {
                try contents.write(to: output)
                return Data()
            }
            return Data("-rw-r--r-- 1 501 20 15 Nov  1 10:00 remote.txt\n".utf8)
        })
        let browser = try XCTUnwrap(left.remoteContent)
        defer { browser.disconnect() }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            browser.canDownload
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        browser.download()
        let destination = rightDirectory.appendingPathComponent("remote.txt")
        let downloaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !browser.isBusy && FileManager.default.fileExists(atPath: destination.path)
        }, object: nil)
        wait(for: [downloaded], timeout: 10)

        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftDirectory.appendingPathComponent("remote.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDirectory.appendingPathComponent("local.txt").path))
        XCTAssertTrue(left.remoteContent === browser)
        XCTAssertTrue(host.errors.isEmpty)
    }

    func testSettingsChangesRefreshBothConnectedPanesWithoutReplacingThem() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneController(label: "Left", directory: leftDirectory)
        let right = PaneController(label: "Right", directory: rightDirectory)
        try loadAndSelectFile(in: left)
        _ = right.view
        let host = Host(active: left, other: right)
        let tools = RemoteTools(owner: host)
        let lock = NSLock()
        var requests = [RemoteProtocol: Int]()
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { tools.closeAll() }

        for (kind, target) in [(RemoteProtocol.shell, left), (.sftp, right)] {
            let connection = try RemoteConnection(kind: kind, host: "host.test", port: 22, user: "me")
            tools.openBrowser(connection, directory: "/home/me", pane: target, runner: { _, _ in
                let count = lock.withLock {
                    requests[kind, default: 0] += 1
                    return requests[kind, default: 0]
                }
                let names = count == 1 ? ["initial.txt"] : ["first.txt", "second.txt"]
                return Data(names.map { "-rw-r--r-- 1 501 20 12 Nov  1 10:00 \($0)\n" }.joined().utf8)
            })
        }
        let leftBrowser = try XCTUnwrap(left.remoteContent as? RemoteBrowser)
        let rightBrowser = try XCTUnwrap(right.remoteContent as? RemoteBrowser)
        let table = NSTableView()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !leftBrowser.isBusy && !rightBrowser.isBusy
                && leftBrowser.numberOfRows(in: table) == 2 && rightBrowser.numberOfRows(in: table) == 2
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        XCTAssertTrue(host.activePane === right)

        tools.settingsChanged()

        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !leftBrowser.isBusy && !rightBrowser.isBusy
                && leftBrowser.numberOfRows(in: table) == 3 && rightBrowser.numberOfRows(in: table) == 3
        }, object: nil)
        wait(for: [refreshed], timeout: 10)
        XCTAssertEqual(lock.withLock { requests[.shell] }, 2)
        XCTAssertEqual(lock.withLock { requests[.sftp] }, 2)
        XCTAssertTrue(left.remoteContent === leftBrowser)
        XCTAssertTrue(right.remoteContent === rightBrowser)
        XCTAssertTrue(leftBrowser.parent === left)
        XCTAssertTrue(rightBrowser.parent === right)
        XCTAssertTrue(host.activePane === right)
        XCTAssertEqual(left.directory, leftDirectory)
        XCTAssertEqual(right.directory, rightDirectory)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        XCTAssertTrue(host.errors.isEmpty)
    }

    func testRemotePathEditingActivatesItsPaneWithoutRefocusingTheList() throws {
        let (root, leftDirectory, rightDirectory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneController(label: "Left", directory: leftDirectory)
        let right = PaneController(label: "Right", directory: rightDirectory)
        let host = Host(active: left, other: right)
        left.onActivate = { host.activate(left) }
        let tools = RemoteTools(owner: host)
        let connection = try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "me")
        tools.openBrowser(connection, directory: "/", pane: left, runner: { _, _ in Data() })
        let browser = try XCTUnwrap(left.remoteContent as? RemoteBrowser)
        defer { browser.disconnect() }
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !browser.isBusy }, object: nil)], timeout: 10)

        var activations = 0
        left.onActivate = { activations += 1; host.activate(left) }
        host.activate(right)
        browser.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification))
        XCTAssertTrue(host.activePane === left)
        XCTAssertEqual(activations, 1)

        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        left.onKey = { _ in host.activate(right); return true }
        XCTAssertTrue(browser.onKey?(key) == true)
        XCTAssertTrue(host.activePane === right)
    }
}
