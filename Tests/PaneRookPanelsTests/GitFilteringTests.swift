import Foundation
import PaneRookCore
import PaneRookPanels
import XCTest

final class GitFilteringTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-git-filter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for folder in ["src", "src-old", "saved", "ignored", ".git"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        for file in ["src/changed.txt", "src/clean.txt", "src-old/other.txt", "saved/stashed.txt", "ignored/cache.txt",
                     "staged.txt", "new.txt", "conflict.txt", "clean.txt", "ignored.txt", ".git/index"] {
            try Data(file.utf8).write(to: directory.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func snapshot() -> GitSnapshot {
        GitSnapshot(root: directory, branch: "main", head: nil, upstream: nil, ahead: 0, behind: 0,
                    files: [
                        GitFileStatus(path: "src/changed.txt", originalPath: nil, indexStatus: " ", workTreeStatus: "M"),
                        GitFileStatus(path: "staged.txt", originalPath: nil, indexStatus: "A", workTreeStatus: " "),
                        GitFileStatus(path: "new.txt", originalPath: nil, indexStatus: "?", workTreeStatus: "?"),
                        GitFileStatus(path: "conflict.txt", originalPath: nil, indexStatus: "U", workTreeStatus: "U"),
                        GitFileStatus(path: "ignored.txt", originalPath: nil, indexStatus: "!", workTreeStatus: "!"),
                        GitFileStatus(path: "ignored/", originalPath: nil, indexStatus: "!", workTreeStatus: "!")
                    ], stashes: [], operation: nil,
                    trackedPaths: ["src/changed.txt", "src/clean.txt", "src-old/other.txt", "staged.txt", "conflict.txt", "clean.txt"],
                    stashedPaths: ["saved/stashed.txt"])
    }

    private func state(filter: GitFileFilter) throws -> PanelState {
        var state = PanelState(directory: directory)
        let request = state.beginNavigation()
        XCTAssertTrue(state.completeNavigation(request, to: directory,
                                               files: try FileSystem.list(directory, showHidden: true),
                                               recordHistory: false, preserveDirectorySizes: false))
        state.gitSnapshot = snapshot()
        state.gitFilter = filter
        state.filterAndSort()
        return state
    }

    func testStatusFiltersRetainParentAndOnlyRelevantDirectoryAncestors() throws {
        let changed = try state(filter: .changed).entries.map(\.name)
        XCTAssertTrue(changed.contains(".."))
        XCTAssertTrue(changed.contains("src"))
        XCTAssertFalse(changed.contains("src-old"))
        XCTAssertFalse(changed.contains(".git"))
        XCTAssertFalse(changed.contains("clean.txt"))
        XCTAssertEqual(try state(filter: .staged).entries.map(\.name), ["..", "staged.txt"])
        XCTAssertEqual(try state(filter: .untracked).entries.map(\.name), ["..", "new.txt"])
        XCTAssertEqual(try state(filter: .conflicted).entries.map(\.name), ["..", "conflict.txt"])
        XCTAssertEqual(try state(filter: .stashed).entries.map(\.name), ["..", "saved"])
        XCTAssertEqual(try state(filter: .ignored).entries.map(\.name), ["..", "ignored", "ignored.txt"])
    }

    func testTrackedIncludesCleanFilesAndFilenameMaskCombinesWithGitFilter() throws {
        var state = try state(filter: .tracked)
        XCTAssertTrue(state.entries.contains { $0.name == "clean.txt" })
        XCTAssertFalse(state.entries.contains { $0.name == "new.txt" })
        state.filterPattern = "stage*.txt"
        state.filterAndSort()
        XCTAssertEqual(state.entries.map(\.name), ["..", "src", "src-old", "staged.txt"])
    }

    func testWatchedDirectoriesIncludeDescendantsWithoutPrefixCollisions() throws {
        var state = try state(filter: .watched)
        state.watchedPaths = ["src"]
        state.filterAndSort()
        XCTAssertEqual(state.entries.map(\.name), ["..", "src"])
        let children = try FileSystem.list(directory.appendingPathComponent("src"), showHidden: true)
        XCTAssertEqual(GitFileFilter.watched.filter(children, snapshot: snapshot(), watchedPaths: ["src"]).count, 2)
        let old = try FileSystem.list(directory.appendingPathComponent("src-old"), showHidden: true)
        XCTAssertTrue(GitFileFilter.watched.filter(old, snapshot: snapshot(), watchedPaths: ["src"]).isEmpty)
        let clean = try XCTUnwrap(children.first { $0.name == "clean.txt" })
        XCTAssertEqual(GitPanelPaths.statusLabel(for: clean, snapshot: snapshot(), watchedPaths: ["src"]), "★")
    }

    func testNoRepositoryAndSearchResultsRemainVisibleWithAnActiveGitFilter() throws {
        var state = try state(filter: .staged)
        state.gitSnapshot = nil
        state.filterAndSort()
        XCTAssertTrue(state.entries.contains { $0.name == "clean.txt" })
        state.gitSnapshot = snapshot()
        state.showResults(try FileSystem.list(directory, showHidden: false))
        XCTAssertTrue(state.entries.contains { $0.name == "clean.txt" })
    }

    func testChangingDirectoryClearsSnapshotBeforeApplyingOldFilter() throws {
        var state = try state(filter: .staged)
        state.watchedPaths = ["src"]
        let child = directory.appendingPathComponent("src")
        let request = state.beginNavigation()
        XCTAssertTrue(state.completeNavigation(request, to: child, files: try FileSystem.list(child, showHidden: false),
                                               recordHistory: true, preserveDirectorySizes: false))
        XCTAssertNil(state.gitSnapshot)
        XCTAssertTrue(state.watchedPaths.isEmpty)
        XCTAssertTrue(state.entries.contains { $0.name == "clean.txt" })
    }

    func testPathNormalizationRetainsSymbolicLinkLeafAndRejectsOutsidePaths() throws {
        let link = directory.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("clean.txt"))
        XCTAssertEqual(GitPanelPaths.relativePath(for: link, in: directory), "linked.txt")
        let alias = directory.deletingLastPathComponent().appendingPathComponent("alias-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertEqual(GitPanelPaths.relativePath(for: alias.appendingPathComponent("clean.txt"), in: directory), "clean.txt")
        XCTAssertNil(GitPanelPaths.relativePath(for: directory.deletingLastPathComponent().appendingPathComponent("outside.txt"), in: directory))
    }

    func testWatchBookmarksPersistPerRepositoryAndIgnoreGitInternals() throws {
        let suite = "PaneRook-GitWatchTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = GitWatchStore(defaults: defaults)
        store.toggle(paths: ["src", "clean.txt", "../outside", ".git/index", "/absolute", ""], in: directory)
        XCTAssertEqual(store.paths(in: directory), ["src", "clean.txt"])
        let restored = GitWatchStore(defaults: defaults)
        XCTAssertEqual(restored.paths(in: directory), ["src", "clean.txt"])
        XCTAssertTrue(restored.paths(in: directory.appendingPathComponent("other-repository")).isEmpty)
        restored.toggle(paths: ["src", "src"], in: directory)
        XCTAssertEqual(restored.paths(in: directory), ["clean.txt"])
    }
}
