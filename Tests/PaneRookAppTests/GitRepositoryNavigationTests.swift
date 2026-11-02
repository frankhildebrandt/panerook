import AppKit
import PaneRookCore
import PaneRookRemote
import XCTest

@testable import PaneRookApp

final class GitRepositoryNavigationTests: XCTestCase {
    private final class Host: FavoritesHost {
        var activePane: any PanelAccess
        var presentationWindow: NSWindow? { nil }
        var canUseMenus: Bool { true }
        var isPerformingOperation: Bool { false }
        var errors: [String] = []
        init(pane: any PanelAccess) { activePane = pane }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func showError(_ error: Error, detail: String) { errors.append(error.localizedDescription) }
        func showConnectionArchive(pane: any PanelAccess) {}
        func savedBookmarks() throws -> [ConnectionBookmark] { [] }
        func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess) {}
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "-c", "user.name=PaneRook Tests", "-c", "user.email=tests@panerook.invalid"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10)
    }

    private func choose(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    func testVisitsPersistAndWorktreeMenuNavigatesTheOriginatingPanel() throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("project", isDirectory: true)
        let nested = repository.appendingPathComponent("Sources", isDirectory: true)
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let ordinary = root.appendingPathComponent("ordinary", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.createDirectory(at: ordinary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try git(["init", "--initial-branch=main"], in: repository)
        try git(["commit", "--allow-empty", "-m", "Fixture"], in: repository)
        try git(["worktree", "add", "-b", "feature", worktree.path], in: repository)

        let suite = "PaneRookGitNavigation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults))
        let left = PaneController(label: "Left", directory: nested)
        let right = PaneController(label: "Right", directory: ordinary)
        left.onRepositoryVisited = { catalog.record($0) }
        _ = left.view
        _ = right.view
        waitUntil { left.gitRepository != nil && catalog.repositories().count == 1 }
        XCTAssertEqual(catalog.repositories().first?.lastVisitedWorktree, repository)
        XCTAssertEqual(catalog.repositories().first?.worktrees.count, 2)

        let host = Host(pane: right)
        let controller = PanelFavoritesController(owner: host, pane: left, cache: FavoriteDestinationCache(), repositories: catalog)
        let favorites = try XCTUnwrap(left.favoritesButton.menu)
        controller.menuNeedsUpdate(favorites)
        let menu = try XCTUnwrap(favorites.items.first { $0.title == "Git-Repositories" }?.submenu)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.first { $0.toolTip == repository.path }?.state, .on)
        let feature = try XCTUnwrap(menu.items.first { $0.toolTip == worktree.path })
        XCTAssertTrue(controller.validateMenuItem(feature))
        try choose(feature)
        waitUntil { left.directory == worktree && left.gitRepository?.worktreeRoot == worktree }
        XCTAssertEqual(right.directory, ordinary)
        XCTAssertTrue(host.activePane === left)
        XCTAssertEqual(catalog.repositories().count, 1)
        XCTAssertEqual(catalog.repositories().first?.lastVisitedWorktree, worktree)

        // A fresh catalog models a new app session, with no current Git directory.
        let restored = GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults))
        let otherMenuController = PanelFavoritesController(owner: host, pane: right,
            cache: FavoriteDestinationCache(), repositories: restored)
        let otherFavorites = try XCTUnwrap(right.favoritesButton.menu)
        otherMenuController.menuNeedsUpdate(otherFavorites)
        let savedMenu = try XCTUnwrap(otherFavorites.items.first { $0.title == "Git-Repositories" }?.submenu)
        otherMenuController.menuNeedsUpdate(savedMenu)
        let group = try XCTUnwrap(savedMenu.items.first { $0.title == "project" }?.submenu)
        let main = try XCTUnwrap(group.items.first { $0.toolTip == repository.path })
        try choose(main)
        waitUntil { right.directory == repository && right.gitRepository?.worktreeRoot == repository }
        XCTAssertEqual(left.directory, worktree)
        XCTAssertTrue(host.activePane === right)
        XCTAssertTrue(host.errors.isEmpty)

        let remove = try XCTUnwrap(group.items.first { $0.title == "Aus Liste entfernen" })
        try choose(remove)
        waitUntil { restored.repositories().isEmpty }
    }

    func testBackgroundRefreshDiscoversNewWorktreesWithoutChangingVisitOrder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let repository = root.appendingPathComponent("project", isDirectory: true)
        try fm.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try git(["init", "--initial-branch=main"], in: repository)
        try git(["commit", "--allow-empty", "-m", "Fixture"], in: repository)
        let suite = "PaneRookGitRefresh-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults))
        catalog.record(try XCTUnwrap(GitRepositoryReader().repository(containing: repository)))
        let original = try XCTUnwrap(catalog.repositories().first)
        let added = root.appendingPathComponent("new-worktree", isDirectory: true)
        try git(["worktree", "add", "-b", "new", added.path], in: repository)
        catalog.refresh()
        waitUntil { !catalog.refreshing }
        let refreshed = try XCTUnwrap(catalog.repositories().first)
        XCTAssertEqual(refreshed.lastVisitedAt, original.lastVisitedAt)
        XCTAssertEqual(refreshed.lastVisitedWorktree, original.lastVisitedWorktree)
        XCTAssertTrue(refreshed.worktrees.contains { $0.url == added && $0.branch == "new" })
    }
}
