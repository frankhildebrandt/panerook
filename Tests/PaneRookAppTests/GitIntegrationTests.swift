import AppKit
import Foundation
import PaneRookCore
import PaneRookPanels
import XCTest

@testable import PaneRookApp

final class GitIntegrationTests: XCTestCase {
    private var temporary: URL!
    private var repository: URL!
    private var ordinary: URL!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-git-ui-" + UUID().uuidString)
        repository = temporary.appendingPathComponent("repository")
        ordinary = temporary.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        for name in ["changed.txt", "clean.txt"] {
            try Data("initial\n".utf8).write(to: repository.appendingPathComponent(name))
        }
        try Data("ordinary\n".utf8).write(to: ordinary.appendingPathComponent("ordinary.txt"))
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "PaneRook Tests"])
        try git(["config", "user.email", "panerook-tests@example.invalid"])
        try git(["add", "."])
        try git(["commit", "-m", "Initial test version"])
        try Data("modified\n".utf8).write(to: repository.appendingPathComponent("changed.txt"))
        try Data("new\n".utf8).write(to: repository.appendingPathComponent("new.txt"))
    }

    override func tearDownWithError() throws {
        let store = GitWatchStore()
        store.toggle(paths: Array(store.paths(in: repository)), in: repository)
        try FileManager.default.removeItem(at: temporary)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError(String(decoding: data, as: UTF8.self))
        }
    }

    private func eventually(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard condition() else {
            XCTFail("Asynchronous Git UI did not reach the expected state", file: file, line: line)
            throw GitError("Git UI test timed out")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func gitColumn(_ pane: PaneController) throws -> NSTableColumn {
        try XCTUnwrap(pane.table.tableColumn(withIdentifier: .init("git")))
    }

    func testCachedHeaderAppearsImmediatelyAndAlwaysGetsFreshStatus() throws {
        let suite = "PaneRookGitHeaderCache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let missing = temporary.appendingPathComponent("missing")
        for directory in [repository!, ordinary!, missing] {
            cache.store(GitHeaderStatus(snapshot: GitSnapshot(root: directory, branch: "cached-branch")), for: directory)
            // A new cache instance models the first display after an app restart.
            let restored = GitStatusCache(defaults: defaults)
            let pane = PaneController(label: "Cached Header", directory: directory, gitStatusCache: restored)
            let branch = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("openGit") })
            let group = try XCTUnwrap(branch.superview)
            let filter = try XCTUnwrap(descendants(of: group).compactMap { $0 as? NSPopUpButton }.first)
            XCTAssertFalse(group.isHidden)
            XCTAssertEqual(branch.title, "cached-branch · sauber")
            XCTAssertTrue(branch.toolTip?.contains("Zuletzt bekannter Status") == true)
            XCTAssertFalse(filter.isEnabled)
            XCTAssertTrue(try gitColumn(pane).isHidden)

            if directory == repository {
                try eventually { branch.title == "main · 2 geändert" && filter.isEnabled }
                XCTAssertEqual(restored.header(for: directory)?.branch, "main")
                XCTAssertFalse(branch.toolTip?.contains("Zuletzt bekannter Status") == true)
            } else {
                try eventually { group.isHidden && restored.header(for: directory) == nil }
                XCTAssertNil(GitStatusCache(defaults: defaults).header(for: directory))
            }
        }
    }

    func testCachedBadgesAreRevalidatedAndRemovedWhenRepositoryDisappears() throws {
        let suite = "PaneRookGitBadgeCache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let folders = try FileSystem.list(temporary, showHidden: false).filter(\.isDirectory)
        for folder in folders { cache.store(GitRepositoryStatus(branch: "cached-branch"), for: folder.url) }
        let pane = PaneController(label: "Cached Badges", directory: temporary, gitStatusCache: cache)
        func badge(for name: String) -> GitStatusBadge? {
            guard let column = pane.table.tableColumns.first,
                  let row = pane.entries.firstIndex(where: { $0.name == name }),
                  let cell = pane.tableView(pane.table, viewFor: column, row: row) else { return nil }
            return cell.subviews.compactMap { $0 as? GitStatusBadge }.first
        }
        var firstBadges: [String: String] = [:]
        pane.onDirectoryChanged = {
            for folder in folders { firstBadges[folder.name] = badge(for: folder.name)?.stringValue }
        }
        _ = pane.view
        try eventually { !firstBadges.isEmpty }
        XCTAssertEqual(firstBadges, ["ordinary": "✓ cached-branch", "repository": "✓ cached-branch"])
        try eventually { badge(for: "repository")?.stringValue == "● main" && badge(for: "ordinary") == nil }
        let repositoryURL = try XCTUnwrap(folders.first { $0.name == "repository" }?.url)
        let ordinaryURL = try XCTUnwrap(folders.first { $0.name == "ordinary" }?.url)
        XCTAssertEqual(cache.status(for: repositoryURL)?.branch, "main")
        XCTAssertNil(cache.status(for: ordinaryURL))

        pane.onDirectoryChanged = nil
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        pane.refresh()
        try eventually { badge(for: "repository") == nil && cache.status(for: repositoryURL) == nil }
        XCTAssertNil(GitStatusCache(defaults: defaults).status(for: repositoryURL))
    }

    func testSessionFileStatusAndFiltersAppearBeforeFreshSnapshotAndDisappearWhenRepositoryIsRemoved() throws {
        let suite = "PaneRookGitSessionCache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let firstPane = PaneController(label: "First Panel", directory: repository, gitStatusCache: cache)
        _ = firstPane.view
        try eventually { cache.snapshot(for: self.repository)?.files.filter(\.isChanged).count == 2 }
        firstPane.navigate(to: ordinary)
        try eventually { firstPane.directory == self.ordinary }
        try git(["add", "."])
        try git(["commit", "-m", "Commit previously cached changes"])

        let pane = PaneController(label: "Second Panel", directory: repository, gitStatusCache: cache)
        pane.setGitFilter(.changed)
        var initialFiles: [String]?
        var initialStatuses: [String: String] = [:]
        pane.onDirectoryChanged = {
            initialFiles = pane.entries.map(\.name)
            guard let column = pane.table.tableColumn(withIdentifier: .init("git")) else { return }
            for (row, entry) in pane.entries.enumerated() where !entry.isParent {
                let cell = pane.tableView(pane.table, viewFor: column, row: row) as? NSTableCellView
                initialStatuses[entry.name] = cell?.textField?.stringValue
            }
            XCTAssertFalse(column.isHidden)
        }
        _ = pane.view
        try eventually { initialFiles != nil }
        XCTAssertEqual(initialFiles, ["..", "changed.txt", "new.txt"])
        XCTAssertEqual(initialStatuses, ["changed.txt": ".M", "new.txt": "??"])
        try eventually {
            cache.snapshot(for: self.repository)?.files.filter(\.isChanged).isEmpty == true
                && pane.entries.map(\.name) == [".."]
        }
        XCTAssertNil(GitStatusCache(defaults: defaults).snapshot(for: repository))

        pane.onDirectoryChanged = nil
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))
        let column = try gitColumn(pane)
        var columnHiddenAfterRemoval: Bool?
        var filesAfterRemoval: [String]?
        pane.onDirectoryChanged = {
            columnHiddenAfterRemoval = column.isHidden
            filesAfterRemoval = pane.entries.map(\.name)
        }
        pane.refresh()
        try eventually { columnHiddenAfterRemoval != nil }
        XCTAssertEqual(columnHiddenAfterRemoval, true)
        XCTAssertEqual(filesAfterRemoval, ["..", "changed.txt", "clean.txt", "new.txt"])
        try eventually { column.isHidden && cache.snapshot(for: self.repository) == nil }
    }

    func testPanelLoadsGitStatusAndCombinesStatusWithFilenameFilter() throws {
        let pane = PaneController(label: "Git Test", directory: repository)
        _ = pane.view
        let column = try gitColumn(pane)
        try eventually { !column.isHidden && pane.entries.contains { $0.name == "clean.txt" } }
        let branch = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("openGit") })
        XCTAssertTrue(branch.title.contains("main"))
        XCTAssertTrue(branch.title.contains("2 geändert"))

        pane.setGitFilter(.changed)
        XCTAssertEqual(pane.entries.map(\.name), ["..", "changed.txt", "new.txt"])
        pane.setFilter("changed*")
        XCTAssertEqual(pane.entries.map(\.name), ["..", "changed.txt"])
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == "changed.txt" })
        let cell = try XCTUnwrap(pane.tableView(pane.table, viewFor: column, row: row) as? NSTableCellView)
        XCTAssertTrue(cell.textField?.stringValue.contains("M") == true)

        pane.setBriefListing(true)
        XCTAssertTrue(column.isHidden)
        pane.refresh()
        try eventually { pane.canApplyTaskResult(in: self.repository) }
        XCTAssertTrue(pane.isBriefListing)
        XCTAssertTrue(column.isHidden)
        pane.setBriefListing(false)
        XCTAssertFalse(column.isHidden)
    }

    func testFirstVisitToDeepSubdirectoryUsesWholeRepositorySnapshotBeforeFreshStatus() throws {
        let suite = "PaneRookGitSubdirectoryCache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let child = repository.appendingPathComponent("Sources/Deep")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("initial\n".utf8).write(to: child.appendingPathComponent("changed.txt"))
        try Data("clean\n".utf8).write(to: child.appendingPathComponent("clean.txt"))
        try git(["add", "."])
        try git(["commit", "-m", "Subdirectory fixture"])
        try Data("modified\n".utf8).write(to: child.appendingPathComponent("changed.txt"))
        try Data("untracked\n".utf8).write(to: child.appendingPathComponent("new.txt"))
        let first = PaneController(label: "Repository Root", directory: repository, gitStatusCache: cache)
        _ = first.view
        try eventually { cache.snapshot(for: self.repository)?.files.filter(\.isChanged).count == 2 }
        XCTAssertNil(cache.snapshot(for: child))
        try git(["add", "."])
        try git(["commit", "-m", "Commit child changes after caching"])

        let pane = PaneController(label: "Unvisited Child", directory: child, gitStatusCache: cache)
        pane.setGitFilter(.changed)
        var initialFiles: [String]?
        var initialStatuses: [String: String] = [:]
        pane.onDirectoryChanged = {
            initialFiles = pane.entries.map(\.name)
            guard let column = pane.table.tableColumn(withIdentifier: .init("git")) else { return }
            XCTAssertFalse(column.isHidden)
            for (row, entry) in pane.entries.enumerated() where !entry.isParent {
                let cell = pane.tableView(pane.table, viewFor: column, row: row) as? NSTableCellView
                initialStatuses[entry.name] = cell?.textField?.stringValue
            }
        }
        _ = pane.view
        try eventually { initialFiles != nil }
        XCTAssertEqual(initialFiles, ["..", "changed.txt", "new.txt"])
        XCTAssertEqual(initialStatuses, ["changed.txt": ".M", "new.txt": "??"])
        try eventually {
            pane.entries.map(\.name) == [".."]
                && cache.snapshot(for: child)?.files.filter(\.isChanged).isEmpty == true
        }
    }

    func testNewNestedRepositoryDoesNotReuseAnOldAliasToTheOuterSnapshot() throws {
        let suite = "PaneRookGitNestedCache-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = GitStatusCache(defaults: defaults)
        let child = repository.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data("file\n".utf8).write(to: child.appendingPathComponent("file.txt"))
        let outer = try GitRepository(directory: repository).snapshot()
        cache.storeSnapshot(outer, for: child)
        cache.store(GitHeaderStatus(snapshot: outer), for: child)
        try git(["init", "-b", "nested-branch", child.path])

        let pane = PaneController(label: "Nested Repository", directory: child, gitStatusCache: cache)
        var initialGitColumnHidden: Bool?
        var initialGitHeaderHidden: Bool?
        pane.onDirectoryChanged = {
            initialGitColumnHidden = pane.table.tableColumn(withIdentifier: .init("git"))?.isHidden
            initialGitHeaderHidden = self.descendants(of: pane.view).compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("openGit") }?.superview?.isHidden
        }
        _ = pane.view
        try eventually { initialGitColumnHidden != nil }
        XCTAssertEqual(initialGitColumnHidden, true)
        XCTAssertEqual(initialGitHeaderHidden, true)
        try eventually { cache.snapshot(for: child)?.branch == "nested-branch" }
        XCTAssertEqual(cache.snapshot(for: child)?.root.path, child.resolvingSymlinksInPath().path)
        XCTAssertEqual(cache.snapshot(for: repository)?.branch, "main")
    }

    func testChoosingGitFilterSurvivesPanelActivationRefreshingTheDropdown() throws {
        let pane = PaneController(label: "Filter Activation", directory: repository)
        _ = pane.view
        let column = try gitColumn(pane)
        try eventually { !column.isHidden && pane.entries.contains { $0.name == "clean.txt" } }
        let popup = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.action == NSSelectorFromString("gitFilterChanged") })
        var activations = 0
        pane.onActivate = { [weak pane] in
            activations += 1
            // The Commander refreshes navigation when this panel is activated,
            // including when it was already the active panel.
            pane?.isActive = true
        }
        let choices: [(GitFileFilter, [String])] = [
            (.changed, ["..", "changed.txt", "new.txt"]),
            (.untracked, ["..", "new.txt"]),
            (.all, ["..", "changed.txt", "clean.txt", "new.txt"])
        ]
        for (index, choice) in choices.enumerated() {
            popup.selectItem(withTitle: choice.0.title)
            XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
            XCTAssertEqual(activations, index + 1)
            XCTAssertTrue(pane.isActive)
            XCTAssertEqual(pane.gitFilter, choice.0)
            XCTAssertEqual(popup.titleOfSelectedItem, choice.0.title)
            XCTAssertEqual(pane.entries.map(\.name), choice.1)
        }
    }

    func testFullListingKeepsGitColumnHiddenOutsideRepositories() throws {
        let pane = PaneController(label: "Ordinary Test", directory: ordinary)
        _ = pane.view
        try eventually { pane.entries.contains { $0.name == "ordinary.txt" } }
        let column = try gitColumn(pane)
        XCTAssertTrue(column.isHidden)
        pane.setBriefListing(true)
        pane.setBriefListing(false)
        XCTAssertFalse(pane.isBriefListing)
        XCTAssertTrue(column.isHidden)
    }

    func testGitControlsKeepADedicatedRowAndWorkingActionsAsPanelResizes() throws {
        let pane = PaneController(label: "Layout Test", directory: repository)
        pane.view.frame = NSRect(x: 0, y: 0, width: 1500, height: 600)
        let column = try gitColumn(pane)
        try eventually { pane.entries.contains { $0.name == "clean.txt" } && !column.isHidden }
        let branch = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("openGit") })
        let group = try XCTUnwrap(branch.superview as? NSStackView)
        let filter = try XCTUnwrap(group.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
        let watch = try XCTUnwrap(group.arrangedSubviews.compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("toggleWatched") })
        let listing = try XCTUnwrap(pane.table.enclosingScrollView)
        var openCount = 0
        pane.onOpenGit = { openCount += 1 }
        pane.view.layoutSubtreeIfNeeded()
        let initialPathY = pane.pathField.convert(pane.pathField.bounds, to: pane.view).midY
        let initialGitY = group.convert(group.bounds, to: pane.view).midY
        let initialListingTop = listing.convert(listing.bounds, to: pane.view).maxY

        for width: CGFloat in [1500, 400, 1500, 320, 1500] {
            pane.view.setFrameSize(NSSize(width: width, height: 600))
            pane.view.layoutSubtreeIfNeeded()
            let pathFrame = pane.pathField.convert(pane.pathField.bounds, to: pane.view)
            let gitFrame = group.convert(group.bounds, to: pane.view)
            let listingFrame = listing.convert(listing.bounds, to: pane.view)
            XCTAssertFalse(group.isHidden)
            XCTAssertGreaterThanOrEqual(pathFrame.width, 180)
            XCTAssertEqual(group.arrangedSubviews.count, 3)
            XCTAssertLessThanOrEqual(gitFrame.maxY, pathFrame.minY)
            XCTAssertEqual(pathFrame.midY, initialPathY, accuracy: 1)
            XCTAssertEqual(gitFrame.midY, initialGitY, accuracy: 1)
            XCTAssertEqual(listingFrame.maxY, initialListingTop, accuracy: 1)
            XCTAssertLessThanOrEqual(listingFrame.maxY, gitFrame.minY)
            for control in group.arrangedSubviews {
                let frame = control.convert(control.bounds, to: pane.view)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width)
            }
            let previousOpenCount = openCount
            XCTAssertTrue(branch.sendAction(branch.action, to: branch.target))
            XCTAssertEqual(openCount, previousOpenCount + 1)
            filter.selectItem(withTitle: GitFileFilter.changed.title)
            XCTAssertTrue(filter.sendAction(filter.action, to: filter.target))
            XCTAssertEqual(pane.entries.map(\.name), ["..", "changed.txt", "new.txt"])
            pane.setGitFilter(.all)
            let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == "clean.txt" })
            pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertTrue(watch.isEnabled)
            let wasWatched = GitWatchStore().paths(in: repository).contains("clean.txt")
            XCTAssertTrue(watch.sendAction(watch.action, to: watch.target))
            XCTAssertEqual(GitWatchStore().paths(in: repository).contains("clean.txt"), !wasWatched)
        }

        pane.setMode(.info)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.isHidden)
        pane.setMode(.listing)
        pane.navigate(to: ordinary)
        try eventually { pane.directory == self.ordinary && column.isHidden }
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.isHidden)
        XCTAssertEqual(listing.convert(listing.bounds, to: pane.view).maxY, 552, accuracy: 1)
    }

    func testBranchAndPathLengthNeverMoveTheGitRowOrListing() throws {
        let pane = PaneController(label: "Long Branch Test", directory: repository)
        pane.view.frame = NSRect(x: 0, y: 0, width: 1500, height: 600)
        let column = try gitColumn(pane)
        try eventually { !column.isHidden }
        let branch = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("openGit") })
        let group = try XCTUnwrap(branch.superview)
        let listing = try XCTUnwrap(pane.table.enclosingScrollView)
        pane.view.layoutSubtreeIfNeeded()
        let initialPathY = pane.pathField.convert(pane.pathField.bounds, to: pane.view).midY
        let initialGitY = group.convert(group.bounds, to: pane.view).midY
        let initialListingTop = listing.convert(listing.bounds, to: pane.view).maxY
        func assertStableHeader(file: StaticString = #filePath, line: UInt = #line) {
            pane.view.layoutSubtreeIfNeeded()
            let pathFrame = pane.pathField.convert(pane.pathField.bounds, to: pane.view)
            let gitFrame = group.convert(group.bounds, to: pane.view)
            let branchFrame = branch.convert(branch.bounds, to: pane.view)
            XCTAssertFalse(group.isHidden, file: file, line: line)
            XCTAssertEqual(pathFrame.midY, initialPathY, accuracy: 1, file: file, line: line)
            XCTAssertEqual(gitFrame.midY, initialGitY, accuracy: 1, file: file, line: line)
            XCTAssertEqual(listing.convert(listing.bounds, to: pane.view).maxY,
                           initialListingTop, accuracy: 1, file: file, line: line)
            XCTAssertLessThanOrEqual(gitFrame.maxY, pathFrame.minY, file: file, line: line)
            XCTAssertGreaterThan(branchFrame.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(branchFrame.minX, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(branchFrame.maxX, pane.view.bounds.width, file: file, line: line)
        }
        assertStableHeader()

        let longBranch = "feature/" + String(repeating: "long-branch-name-", count: 12) + "end"
        try git(["checkout", "-b", longBranch])
        pane.refresh()
        try eventually { branch.title.contains(longBranch) }
        assertStableHeader()

        try git(["checkout", "main"])
        pane.refresh()
        try eventually { branch.title.hasPrefix("main ·") }
        assertStableHeader()

        for width: CGFloat in [320, 700, 1500] {
            pane.view.setFrameSize(NSSize(width: width, height: 600))
            for path in ["/tmp", "/" + String(repeating: "long-directory-name/", count: 20)] {
                pane.pathField.stringValue = path
                pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: pane.pathField))
                assertStableHeader()
                XCTAssertGreaterThanOrEqual(pane.pathField.bounds.width, 180)
            }
        }
        var opened = false
        pane.onOpenGit = { opened = true }
        XCTAssertTrue(branch.sendAction(branch.action, to: branch.target))
        XCTAssertTrue(opened)
    }

    func testNewerNavigationKeepsOrdinaryListingWhenInitialRepositoryReadFinishes() throws {
        let pane = PaneController(label: "Navigation Test", directory: repository)
        _ = pane.view
        pane.setGitFilter(.changed)
        pane.navigate(to: ordinary)
        try eventually { pane.directory == self.ordinary && pane.entries.contains { $0.name == "ordinary.txt" } }
        XCTAssertEqual(pane.entries.map(\.name), ["..", "ordinary.txt"])
        XCTAssertTrue(try gitColumn(pane).isHidden)
        XCTAssertFalse(pane.entries.contains { $0.name == "changed.txt" })
    }

    func testWatchButtonPersistsSelectionAndDrivesWatchedFilter() throws {
        let pane = PaneController(label: "Watch Test", directory: repository)
        _ = pane.view
        let column = try gitColumn(pane)
        try eventually { !column.isHidden && pane.entries.contains { $0.name == "clean.txt" } }
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == "clean.txt" })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let button = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("toggleWatched") })
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
        XCTAssertEqual(GitWatchStore().paths(in: repository), ["clean.txt"])
        pane.setGitFilter(.watched)
        XCTAssertEqual(pane.entries.map(\.name), ["..", "clean.txt"])
        let cell = try XCTUnwrap(pane.tableView(pane.table, viewFor: column, row: 1) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.stringValue, "★")
    }

    func testWorkspaceLoadsFilesAndHistoryWithoutShowingWindow() throws {
        let workspace = GitWorkspace(repository: try GitRepository(directory: repository), selectedFile: nil)
        defer { workspace.close() }
        let window = try XCTUnwrap(workspace.window)
        XCTAssertFalse(window.isVisible)
        let content = try XCTUnwrap(window.contentView)
        let views = descendants(of: content)
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }.first)
        let mode = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 3 })
        let filter = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("Watched") })
        let branch = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Branch oder Tag" })
        workspace.reload()
        try eventually { branch.itemTitles.contains { $0.contains("main") } && table.isEnabled && table.numberOfRows == 2 }
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(filter.titleOfSelectedItem, "Changed")
        filter.selectItem(withTitle: "Tracked")
        XCTAssertTrue(filter.sendAction(filter.action, to: filter.target))
        XCTAssertEqual(table.numberOfRows, 2)

        mode.selectedSegment = 1
        XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.tableColumns.first?.title, "Commit")
        let message = workspace.tableView(table, viewFor: table.tableColumns[1], row: 0) as? NSTextField
        XCTAssertTrue(message?.stringValue.contains("Initial test version") == true)
        let preview = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        try eventually { preview.string.contains("Initial test version") }
        XCTAssertFalse(window.isVisible)
    }

    func testWorkspaceFillsWindowWhenResizingAndChangingModes() throws {
        let workspace = GitWorkspace(repository: try GitRepository(directory: repository), selectedFile: nil)
        defer { workspace.close() }
        let window = try XCTUnwrap(workspace.window)
        let content = try XCTUnwrap(window.contentView)
        let root = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first)
        let split = try XCTUnwrap(root.arrangedSubviews.compactMap { $0 as? NSSplitView }.first)
        let footer = try XCTUnwrap(root.arrangedSubviews.last)
        let mode = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSSegmentedControl }
            .first { $0.segmentCount == 3 })
        let presentation = try XCTUnwrap(descendants(of: root).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Diff-Darstellung" })
        presentation.selectedSegment = 1
        XCTAssertTrue(presentation.sendAction(presentation.action, to: presentation.target))

        for size in [NSSize(width: 1080, height: 760), NSSize(width: 1400, height: 1000), NSSize(width: 850, height: 580)] {
            window.setContentSize(size)
            for selectedMode in 0...2 {
                mode.selectedSegment = selectedMode
                XCTAssertTrue(mode.sendAction(mode.action, to: mode.target))
                content.layoutSubtreeIfNeeded()
                let rootFrame = root.convert(root.bounds, to: content)
                let footerFrame = footer.convert(footer.bounds, to: content)
                XCTAssertEqual(footerFrame.minY, rootFrame.minY, accuracy: 1)
                XCTAssertEqual(split.frame.width, root.bounds.width, accuracy: 1)
                XCTAssertGreaterThan(split.frame.height, 300)
                XCTAssertEqual(split.arrangedSubviews.reduce(split.dividerThickness) { $0 + $1.frame.height },
                               split.bounds.height, accuracy: 1)
                XCTAssertGreaterThanOrEqual(split.arrangedSubviews[0].frame.height, 120)
                XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.height, 140)
            }
        }

        window.setContentSize(NSSize(width: 1080, height: 900))
        content.layoutSubtreeIfNeeded()
        split.setPosition(160, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        let firstHeight = split.arrangedSubviews[0].frame.height
        split.setPosition(300, ofDividerAt: 0)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(abs(split.arrangedSubviews[0].frame.height - firstHeight), 100)
        XCTAssertFalse(window.isVisible)
    }

    func testWorkspaceSwitchesDiffPresentationForWorkingStagedUntrackedHistoryAndStash() throws {
        let workspace = GitWorkspace(repository: try GitRepository(directory: repository), selectedFile: nil)
        defer { workspace.close() }
        let window = try XCTUnwrap(workspace.window)
        let views = descendants(of: try XCTUnwrap(window.contentView))
        let table = try XCTUnwrap(views.compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Git-Dateien, Versionen und Stashes" })
        let unified = try XCTUnwrap(views.compactMap { $0 as? NSTextView }
            .first { $0.accessibilityLabel() == "Git-Diff und Versionsvorschau" })
        let before = try XCTUnwrap(views.compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Git-Diff: Vorher" })
        let after = try XCTUnwrap(views.compactMap { $0 as? NSTableView }
            .first { $0.accessibilityLabel() == "Git-Diff: Nachher" })
        func selector(_ label: String) throws -> NSSegmentedControl {
            try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first { $0.accessibilityLabel() == label })
        }
        func choose(_ control: NSSegmentedControl, _ index: Int) {
            control.selectedSegment = index
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
        }
        func texts(in table: NSTableView) -> [String] {
            guard let column = table.tableColumns.last else { return [] }
            return (0..<table.numberOfRows).compactMap { row in
                guard let cell = table.delegate?.tableView?(table, viewFor: column, row: row) else { return nil }
                return (cell as? NSTextField)?.stringValue
                    ?? (cell as? NSTableCellView)?.textField?.stringValue
            }
        }
        let presentation = try selector("Diff-Darstellung")
        let source = try selector("Diff von Arbeitskopie oder Index")
        let mode = try selector("Git-Ansicht")
        workspace.reload()
        try eventually { unified.string.contains("+modified") }
        let workingPatch = unified.string
        choose(presentation, 1)
        XCTAssertEqual(unified.string, workingPatch)
        XCTAssertTrue(texts(in: before).contains("initial"))
        XCTAssertTrue(texts(in: after).contains("modified"))
        XCTAssertEqual(before.numberOfRows, after.numberOfRows)
        choose(presentation, 0)
        XCTAssertEqual(unified.string, workingPatch)
        choose(presentation, 1)

        try git(["add", "--", "changed.txt"])
        workspace.reload()
        try eventually { table.isEnabled }
        choose(source, 1)
        try eventually { unified.string.contains("+modified") }
        XCTAssertTrue(texts(in: before).contains("initial"))
        XCTAssertTrue(texts(in: after).contains("modified"))
        choose(source, 0)
        let newRow = try XCTUnwrap((0..<table.numberOfRows).first { row in
            (workspace.tableView(table, viewFor: table.tableColumns[1], row: row) as? NSTextField)?.stringValue == "new.txt"
        })
        table.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
        try eventually { unified.string.contains("/dev/null") && unified.string.contains("+new") }
        XCTAssertFalse(texts(in: before).contains("new"))
        XCTAssertTrue(texts(in: after).contains("new"))

        choose(mode, 1)
        try eventually { unified.string.contains("Initial test version") }
        XCTAssertTrue(texts(in: after).contains("initial"))
        XCTAssertEqual(presentation.selectedSegment, 1)

        try git(["stash", "push", "-u", "-m", "Side-by-side stash"])
        workspace.reload()
        try eventually { table.isEnabled }
        choose(mode, 2)
        try eventually { unified.string.contains("Side-by-side stash") }
        XCTAssertTrue(texts(in: after).contains("modified"))
        XCTAssertEqual(before.numberOfRows, after.numberOfRows)
        XCTAssertEqual(presentation.selectedSegment, 1)
        XCTAssertFalse(window.isVisible)
    }
}
