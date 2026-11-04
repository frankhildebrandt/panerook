import AppKit
import PaneRookCore
import PaneRookRemote
import XCTest
@testable import PaneRookApp

final class WorkspaceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var root: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        suite = "PaneRookWorkspaces-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.path, forKey: "leftDirectory")
        defaults.set(root.path, forKey: "rightDirectory")
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func commander() -> CommanderController {
        let commander = CommanderController(defaults: defaults)
        commander.tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        _ = commander.view
        return commander
    }
    func testIndependentTabsKeepSelectionHistorySearchResultsAndOptions() throws {
        let folder = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("chosen.txt")
        try Data("Contents".utf8).write(to: file)
        let commander = commander()
        let original = commander.left
        original.navigate(to: folder)
        eventually { original.entries.contains { $0.name == "chosen.txt" } }
        original.setFilter("*.txt"); original.setSort(key: "size", ascending: false)
        original.setBriefListing(true)
        let row = try XCTUnwrap(original.entries.firstIndex { $0.name == "chosen.txt" })
        original.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let registry = commander.commandRegistry
        XCTAssertTrue(registry["left.sort.size"]!.checked())
        let originalHistory = original.visitedDirectories
        commander.newTab()
        let second = commander.left
        XCTAssertFalse(second === original)
        second.setFilter("")
        second.setSort(key: "name", ascending: true)
        XCTAssertFalse(registry["left.sort.size"]!.checked(), "Menus resolve the selected tab")
        second.navigate(to: root)
        eventually { second.directory == self.root }
        second.panelize([file])
        second.selectMatching("chosen.txt", select: true)
        commander.workspaceSession.left.select(original)
        XCTAssertTrue(commander.active === original)
        XCTAssertTrue(registry["left.sort.size"]!.checked())
        XCTAssertEqual(original.directory, folder)
        XCTAssertEqual(original.selectedFiles.map(\.lastPathComponent), ["chosen.txt"])
        XCTAssertEqual(original.filterPattern, "*.txt")
        XCTAssertEqual(original.sortKey, "size")
        XCTAssertFalse(original.sortAscending)
        XCTAssertTrue(original.isBriefListing)
        XCTAssertEqual(original.visitedDirectories, originalHistory)
        commander.workspaceSession.left.select(second)
        XCTAssertFalse(second.canApplyTaskResult(in: root), "Search results survive tab switches")
        XCTAssertEqual(second.selectedFiles.map(\.lastPathComponent), ["chosen.txt"])
        commander.closeActiveTab()
        XCTAssertTrue(commander.left === original)
        XCTAssertEqual(commander.workspaceSession.left.panes.count, 1)
        commander.closeActiveTab()
        XCTAssertEqual(commander.workspaceSession.left.panes.count, 1)
    }
    func testTabAndWorkspaceVisibilityControlsObservationAndKeepsNativeExchange() throws {
        let commander = commander()
        let events = ObservationEvents()
        let firstFile = root.appendingPathComponent("first.txt")
        try Data("selected".utf8).write(to: firstFile)
        let pane = PaneController(label: "Observed tab", directory: root,
            localObservation: LocalDirectoryObservation(delay: 0.01, factory: events.make))
        commander.configureTab(pane)
        commander.workspaceSession.left.append(pane)
        eventually { !events.sources.isEmpty && pane.entries.contains { $0.name == "first.txt" } }
        pane.selectMatching("first.txt", select: true)
        let firstSource = try XCTUnwrap(events.sources.last)
        XCTAssertFalse(firstSource.cancelled)
        XCTAssertTrue(pane.fileExchange === commander.fileExchange)
        commander.newTab()
        XCTAssertTrue(commander.left.fileExchange === commander.fileExchange)
        XCTAssertTrue(firstSource.cancelled)
        let laterFile = root.appendingPathComponent("later.txt")
        try Data("external".utf8).write(to: laterFile)
        firstSource.receive([.init(url: laterFile)])
        commander.workspaceSession.left.select(pane)
        eventually { pane.entries.contains { $0.name == "later.txt" } }
        XCTAssertEqual(pane.selectedFiles.map(\.lastPathComponent), ["first.txt"])
        let visibleSource = try XCTUnwrap(events.sources.last)
        commander.togglePanels()
        XCTAssertTrue(visibleSource.cancelled)
        commander.togglePanels()
        eventually { events.sources.last?.cancelled == false }
        let workspace = commander.workspaceSession
        let resumedSource = try XCTUnwrap(events.sources.last)
        commander.createWorkspace()
        XCTAssertTrue(resumedSource.cancelled)
        XCTAssertTrue(commander.left.fileExchange === commander.fileExchange)
        commander.loadWorkspace(id: workspace.id)
        eventually { events.sources.last?.cancelled == false }
        let finalSource = try XCTUnwrap(events.sources.last)
        commander.closeActiveTab()
        XCTAssertTrue(finalSource.cancelled)
    }
    private final class ObservationEvents {
        final class Source: LocalDirectoryEventSource {
            var cancelled = false
            let receive: ([LocalDirectoryEvent]) -> Void
            init(receive: @escaping ([LocalDirectoryEvent]) -> Void) { self.receive = receive }
            func cancel() { cancelled = true }
        }
        var sources: [Source] = []
        func make(_ roots: [URL], _ receive: @escaping ([LocalDirectoryEvent]) -> Void) -> (any LocalDirectoryEventSource)? {
            let source = Source(receive: receive)
            sources.append(source)
            return source
        }
    }
    func testWorkspaceRoundTripRestoresBothGroupsActiveTabsAndRemoteLocationWithoutCredentials() throws {
        let connection = try RemoteConnection(kind: .ftp, host: "example.test", port: 21, user: "user", password: "NEVER_PERSIST_THIS")
        let commander = commander()
        commander.newTab()
        commander.left.setFilter("*.swift")
        commander.left.setMode(.info)
        commander.activate(commander.right)
        commander.newTab()
        let remote = RemoteBrowser(connection: connection, peer: commander.left, tasks: commander.tasks)
        remote.directory = "/public/site"
        commander.right.showRemoteContent(remote)
        commander.right.setSort(key: "modified", ascending: false)
        try commander.saveWorkspace(named: "Website")
        let expected = try WorkspaceStore(defaults: defaults).load().session
        let data = try XCTUnwrap(defaults.data(forKey: WorkspaceStore.key))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("NEVER_PERSIST_THIS"))
        let restored = self.commander()
        XCTAssertEqual(restored.workspaceSession.left.panes.count, 2)
        XCTAssertEqual(restored.workspaceSession.right.panes.count, 2)
        XCTAssertTrue(restored.active === restored.right)
        XCTAssertEqual(restored.left.mode, .info)
        XCTAssertEqual(restored.left.filterPattern, "*.swift")
        XCTAssertEqual(restored.right.pendingWorkspaceConnection?.path, "/public/site")
        XCTAssertEqual(restored.right.remoteContent?.workspaceBookmark?.host, "example.test")
        XCTAssertTrue(restored.right.remoteContent?.awaitsWorkspaceAuthentication == true)
        XCTAssertTrue(restored.right.selectedFiles.isEmpty)
        XCTAssertFalse(restored.right.remoteContent?.canUpload ?? true)
        XCTAssertEqual(restored.right.sortKey, "modified")
        XCTAssertFalse(restored.right.sortAscending)
        XCTAssertEqual(restored.left.tabID, expected?.left.activeTab)
        XCTAssertEqual(restored.right.tabID, expected?.right.activeTab)
        XCTAssertTrue(restored.canReconnectWorkspaceTab)
        remote.disconnect()
    }
    func testLegacySettingsAndRestoreOptOutArePreserved() throws {
        defaults.set("*.txt", forKey: "leftFilter")
        defaults.set("size", forKey: "leftSort")
        defaults.set(false, forKey: "leftAscending")
        let first = commander()
        XCTAssertEqual(first.left.directory.path, root.path)
        XCTAssertEqual(first.left.filterPattern, "*.txt")
        XCTAssertEqual(first.left.sortKey, "size")
        XCTAssertFalse(first.left.sortAscending)
        first.newTab()
        try first.saveWorkspace(named: "Project")
        defaults.set(false, forKey: "restorePanels")
        let second = commander()
        XCTAssertEqual(second.workspaceSession.left.panes.count, 1)
        XCTAssertEqual(second.left.directory, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(second.workspaceNames.count, 1)
        XCTAssertEqual(defaults.string(forKey: "leftFilter"), "*.txt")
    }
    func testTabActionsHaveDistinctConfigurableDefaults() throws {
        let registry = commander().commandRegistry
        for id in ["tabs.new", "tabs.close", "tabs.next", "tabs.previous"] {
            let binding = try XCTUnwrap(registry.bindings[id])
            XCTAssertNil(registry.conflicts(for: binding, assigningTo: id), id)
        }
        XCTAssertNotNil(registry["workspaces.reconnect"])
    }
    func testInvalidAndFutureArchivesAreNotOverwritten() throws {
        let store = WorkspaceStore(defaults: defaults)
        for data in [Data("invalid".utf8), Data("{\"version\":999,\"workspaces\":[]}".utf8)] {
            defaults.set(data, forKey: WorkspaceStore.key)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(WorkspaceArchive()))
            XCTAssertEqual(defaults.data(forKey: WorkspaceStore.key), data)
        }
        defaults.removeObject(forKey: WorkspaceStore.key)
        let tab = WorkspaceTab(directory: root)
        var group = WorkspacePanelGroup(tabs: [tab])
        group.activeTab = UUID()
        let invalid = ProjectWorkspace(name: "Bad", left: group, right: group)
        XCTAssertThrowsError(try store.save(WorkspaceArchive(workspaces: [invalid])))
    }
    @MainActor func testWorkspaceSwitchRetainsShellIdentityAndTerminalDirectory() throws {
        let commander = commander()
        let terminal = TestTerminal()
        let pane = PaneController(label: "Shell", directory: root, terminalContent: terminal)
        commander.configureTab(pane)
        commander.workspaceSession.left.append(pane)
        pane.setMode(.terminal)
        terminal.currentDirectory = root.appendingPathComponent("cwd")
        try commander.saveWorkspace(named: "Shell project")
        let original = commander.workspaceSession
        commander.createWorkspace()
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(terminal.stops, 0)
        commander.loadWorkspace(id: original.id)
        XCTAssertTrue(commander.left === pane)
        XCTAssertTrue(terminal.isRunning)
        XCTAssertEqual(terminal.starts, 1)
        XCTAssertEqual(pane.workspaceSnapshot().terminalDirectory, terminal.currentDirectory)
        XCTAssertEqual(pane.workspaceSnapshot().directory, root)
        pane.setMode(.listing)
        commander.newTab()
        commander.workspaceSession.left.select(pane)
        XCTAssertEqual(terminal.stops, 0)
        terminal.stop()
    }
    func testActivatingParkedTabsUpdatesTransferPeerAndRetainsTheCurrentWorkspace() throws {
        let commander = commander()
        let original = commander.left
        commander.remote.openBrowser(try RemoteConnection(kind: .shell, host: "source.test", port: 22, user: "me"),
            directory: "/", pane: commander.right, runner: { _, _ in Data() })
        let browser = try XCTUnwrap(commander.right.remoteContent as? RemoteBrowser)
        eventually { !browser.isBusy }
        commander.activate(original)
        commander.newTab()
        XCTAssertTrue(browser.peer === commander.left)
        XCTAssertFalse(browser.peer === original)
        commander.activate(original)
        XCTAssertTrue(browser.peer === original)
        try commander.saveWorkspace(named: "Remote project")
        commander.createWorkspace()
        let parked = commander.workspaceSession
        commander.activate(original)
        XCTAssertTrue(commander.liveWorkspaces[parked.id] === parked)
        XCTAssertTrue(commander.left === original)
        XCTAssertTrue(browser.peer === original)
        browser.disconnect()
    }
    func testWorkspaceNamingAndRemovalKeepLiveTabsAndRejectFailedStorage() throws {
        let commander = commander()
        try commander.saveWorkspace(named: "Website")
        let website = commander.workspaceSession
        commander.createWorkspace()
        XCTAssertThrowsError(try commander.saveWorkspace(named: "website"))
        try commander.saveWorkspace(named: "Other")
        commander.loadWorkspace(id: website.id)
        let pane = commander.left
        commander.removeWorkspace(id: website.id)
        XCTAssertTrue(commander.left === pane)
        XCTAssertTrue(commander.workspaceNames.contains { $0.0 == website.id && $0.1.contains("Sitzung") })
        XCTAssertFalse(try WorkspaceStore(defaults: defaults).load().workspaces.contains { $0.id == website.id })
        defaults.set(Data("corrupt".utf8), forKey: WorkspaceStore.key)
        XCTAssertThrowsError(try commander.saveWorkspace(named: "Cannot save"))
        XCTAssertEqual(commander.currentWorkspaceName, "Website")
        XCTAssertEqual(defaults.data(forKey: WorkspaceStore.key), Data("corrupt".utf8))
    }
    func testRemoteTransferKeepsCapturedTargetDuringTabAndWorkspaceSwitch() throws {
        let commander = commander()
        let target = commander.right
        target.navigate(to: root)
        eventually { target.directory == self.root }
        let started = expectation(description: "download started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let payload = Data("captured remote contents".utf8)
        commander.newTab()
        var blockedFirstRead = false
        commander.remote.openBrowser(try RemoteConnection(kind: .shell, host: "source.test", port: 22, user: "me"), directory: "/source", pane: commander.left, runner: { request, _ in
            if let output = request.outputFile {
                if !blockedFirstRead {
                    blockedFirstRead = true
                    started.fulfill()
                    guard gate.wait(timeout: .now() + 10) == .success else { throw RemoteError.cancelled }
                }
                try payload.write(to: output)
                return Data()
            }
            if request.arguments.last == "LC_ALL=C ls -lan '/'" {
                return Data("drwxr-xr-x 2 501 20 64 Nov  1 10:00 source\n".utf8)
            }
            return Data("-rw-r--r-- 1 501 20 24 Nov  1 10:00 selected.txt\n".utf8)
        })
        let browser = try XCTUnwrap(commander.left.remoteContent as? RemoteBrowser)
        eventually { !browser.isBusy }
        let row = try XCTUnwrap(browser.entries.firstIndex { $0.name == "selected.txt" })
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        browser.download()
        wait(for: [started], timeout: 10)
        XCTAssertFalse(commander.canClosePanelTab)
        commander.closeActiveTab()
        XCTAssertEqual(commander.workspaceSession.left.panes.count, 2)
        XCTAssertFalse(browser.disconnected)
        commander.activate(target)
        commander.newTab()
        let later = root.appendingPathComponent("later")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        commander.right.navigate(to: later)
        eventually { commander.right.directory == later }
        XCTAssertTrue(browser.peer === commander.right)
        commander.createWorkspace()
        XCTAssertFalse(browser.disconnected)
        gate.signal()
        eventually { !browser.isBusy && !commander.tasks.hasActiveTasks }
        XCTAssertEqual(commander.tasks.snapshots.last?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("selected.txt")), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.appendingPathComponent("selected.txt").path))
        XCTAssertFalse(browser.disconnected)
        browser.disconnect()
    }
    private final class TestTerminal: NSViewController, TerminalPanelContent {
        var viewController: NSViewController { self }
        var currentDirectory: URL?
        var hasKeyboardFocus = false
        var isRunning = false
        var onActivate: (() -> Void)?
        var onDirectoryChanged: ((URL) -> Void)?
        var onClose: (() -> Void)?
        var starts = 0
        var stops = 0
        init() { super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        override func loadView() { view = NSView() }
        func start(directory: URL) { if !isRunning { currentDirectory = directory; isRunning = true; starts += 1 } }
        func stop() { isRunning = false; stops += 1 }
        func focus() {}
        func setVisible(_ visible: Bool) {}
    }
}
