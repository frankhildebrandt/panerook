import Foundation
import PaneRookCore
import PaneRookPanels
import XCTest

final class PanelStateTests: XCTestCase {
    func testStaleNavigationCannotReplaceNewerListingOrHistory() {
        let start = URL(fileURLWithPath: "/start")
        let newest = URL(fileURLWithPath: "/newest")
        var state = PanelState(directory: start)
        let old = state.beginNavigation()
        let new = state.beginNavigation()
        XCTAssertTrue(
            state.completeNavigation(new, to: newest, files: [], recordHistory: true, preserveDirectorySizes: false))
        XCTAssertFalse(
            state.completeNavigation(
                old, to: URL(fileURLWithPath: "/old"), files: [], recordHistory: true, preserveDirectorySizes: false))
        XCTAssertEqual(state.directory, newest)
        XCTAssertEqual(state.history, [start])
        XCTAssertFalse(state.failNavigation(old))
    }
    func testSearchResultsInvalidateNavigationAndRejectTaskRefresh() {
        let directory = URL(fileURLWithPath: "/start")
        var state = PanelState(directory: directory)
        let request = state.beginNavigation()
        state.showResults([])
        XCTAssertFalse(
            state.completeNavigation(
                request, to: directory, files: [], recordHistory: false, preserveDirectorySizes: false))
        XCTAssertFalse(state.canApplyTaskResult(in: directory))
        XCTAssertFalse(state.loading)
    }
    func testTaskResultMustMatchDirectoryAndListingMode() {
        let directory = URL(fileURLWithPath: "/start")
        var state = PanelState(directory: directory)
        XCTAssertTrue(state.canApplyTaskResult(in: directory))
        XCTAssertFalse(state.canApplyTaskResult(in: URL(fileURLWithPath: "/other")))
        state.mode = .network
        XCTAssertFalse(state.canApplyTaskResult(in: directory))
        state.mode = .listing
        _ = state.beginNavigation()
        XCTAssertFalse(state.canApplyTaskResult(in: directory))
    }
    func testFilteringAndDescendingSortKeepParentAndDirectoriesFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder"), withIntermediateDirectories: false)
        for name in ["a.txt", "z.txt", "hidden.png"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        var state = PanelState(directory: directory)
        state.filterPattern = "*.txt"
        state.sortAscending = false
        let request = state.beginNavigation()
        XCTAssertTrue(
            state.completeNavigation(
                request, to: directory, files: try FileSystem.list(directory, showHidden: false),
                recordHistory: false, preserveDirectorySizes: false))
        XCTAssertEqual(state.entries.map(\.name), ["..", "folder", "z.txt", "a.txt"])
        XCTAssertTrue(state.history.isEmpty)
    }

    func testFailedNavigationLeavesDirectoryAndHistoryIntact() {
        let directory = URL(fileURLWithPath: "/start")
        var state = PanelState(directory: directory)
        let request = state.beginNavigation()
        XCTAssertTrue(state.failNavigation(request))
        XCTAssertEqual(state.directory, directory)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertFalse(state.loading)
        XCTAssertTrue(state.canApplyTaskResult(in: directory))
    }

    func testGitStatusesFollowListingGenerationAndSurviveFiltering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = directory.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("file.txt"))
        let files = try FileSystem.list(directory, showHidden: false)
        let repositoryURL = try XCTUnwrap(files.first { $0.isDirectory }?.url)
        let fileURL = try XCTUnwrap(files.first { !$0.isDirectory }?.url)
        var state = PanelState(directory: directory)
        let first = state.beginNavigation()
        XCTAssertTrue(state.completeNavigation(first, to: directory, files: files,
            recordHistory: false, preserveDirectorySizes: false))
        let status = GitRepositoryStatus(branch: "main", modifiedCount: 1)
        XCTAssertFalse(state.applyGitStatus(status, for: fileURL, request: first))
        XCTAssertFalse(state.applyGitStatus(status, for: directory.deletingLastPathComponent(), request: first))
        XCTAssertTrue(state.applyGitStatus(status, for: repositoryURL, request: first))
        state.filterPattern = "*.png"
        state.sortAscending = false
        state.filterAndSort()
        XCTAssertEqual(state.gitStatuses[repositoryURL], status)
        XCTAssertTrue(state.entries.contains { $0.url == repositoryURL })

        let refresh = state.beginNavigation()
        XCTAssertFalse(state.applyGitStatus(status, for: repositoryURL, request: first))
        XCTAssertFalse(state.applyGitStatus(status, for: repositoryURL, request: refresh))
        XCTAssertTrue(state.completeNavigation(refresh, to: directory, files: files,
            recordHistory: false, preserveDirectorySizes: true))
        XCTAssertTrue(state.gitStatuses.isEmpty)
        XCTAssertFalse(state.applyGitStatus(status, for: repositoryURL, request: first))
        XCTAssertTrue(state.applyGitStatus(status, for: repositoryURL, request: refresh))
        state.showResults(files)
        XCTAssertTrue(state.gitStatuses.isEmpty)
        XCTAssertFalse(state.applyGitStatus(status, for: repositoryURL, request: refresh))
    }

}
