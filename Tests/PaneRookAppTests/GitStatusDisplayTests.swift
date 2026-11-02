import AppKit
import PaneRookCore
import XCTest

@testable import PaneRookApp

final class GitStatusDisplayTests: XCTestCase {
    func testStatusRemainsReadableWithoutColorAndExplainsDetails() {
        let clean = GitStatusPresentation(status: GitRepositoryStatus(branch: "main"))
        XCTAssertEqual(clean.text, "✓ main")
        XCTAssertTrue(clean.detail.contains("Arbeitsverzeichnis sauber"))

        let dirty = GitStatusPresentation(status: GitRepositoryStatus(branch: "feature", stagedCount: 1,
            modifiedCount: 2, untrackedCount: 3, aheadCount: 4, behindCount: 5))
        XCTAssertEqual(dirty.text, "● feature ↑4 ↓5")
        for detail in ["1 zum Commit", "2 nicht vorgemerkte", "3 unversionierte", "4 Commits voraus", "5 Commits zurück"] {
            XCTAssertTrue(dirty.detail.contains(detail))
        }
        let conflicts = GitStatusPresentation(status: GitRepositoryStatus(branch: nil, conflictCount: 2))
        XCTAssertEqual(conflicts.text, "! HEAD")
        XCTAssertTrue(conflicts.detail.contains("Detached HEAD"))
        XCTAssertTrue(conflicts.detail.contains("2 Konflikte"))
    }

    func testParentListingLoadsGitBadgesAndRefreshesBriefListingWithoutLosingSelection() throws {
        _ = NSApplication.shared
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repositoryName = "project-with-a-very-long-directory-name"
        let repository = parent.appendingPathComponent(repositoryName)
        let ordinary = parent.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "--initial-branch=main", repository.path]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let pane = PaneController(label: "Test", directory: parent)
        _ = pane.view
        let column = try XCTUnwrap(pane.table.tableColumns.first)
        func badge(named name: String) -> GitStatusBadge? {
            guard let row = pane.entries.firstIndex(where: { $0.name == name }),
                  let cell = pane.tableView(pane.table, viewFor: column, row: row) else { return nil }
            return cell.subviews.compactMap { $0 as? GitStatusBadge }.first
        }
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            badge(named: repositoryName)?.stringValue == "✓ main"
        }, object: nil)
        wait(for: [loaded], timeout: 10)
        XCTAssertNil(badge(named: "ordinary"))
        XCTAssertNil(badge(named: ".."))
        XCTAssertEqual(pane.table.tableColumns.count, 3)

        let repositoryRow = try XCTUnwrap(pane.entries.firstIndex { $0.name == repositoryName })
        let narrowCell = try XCTUnwrap(pane.tableView(pane.table, viewFor: column, row: repositoryRow) as? NSTableCellView)
        narrowCell.frame = NSRect(x: 0, y: 0, width: 140, height: 29)
        narrowCell.layoutSubtreeIfNeeded()
        let narrowBadge = try XCTUnwrap(narrowCell.subviews.compactMap { $0 as? GitStatusBadge }.first)
        XCTAssertGreaterThan(narrowBadge.frame.width, 30)
        XCTAssertLessThanOrEqual(narrowBadge.frame.width, 70)
        XCTAssertGreaterThan(try XCTUnwrap(narrowCell.textField).frame.width, 20)

        pane.setBriefListing(true)
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == repositoryName })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try Data("new file".utf8).write(to: repository.appendingPathComponent("new.txt"))
        pane.refresh()
        let refreshed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            badge(named: repositoryName)?.stringValue == "● main"
        }, object: nil)
        wait(for: [refreshed], timeout: 10)
        XCTAssertTrue(pane.isBriefListing)
        XCTAssertTrue(badge(named: repositoryName)?.toolTip?.contains("1 unversionierte") == true)
        XCTAssertEqual(pane.selectedEntries.map(\.name), [repositoryName])
    }
}
