import XCTest
@testable import PaneRookCore

final class GitRepositoryStoreTests: XCTestCase {
    private struct Archive: Codable {
        let version: Int
        let repositories: [VisitedGitRepository]
    }
    private let key = "PaneRook.visitedGitRepositories"
    private var suite: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        suite = "PaneRookGitRepositoryStoreTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookGitStore-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try fm.removeItem(at: root)
    }

    private func info(_ name: String, worktree: String = "main", branch: String = "main") -> GitRepositoryInfo {
        let common = root.appendingPathComponent(name + "/.git", isDirectory: true)
        let main = root.appendingPathComponent(name + "/main", isDirectory: true)
        let feature = root.appendingPathComponent(name + "/feature", isDirectory: true)
        return GitRepositoryInfo(commonDirectory: common,
            worktreeRoot: worktree == "main" ? main : feature,
            worktrees: [GitWorktree(url: main, branch: "main"), GitWorktree(url: feature, branch: branch)])
    }

    private func visited(_ info: GitRepositoryInfo, at date: Date) -> VisitedGitRepository {
        VisitedGitRepository(commonDirectory: info.commonDirectory, lastVisitedWorktree: info.worktreeRoot,
            worktrees: info.worktrees, lastVisitedAt: date)
    }

    func testVisitsSurviveReloadAndKeepOfflinePathsAndWorktreeDetails() throws {
        let store = GitRepositoryStore(defaults: defaults)
        let repository = info("offline", worktree: "feature", branch: "topic")
        let date = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(try store.repositories().isEmpty)
        try store.record(repository, at: date)
        let reloaded = GitRepositoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(try reloaded.repositories(), [visited(repository, at: date)])
        XCTAssertFalse(fm.fileExists(atPath: repository.worktreeRoot.path))
    }

    func testVisitsGroupWorktreesAndSortRepositoriesByActualVisitTime() throws {
        let store = GitRepositoryStore(defaults: defaults)
        try store.record(info("first"), at: Date(timeIntervalSince1970: 100))
        try store.record(info("second"), at: Date(timeIntervalSince1970: 200))
        try store.record(info("first", worktree: "feature", branch: "topic"), at: Date(timeIntervalSince1970: 300))
        let values = try store.repositories()
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.map { $0.commonDirectory.deletingLastPathComponent().lastPathComponent }, ["first", "second"])
        XCTAssertEqual(values.first?.lastVisitedWorktree, info("first", worktree: "feature").worktreeRoot)
        XCTAssertEqual(values.first?.worktrees.last?.branch, "topic")
    }

    func testRefreshPreservesLastVisitAndDoesNotRegisterUnknownRepositories() throws {
        let store = GitRepositoryStore(defaults: defaults)
        let original = info("first", worktree: "feature")
        let date = Date(timeIntervalSince1970: 100)
        try store.record(original, at: date)
        let changed = GitRepositoryInfo(commonDirectory: original.commonDirectory, worktreeRoot: original.worktrees[0].url,
            worktrees: [GitWorktree(url: original.worktrees[0].url, branch: nil, isLocked: true)])
        try store.update(changed)
        try store.update(info("unknown"))
        let values = try store.repositories()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.lastVisitedAt, date)
        XCTAssertEqual(values.first?.lastVisitedWorktree, original.worktreeRoot)
        XCTAssertEqual(values.first?.worktrees, changed.worktrees)
    }

    func testCanonicalPathsDeduplicateSymlinkAliasesAndRemovalUsesRepositoryIdentity() throws {
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        try fm.createDirectory(at: physical.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: physical)
        let store = GitRepositoryStore(defaults: defaults)
        try store.record(GitRepositoryInfo(commonDirectory: physical.appendingPathComponent(".git"),
            worktreeRoot: physical, worktrees: [GitWorktree(url: physical, branch: "main")]))
        let aliased = GitRepositoryInfo(commonDirectory: alias.appendingPathComponent(".git/./", isDirectory: true),
            worktreeRoot: alias, worktrees: [GitWorktree(url: alias, branch: "main"), GitWorktree(url: physical, branch: "main")])
        try store.record(aliased)
        let values = try store.repositories()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.worktrees.count, 1)
        XCTAssertEqual(values.first?.lastVisitedWorktree.path, physical.path)
        try store.remove(commonDirectory: alias.appendingPathComponent(".git"))
        XCTAssertTrue(try store.repositories().isEmpty)
    }

    func testDuplicateStoredRepositoriesPreferNewestSnapshotWithoutMutatingOnRead() throws {
        let old = visited(info("same"), at: Date(timeIntervalSince1970: 100))
        let new = visited(info("same", worktree: "feature", branch: "updated"), at: Date(timeIntervalSince1970: 200))
        let lexicalAlias = VisitedGitRepository(commonDirectory: new.commonDirectory.appendingPathComponent("./", isDirectory: true),
            lastVisitedWorktree: new.lastVisitedWorktree, worktrees: new.worktrees, lastVisitedAt: new.lastVisitedAt)
        let data = try JSONEncoder().encode(Archive(version: 1, repositories: [old, lexicalAlias, old]))
        defaults.set(data, forKey: key)
        XCTAssertEqual(try GitRepositoryStore(defaults: defaults).repositories(), [new])
        XCTAssertEqual(defaults.data(forKey: key), data)
    }

    func testTrustedSnapshotsCanBeReadAndWrittenWithoutFollowingFilesystemSymlinks() throws {
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        try fm.createDirectory(at: physical.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: physical)
        let stored = VisitedGitRepository(commonDirectory: alias.appendingPathComponent(".git", isDirectory: true),
            lastVisitedWorktree: alias, worktrees: [GitWorktree(url: alias, branch: "main")], lastVisitedAt: Date())
        defaults.set(try JSONEncoder().encode(Archive(version: 1, repositories: [stored])), forKey: key)
        let store = GitRepositoryStore(defaults: defaults)
        XCTAssertEqual(try store.repositories(), [stored])
        let snapshot = GitRepositoryInfo(commonDirectory: stored.commonDirectory,
            worktreeRoot: alias, worktrees: stored.worktrees)
        try store.record(snapshot, at: stored.lastVisitedAt, canonicalizePaths: false)
        XCTAssertEqual(try store.repositories(), [stored])
        try store.update(snapshot, canonicalizePaths: false)
        XCTAssertEqual(try store.repositories(), [stored])
        try store.remove(commonDirectory: snapshot.commonDirectory, canonicalizePaths: false)
        XCTAssertTrue(try store.repositories().isEmpty)
    }

    func testRepositoryHistoryIsBoundedAndEvictsOldestVisits() throws {
        let history = (0...100).map { visited(info("repo-\($0)"), at: Date(timeIntervalSince1970: Double($0))) }
        defaults.set(try JSONEncoder().encode(Archive(version: 1, repositories: history)), forKey: key)
        let store = GitRepositoryStore(defaults: defaults)
        XCTAssertEqual(try store.repositories().count, 100)
        XCTAssertEqual(try store.repositories().first?.lastVisitedAt, Date(timeIntervalSince1970: 100))
        try store.record(info("newest"), at: Date(timeIntervalSince1970: 200))
        let values = try store.repositories()
        XCTAssertEqual(values.count, 100)
        XCTAssertEqual(values.first?.commonDirectory, info("newest").commonDirectory)
        XCTAssertEqual(values.last?.lastVisitedAt, Date(timeIntervalSince1970: 2))
        let encoded = try XCTUnwrap(defaults.data(forKey: key))
        XCTAssertEqual(try JSONDecoder().decode(Archive.self, from: encoded).repositories.count, 100)
    }

    func testCorruptAndUnsupportedPreferencesAreNeverOverwrittenByMutations() throws {
        let valid = info("valid")
        let remote = VisitedGitRepository(commonDirectory: URL(string: "https://example.invalid/repository")!,
            lastVisitedWorktree: valid.worktreeRoot, worktrees: valid.worktrees, lastVisitedAt: Date())
        let objects: [Any] = [42, Data("invalid JSON".utf8),
            try JSONEncoder().encode(Archive(version: 2, repositories: [])),
            try JSONEncoder().encode(Archive(version: 1, repositories: [remote]))]
        for object in objects {
            defaults.set(object, forKey: key)
            let store = GitRepositoryStore(defaults: defaults)
            XCTAssertThrowsError(try store.repositories())
            XCTAssertThrowsError(try store.record(valid))
            XCTAssertThrowsError(try store.update(valid))
            XCTAssertThrowsError(try store.remove(commonDirectory: valid.commonDirectory))
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, object as? NSObject)
        }
    }

    func testInvalidNewRepositoryCannotReplaceExistingHistory() throws {
        let store = GitRepositoryStore(defaults: defaults)
        let valid = info("valid")
        try store.record(valid)
        let before = defaults.data(forKey: key)
        for url in [URL(string: "sftp://example.invalid/repo")!, URL(fileURLWithPath: "/nul\0path")] {
            XCTAssertThrowsError(try store.record(GitRepositoryInfo(commonDirectory: url,
                worktreeRoot: valid.worktreeRoot, worktrees: valid.worktrees)))
        }
        XCTAssertThrowsError(try store.record(valid, at: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(defaults.data(forKey: key), before)
    }
}
