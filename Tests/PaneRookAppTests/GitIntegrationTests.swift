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
}
