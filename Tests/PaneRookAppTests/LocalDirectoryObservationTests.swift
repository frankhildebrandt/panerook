import AppKit
import PaneRookCore
import PaneRookPanels
import XCTest

@testable import PaneRookApp

final class LocalDirectoryObservationTests: XCTestCase {
    private final class Source: LocalDirectoryEventSource {
        let roots: [URL]
        let receive: ([LocalDirectoryEvent]) -> Void
        var cancelled = false
        init(_ roots: [URL], _ receive: @escaping ([LocalDirectoryEvent]) -> Void) {
            self.roots = roots; self.receive = receive
        }
        func cancel() { cancelled = true }
        // Deliberately deliver even after cancellation to test stale callbacks.
        func send(_ url: URL, rescan: Bool = false, rootChanged: Bool = false) {
            receive([.init(url: url, mustRescan: rescan, rootChanged: rootChanged)])
        }
    }
    private final class Events {
        var sources: [Source] = []
        func make(_ roots: [URL], _ receive: @escaping ([LocalDirectoryEvent]) -> Void) -> (any LocalDirectoryEventSource)? {
            let source = Source(roots, receive); sources.append(source); return source
        }
        var current: Source { sources.last! }
    }
    private final class Reads {
        let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func read(_ url: URL, _ hidden: Bool) throws -> [FileEntry] {
            lock.withLock { count += 1 }
            return try FileSystem.list(url, showHidden: hidden)
        }
    }
    private var directory: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("PaneRook-observation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 8)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }
    private func drain(_ interval: TimeInterval = 0.15) { RunLoop.current.run(until: Date().addingTimeInterval(interval)) }
    private func file(_ name: String, contents: String = "data") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    private func pane(_ events: Events, reads: Reads = Reads()) -> PaneController {
        let pane = PaneController(label: "Test", directory: directory,
            localObservation: LocalDirectoryObservation(delay: 0.03, factory: events.make), directoryReader: reads.read)
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: self.directory) }
        return pane
    }

    func testBurstsMergeAndOldSourcesCannotPublishAfterNavigationOrStop() throws {
        let events = Events()
        let observation = LocalDirectoryObservation(delay: 0.03, factory: events.make)
        var changes: [LocalDirectoryObservation.Change] = []
        observation.onChange = { changes.append($0) }
        observation.watch(directory: directory)
        let old = events.current
        for _ in 0..<100 { old.send(directory.appendingPathComponent("file")) }
        eventually { changes.count == 1 }
        XCTAssertTrue(changes[0].listing)
        XCTAssertFalse(changes[0].git)
        let next = directory.appendingPathComponent("next")
        old.send(directory.appendingPathComponent("pending"))
        observation.watch(directory: next)
        XCTAssertTrue(old.cancelled)
        old.send(directory.appendingPathComponent("late"))
        drain()
        XCTAssertEqual(changes.count, 1)
        events.current.send(next.appendingPathComponent("new"))
        eventually { changes.count == 2 }
        let last = events.current
        observation.stop()
        last.send(next)
        drain()
        XCTAssertTrue(last.cancelled)
        XCTAssertEqual(changes.count, 2)
    }

    func testGitRootsWorktreeMetadataAndNoiseClassification() throws {
        let events = Events()
        let observation = LocalDirectoryObservation(delay: 0.03, factory: events.make)
        let worktree = directory!, sub = worktree.appendingPathComponent("Sources")
        let common = worktree.appendingPathComponent("external-metadata")
        var changes: [LocalDirectoryObservation.Change] = []
        observation.onChange = { changes.append($0) }
        observation.watch(directory: sub, worktree: worktree, metadata: common)
        XCTAssertEqual(Set(events.current.roots.map(\.path)), Set([sub, worktree, common].map { LocalDirectoryObservation.canonical($0).path }))
        for path in ["objects/ab/object", "index.lock", "logs/HEAD", "hooks/post-checkout"] {
            events.current.send(common.appendingPathComponent(path))
        }
        drain()
        XCTAssertTrue(changes.isEmpty)
        events.current.send(common.appendingPathComponent("worktrees/linked/HEAD"))
        events.current.send(worktree.appendingPathComponent("other/file.swift"))
        eventually { changes.count == 1 }
        XCTAssertTrue(changes[0].git)
        XCTAssertTrue(changes[0].repository)
        XCTAssertFalse(changes[0].listing)
        events.current.send(sub, rescan: true)
        eventually { changes.count == 2 }
        XCTAssertTrue(changes[1].listing)
        XCTAssertTrue(changes[1].git)
        events.current.send(worktree, rootChanged: true)
        eventually { changes.count == 3 }
        XCTAssertTrue(changes[2].invalidated)
    }

    func testAutomaticReloadPreservesSelectionEmptySelectionFocusScrollAndHistory() throws {
        for index in 0..<100 { _ = try file(String(format: "%03d.txt", index)) }
        let events = Events(), reads = Reads()
        let pane = pane(events, reads: reads)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        pane.view.layoutSubtreeIfNeeded()
        let selected = pane.entries[60].url
        pane.table.selectRowIndexes(IndexSet(integer: 60), byExtendingSelection: false)
        pane.table.enclosingScrollView!.contentView.scroll(to: NSPoint(x: 0, y: pane.table.rect(ofRow: 50).minY + 3))
        window.makeFirstResponder(pane.pathField)
        let responder = window.firstResponder
        let oldTop = pane.entries[50].url
        let history = pane.visitedDirectories
        let calls = reads.calls
        _ = try file("-inserted.txt")
        for _ in 0..<100 { events.current.send(directory.appendingPathComponent("-inserted.txt")) }
        eventually { pane.entries.contains { $0.name == "-inserted.txt" } }
        XCTAssertEqual(reads.calls, calls + 1)
        XCTAssertEqual(pane.selectedFiles, [selected])
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(pane.visitedDirectories, history)
        let top = try XCTUnwrap(pane.entries.firstIndex { $0.url == oldTop })
        XCTAssertEqual(pane.table.enclosingScrollView!.contentView.bounds.origin.y, pane.table.rect(ofRow: top).minY + 3, accuracy: 1)
        pane.table.deselectAll(nil)
        _ = try file("another.txt")
        events.current.send(directory.appendingPathComponent("another.txt"))
        eventually { pane.entries.contains { $0.name == "another.txt" } }
        XCTAssertTrue(pane.table.selectedRowIndexes.isEmpty)
        window.contentViewController = nil
        window.close()
    }

    func testHiddenViewsSearchResultsAndPanelLifetimeDetachObservers() throws {
        let item = try file("initial")
        let events = Events()
        let pane = pane(events)
        let first = events.current
        pane.setMode(.info)
        XCTAssertTrue(first.cancelled)
        _ = try file("while-hidden")
        first.send(directory)
        drain()
        XCTAssertFalse(pane.entries.contains { $0.name == "while-hidden" })
        pane.setMode(.listing)
        eventually { pane.entries.contains { $0.name == "while-hidden" } }
        let beforeSearch = events.current
        pane.panelize([item])
        XCTAssertTrue(beforeSearch.cancelled)
        beforeSearch.send(directory)
        drain()
        XCTAssertEqual(pane.entries.filter { !$0.isParent }.map(\.url), [item])
        pane.navigate(to: directory)
        eventually { pane.canApplyTaskResult(in: self.directory) }
        let beforeDisappear = events.current
        pane.viewDidDisappear()
        XCTAssertTrue(beforeDisappear.cancelled)
        pane.viewDidAppear()
        XCTAssertFalse(events.current.cancelled)
        let beforeHide = events.current
        pane.setLocalObservationVisible(false)
        XCTAssertTrue(beforeHide.cancelled)
        pane.setLocalObservationVisible(true)
        XCTAssertFalse(events.current.cancelled)
    }

    func testDeinitializationCancelsSource() throws {
        let events = Events()
        var controller: PaneController? = pane(events)
        weak var weakPane = controller
        controller = nil
        eventually { weakPane == nil }
        XCTAssertTrue(events.current.cancelled)
        weakPane = nil
    }

    func testSlowObservedReadCannotOverwriteFastNavigationOrModeChange() throws {
        _ = try file("old")
        let next = directory.appendingPathComponent("next")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        let events = Events(), release = DispatchSemaphore(value: 0), lock = NSLock()
        var block = false
        let started = expectation(description: "Observed read is blocked")
        let pane = PaneController(label: "Test", directory: directory,
            localObservation: LocalDirectoryObservation(delay: 0.03, factory: events.make), directoryReader: { url, hidden in
                if lock.withLock({ block }) && url == self.directory {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return try FileSystem.list(url, showHidden: hidden)
            })
        defer { release.signal() }
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: self.directory) }
        lock.withLock { block = true }
        let source = events.current
        source.send(directory.appendingPathComponent("old"))
        wait(for: [started], timeout: 5)
        pane.navigate(to: next)
        eventually { pane.directory == next && pane.canApplyTaskResult(in: next) }
        XCTAssertTrue(source.cancelled)
        release.signal()
        drain()
        XCTAssertEqual(pane.directory, next)
        XCTAssertFalse(pane.entries.contains { $0.name == "old" })
    }

    func testLostDirectoryStopsWithoutRepeatedErrorDialogsAndManualRefreshReattaches() throws {
        let events = Events(), reads = Reads()
        let pane = pane(events, reads: reads)
        var errors = 0
        pane.onError = { _ in errors += 1 }
        let source = events.current, calls = reads.calls
        try FileManager.default.removeItem(at: directory)
        source.send(directory, rootChanged: true)
        eventually { source.cancelled && reads.calls > calls }
        drain()
        XCTAssertEqual(errors, 0)
        let afterFailure = reads.calls
        source.send(directory)
        drain()
        XCTAssertEqual(reads.calls, afterFailure)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try file("restored")
        pane.refresh()
        eventually { pane.entries.contains { $0.name == "restored" } }
        XCTAssertFalse(events.current.cancelled)
    }

    func testNativeEventsRefreshCreateEditAtomicSaveRenameAndDelete() throws {
        let reads = Reads()
        let pane = PaneController(label: "Test", directory: directory,
            localObservation: LocalDirectoryObservation(delay: 0.03), directoryReader: reads.read)
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: self.directory) }
        let url = try file("external.txt", contents: "a")
        eventually { pane.entries.contains { $0.url == url && $0.size == 1 } }
        try Data("longer text".utf8).write(to: url)
        eventually { pane.entries.contains { $0.url == url && $0.size == 11 } }
        try Data("atomic".utf8).write(to: url, options: .atomic)
        eventually { pane.entries.contains { $0.url == url && $0.size == 6 } }
        let renamed = directory.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: url, to: renamed)
        eventually { pane.entries.contains { $0.url == renamed } && !pane.entries.contains { $0.url == url } }
        try FileManager.default.removeItem(at: renamed)
        eventually { !pane.entries.contains { $0.url == renamed } }
        drain(0.8)
        let stable = reads.calls
        drain(0.8)
        XCTAssertEqual(reads.calls, stable, "Reading must not cause a reload loop")
    }
    func testNativeGitStatusFollowsChangesOutsideVisibleSubdirectoryAndStopsWhenQuiet() throws {
        let repository = try GitRepository.initialize(in: directory)
        let sub = directory.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        _ = try file("tracked.txt")
        try Data("ignored/\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        try git(["add", "."])
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Initial"])
        let suite = "PaneRook-observation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let lock = NSLock()
        var snapshots = 0
        let pane = PaneController(label: "Test", directory: sub, gitStatusCache: cache,
            localObservation: LocalDirectoryObservation(delay: 0.03), gitSnapshotReader: { url in
                lock.withLock { snapshots += 1 }
                return try GitRepository.discover(in: url)?.snapshot()
            })
        _ = pane.view
        eventually { pane.gitRepository != nil && cache.snapshot(for: sub)?.branch != nil }
        try git(["switch", "-c", "external-branch"])
        eventually { cache.snapshot(for: sub)?.branch == "external-branch" }
        _ = try file("tracked.txt", contents: "changed externally")
        eventually { cache.snapshot(for: sub)?.files.contains { $0.path == "tracked.txt" && $0.isChanged } == true }
        let ignored = directory.appendingPathComponent("ignored", isDirectory: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: false)
        try Data("one".utf8).write(to: ignored.appendingPathComponent("output"))
        eventually { cache.snapshot(for: sub)?.files.contains { $0.isIgnored && $0.path == "ignored/" } == true }
        drain(1)
        let before = lock.withLock { snapshots }
        try Data("two".utf8).write(to: ignored.appendingPathComponent("output"))
        drain(2.5)
        XCTAssertEqual(lock.withLock { snapshots }, before, "Ignored build output must not run Git again")
        XCTAssertEqual(try repository.snapshot().branch, "external-branch")
    }

    func testBusyGitReaderCoalescesHundredsOfRequestsIntoOneFollowUp() throws {
        let events = Events(), lock = NSLock(), release = DispatchSemaphore(value: 0)
        let started = expectation(description: "Initial Git read blocked")
        var calls = 0
        let root = directory!
        let pane = PaneController(label: "Test", directory: root,
            localObservation: LocalDirectoryObservation(delay: 0.03, factory: events.make), gitSnapshotReader: { _ in
                let call = lock.withLock { calls += 1; return calls }
                if call == 1 {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return GitSnapshot(root: root, branch: "fresh")
            })
        defer { release.signal() }
        _ = pane.view
        wait(for: [started], timeout: 5)
        for _ in 0..<300 { events.current.send(root.appendingPathComponent(".git/index")) }
        drain(0.15)
        XCTAssertEqual(lock.withLock { calls }, 1)
        release.signal()
        eventually { pane.canUseGitFilter }
        XCTAssertEqual(lock.withLock { calls }, 2)
        drain(0.3)
        XCTAssertEqual(lock.withLock { calls }, 2)
    }

    func testModeChangeDiscardsAnAlreadyRunningObservedListing() throws {
        let events = Events(), lock = NSLock(), release = DispatchSemaphore(value: 0)
        var blocked = false
        let started = expectation(description: "Observed load started")
        let root = directory!
        let pane = PaneController(label: "Test", directory: root,
            localObservation: LocalDirectoryObservation(delay: 0.03, factory: events.make), directoryReader: { url, hidden in
                if lock.withLock({ blocked }) {
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                }
                return try FileSystem.list(url, showHidden: hidden)
            })
        defer { release.signal() }
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: root) }
        lock.withLock { blocked = true }
        _ = try file("late-result")
        events.current.send(root.appendingPathComponent("late-result"))
        wait(for: [started], timeout: 5)
        pane.setMode(.info)
        release.signal()
        drain(0.3)
        XCTAssertFalse(pane.entries.contains { $0.name == "late-result" })
        XCTAssertEqual(pane.mode, .info)
    }

    func testNativeDefaultTemporaryDirectoryAliasesAndDeletedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-alias-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneController(label: "Test", directory: root, localObservation: LocalDirectoryObservation(delay: 0.03))
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: root) }
        let url = root.appendingPathComponent("aliased.txt")
        try Data("content".utf8).write(to: url)
        eventually { pane.entries.contains { $0.name == "aliased.txt" } }
        try FileManager.default.removeItem(at: url)
        eventually { !pane.entries.contains { $0.name == "aliased.txt" } }
    }

    func testNativeLinkedWorktreeObservesSharedStashesAndItsOwnHead() throws {
        _ = try GitRepository.initialize(in: directory)
        _ = try file("tracked.txt")
        try git(["config", "user.name", "Test"])
        try git(["config", "user.email", "test@example.invalid"])
        try git(["add", "tracked.txt"])
        try git(["commit", "-m", "Initial"])
        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try git(["worktree", "add", "-b", "linked-branch", linked.path])
        let suite = "PaneRook-linked-observation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let pane = PaneController(label: "Test", directory: linked, gitStatusCache: cache,
            localObservation: LocalDirectoryObservation(delay: 0.03))
        _ = pane.view
        eventually { pane.gitRepository != nil && cache.snapshot(for: linked)?.branch == "linked-branch" }
        try git(["-C", linked.path, "switch", "-c", "external-linked"])
        eventually { cache.snapshot(for: linked)?.branch == "external-linked" }
        _ = try file("tracked.txt", contents: "main worktree edit")
        try git(["stash", "push", "-m", "main worktree stash"])
        eventually { cache.snapshot(for: linked)?.stashes.first?.subject.contains("main worktree stash") == true }
    }

    func testNativeChildRepositoryBadgeUpdatesThroughASymlinkPanelPath() throws {
        let visible = directory.appendingPathComponent("visible", isDirectory: true)
        try FileManager.default.createDirectory(at: visible, withIntermediateDirectories: false)
        let child = visible.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        _ = try GitRepository.initialize(in: child)
        let tracked = child.appendingPathComponent("tracked.txt")
        try Data("original".utf8).write(to: tracked)
        try git(["-C", child.path, "add", "."])
        try git(["-C", child.path, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Initial"])
        let alias = directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let panelDirectory = alias.appendingPathComponent("visible", isDirectory: true)
        let suite = "PaneRook-symlink-observation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let pane = PaneController(label: "Test", directory: panelDirectory, gitStatusCache: cache,
            localObservation: LocalDirectoryObservation(delay: 0.03))
        _ = pane.view
        eventually { pane.canApplyTaskResult(in: panelDirectory) }
        let folder = try XCTUnwrap(pane.allEntries.first { $0.name == "repository" }?.url)
        eventually { cache.status(for: folder)?.modifiedCount == 0 }
        try Data("changed externally".utf8).write(to: tracked)
        eventually { cache.status(for: folder)?.modifiedCount == 1 }
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testTreeKeepsExpandedNodesAndSelectionWhileRefreshingLoadedLevels() throws {
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let tree = PanelDirectoryTree()
        tree.setRoot(directory, showHidden: false)
        eventually { tree.outline.numberOfRows == 2 }
        let node = try XCTUnwrap(tree.outline.item(atRow: 1))
        tree.outline.expandItem(node)
        tree.outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let child = folder.appendingPathComponent("new-child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        tree.refreshLoadedDirectories()
        eventually { tree.outline.numberOfRows == 3 }
        XCTAssertTrue(tree.outline.isItemExpanded(node))
        XCTAssertEqual(tree.selectedURL?.path, folder.path)
        XCTAssertTrue(tree.outline.item(atRow: 1) as AnyObject === node as AnyObject)
    }

    func testArchiveAndRemoteViewsDoNotObserveHiddenLocalListing() throws {
        _ = try file("inside.txt")
        let archive = directory.appendingPathComponent("fixture.tar")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", archive.path, "-C", directory.path, "inside.txt"]
        tar.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        try tar.run(); tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)
        let events = Events()
        let pane = pane(events)
        pane.navigate(to: archive)
        eventually { pane.isArchiveDirectory && pane.canApplyTaskResult(in: archive) }
        XCTAssertTrue(events.current.cancelled)
        let count = events.sources.count
        pane.setMode(.listing)
        drain()
        XCTAssertEqual(events.sources.count, count)
        pane.navigate(to: directory)
        eventually { pane.directory == self.directory && pane.canApplyTaskResult(in: self.directory) }
        let source = events.current
        let remote = Remote()
        pane.showRemoteContent(remote)
        XCTAssertTrue(source.cancelled)
        _ = try file("hidden-local")
        source.send(directory)
        drain()
        XCTAssertFalse(pane.entries.contains { $0.name == "hidden-local" })
        pane.refresh()
        XCTAssertEqual(remote.refreshes, 1)
        pane.showRemoteContent(nil)
        eventually { pane.entries.contains { $0.name == "hidden-local" } }
    }

    private final class Remote: NSViewController, RemotePanelContent {
        var viewController: NSViewController { self }
        var onKey: ((NSEvent) -> Bool)?
        var isActive = false, isBusy = false, hasSelection = false, canDownload = false, canUpload = false
        var refreshes = 0
        override func loadView() { view = NSView() }
        func focus() {}
        func focusPath() {}
        func refresh() { refreshes += 1 }
        func goUp() {}
        func openSelection() {}
        func download() {}
        func upload() {}
        func makeDirectory() {}
        func deleteSelected() {}
        func disconnect() {}
    }

}
