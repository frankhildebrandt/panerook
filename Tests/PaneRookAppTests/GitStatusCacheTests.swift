import Foundation
import PaneRookCore
import XCTest

@testable import PaneRookApp

final class GitStatusCacheTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let key = "PaneRook.gitStatusCache"
    private let root = URL(fileURLWithPath: "/repositories/project", isDirectory: true)

    override func setUpWithError() throws {
        suite = "PaneRookGitStatusCache-\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func header(root: URL? = nil, branch: String = "main") -> GitHeaderStatus {
        GitHeaderStatus(snapshot: GitSnapshot(root: root ?? self.root, branch: branch))
    }

    func testPersistedStatusAndHeaderContainOnlyDisplayData() throws {
        let cache = GitStatusCache(defaults: defaults)
        let status = GitRepositoryStatus(branch: "feature", stagedCount: 1, modifiedCount: 1,
                                         untrackedCount: 1, aheadCount: 2, behindCount: 3)
        cache.store(status, for: root)
        let snapshot = GitSnapshot(root: root, branch: "feature", ahead: 2, behind: 3, files: [
            GitFileStatus(path: "private-file-name.txt", indexStatus: "M", workTreeStatus: "M"),
            GitFileStatus(path: "new.txt", indexStatus: "?", workTreeStatus: "?"),
            GitFileStatus(path: "ignored.txt", indexStatus: "!", workTreeStatus: "!")
        ], stashes: [GitStash(id: "stash@{0}", objectID: "abc", subject: "private-stash-subject")],
        operation: "Merge", trackedPaths: ["private-file-name.txt"], stashedPaths: ["stashed-file.txt"])
        let display = GitHeaderStatus(snapshot: snapshot)
        cache.store(display, for: root)

        let restored = GitStatusCache(defaults: defaults)
        XCTAssertEqual(restored.status(for: root), status)
        let restoredHeader = try XCTUnwrap(restored.header(for: root))
        XCTAssertEqual(restoredHeader.title, "feature · 2 geändert ↑2 ↓3")
        XCTAssertEqual(restoredHeader.toolTip,
                       "\(root.path)\nfeature · 2 geändert · 1 Stashes · Merge\nGit öffnen: Branches, Status, Diffs und Versionen")
        XCTAssertEqual(header().title, "main · sauber")
        let encoded = String(decoding: try XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self)
        for omitted in ["private-file-name.txt", "private-stash-subject", "stashed-file.txt", "trackedPaths"] {
            XCTAssertFalse(encoded.contains(omitted))
        }
    }

    func testExactLexicalKeysReuseRootWithoutInferringDescendantRepositories() {
        let cache = GitStatusCache(defaults: defaults)
        let queried = root.appendingPathComponent("Sources/../Sources", isDirectory: true)
        let normalized = root.appendingPathComponent("Sources", isDirectory: true)
        cache.store(header(), for: queried)
        cache.store(GitRepositoryStatus(branch: "main"), for: queried)
        XCTAssertEqual(cache.header(for: normalized)?.branch, "main")
        XCTAssertEqual(cache.header(for: root)?.branch, "main")
        XCTAssertEqual(cache.status(for: normalized)?.branch, "main")
        XCTAssertNil(cache.status(for: root))
        XCTAssertNil(cache.header(for: normalized.appendingPathComponent("nested")))
        XCTAssertNil(cache.header(for: URL(fileURLWithPath: "/repositories/project-other")))
        XCTAssertNil(cache.header(for: URL(string: "https://example.invalid/repositories/project")!))
    }

    func testWorktreesKeepIndependentStatusesAndKnownAliasesReceiveFreshHeaders() {
        let cache = GitStatusCache(defaults: defaults)
        let worktree = URL(fileURLWithPath: "/repositories/worktree", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        cache.store(header(), for: sources)
        cache.store(header(root: worktree, branch: "feature"), for: worktree)
        cache.store(GitRepositoryStatus(branch: "main"), for: root)
        cache.store(GitRepositoryStatus(branch: "feature", modifiedCount: 1), for: worktree)
        cache.store(header(branch: "renamed"), for: root)
        XCTAssertEqual(cache.header(for: sources)?.branch, "renamed")
        XCTAssertEqual(cache.header(for: worktree)?.branch, "feature")
        XCTAssertEqual(cache.status(for: root)?.branch, "main")
        XCTAssertEqual(cache.status(for: worktree)?.modifiedCount, 1)
    }

    func testNilResultsRemoveOnlyTheirKindAndRootInvalidationRemovesKnownAliases() {
        let cache = GitStatusCache(defaults: defaults)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let tests = root.appendingPathComponent("Tests", isDirectory: true)
        let other = URL(fileURLWithPath: "/repositories/other", isDirectory: true)
        cache.store(header(), for: sources)
        cache.store(header(), for: tests)
        cache.store(header(root: other, branch: "other"), for: other)
        cache.store(GitRepositoryStatus(branch: "main"), for: root)
        cache.store(nil as GitRepositoryStatus?, for: root)
        XCTAssertNil(cache.status(for: root))
        XCTAssertNotNil(cache.header(for: root))

        cache.store(nil as GitHeaderStatus?, for: sources)
        XCTAssertNil(cache.header(for: sources))
        XCTAssertNotNil(cache.header(for: tests))
        XCTAssertNotNil(cache.header(for: root))
        cache.store(GitRepositoryStatus(branch: "main"), for: root)
        cache.store(nil as GitHeaderStatus?, for: root)
        XCTAssertNil(cache.header(for: root))
        XCTAssertNil(cache.header(for: tests))
        XCTAssertNotNil(cache.status(for: root))
        XCTAssertEqual(cache.header(for: other)?.branch, "other")

        let restored = GitStatusCache(defaults: defaults)
        XCTAssertNil(restored.header(for: root))
        XCTAssertNil(restored.header(for: tests))
        XCTAssertNotNil(restored.status(for: root))
        XCTAssertEqual(restored.header(for: other)?.branch, "other")
    }

    func testOldestWritesAreEvictedAndLimitAlsoAppliesWhenLoading() {
        let cache = GitStatusCache(defaults: defaults, limit: 2)
        let second = root.appendingPathComponent("second")
        let third = root.appendingPathComponent("third")
        cache.store(GitRepositoryStatus(branch: "first"), for: root)
        cache.store(GitRepositoryStatus(branch: "second"), for: second)
        cache.store(GitRepositoryStatus(branch: "first-updated"), for: root)
        cache.store(GitRepositoryStatus(branch: "third"), for: third)
        XCTAssertNil(cache.status(for: second))
        XCTAssertEqual(cache.status(for: root)?.branch, "first-updated")
        XCTAssertEqual(cache.status(for: third)?.branch, "third")
        let restored = GitStatusCache(defaults: defaults, limit: 1)
        XCTAssertNil(restored.status(for: root))
        XCTAssertEqual(restored.status(for: third)?.branch, "third")
    }

    func testCorruptAndUnsupportedArchivesAreIgnoredAndReplaceable() throws {
        for data in [Data("not json".utf8), Data("{\"version\":2,\"entries\":[]}".utf8),
                     Data("{\"version\":1,\"entries\":[{}]}".utf8)] {
            defaults.set(data, forKey: key)
            let cache = GitStatusCache(defaults: defaults)
            XCTAssertNil(cache.status(for: root))
            XCTAssertNil(cache.header(for: root))
            cache.store(GitRepositoryStatus(branch: "fresh"), for: root)
            XCTAssertEqual(GitStatusCache(defaults: defaults).status(for: root)?.branch, "fresh")
        }

        let cache = GitStatusCache(defaults: defaults)
        cache.store(GitRepositoryStatus(branch: "main"), for: root)
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        var status = try XCTUnwrap(entries[0]["status"] as? [String: Any])
        status["modifiedCount"] = -1
        entries[0]["status"] = status
        archive["entries"] = entries
        defaults.set(try JSONSerialization.data(withJSONObject: archive), forKey: key)
        XCTAssertNil(GitStatusCache(defaults: defaults).status(for: root))
    }

    func testAbsentNilResultsDoNotWritePreferencesAndZeroLimitDisablesStorage() {
        let cache = GitStatusCache(defaults: defaults)
        cache.store(nil as GitRepositoryStatus?, for: root)
        cache.store(nil as GitHeaderStatus?, for: root)
        XCTAssertNil(defaults.object(forKey: key))

        let disabled = GitStatusCache(defaults: defaults, limit: 0)
        disabled.store(GitRepositoryStatus(branch: "main"), for: root)
        disabled.store(header(), for: root)
        XCTAssertNil(disabled.status(for: root))
        XCTAssertNil(disabled.header(for: root))
    }

    func testFullSnapshotIsAvailableOnlyInTheCurrentSession() throws {
        let cache = GitStatusCache(defaults: defaults)
        let snapshot = GitSnapshot(root: root, branch: "feature", head: "abc", upstream: "origin/feature",
            ahead: 2, behind: 1, files: [
                GitFileStatus(path: "private-file.txt", originalPath: "original.txt", indexStatus: "R", workTreeStatus: "M")
            ], stashes: [GitStash(id: "stash@{0}", objectID: "def", subject: "private-subject")],
            operation: "Merge", trackedPaths: ["private-file.txt"], stashedPaths: ["stashed-file.txt"])
        cache.storeSnapshot(snapshot, for: root)
        let cached = try XCTUnwrap(cache.snapshot(for: root))
        XCTAssertEqual(cached.files, snapshot.files)
        XCTAssertEqual(cached.trackedPaths, snapshot.trackedPaths)
        XCTAssertEqual(cached.stashedPaths, snapshot.stashedPaths)
        XCTAssertEqual(cached.stashes, snapshot.stashes)
        XCTAssertEqual(cached.head, "abc")
        XCTAssertEqual(cached.upstream, "origin/feature")
        XCTAssertNil(defaults.object(forKey: key))

        cache.store(GitHeaderStatus(snapshot: snapshot), for: root)
        let encoded = String(decoding: try XCTUnwrap(defaults.data(forKey: key)), as: UTF8.self)
        for omitted in ["private-file.txt", "original.txt", "private-subject", "stashed-file.txt"] {
            XCTAssertFalse(encoded.contains(omitted))
        }
        let nextSession = GitStatusCache(defaults: defaults)
        XCTAssertNil(nextSession.snapshot(for: root))
        XCTAssertEqual(nextSession.header(for: root)?.branch, "feature")
    }

    func testSessionSnapshotsShareKnownDirectoryAliasesAndKeepWorktreesIndependent() {
        let cache = GitStatusCache(defaults: defaults)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let worktree = URL(fileURLWithPath: "/repositories/linked", isDirectory: true)
        let changed = GitFileStatus(path: "Sources/file.txt", indexStatus: "M", workTreeStatus: "M")
        cache.storeSnapshot(GitSnapshot(root: root, branch: "main", files: [changed]),
                            for: root.appendingPathComponent("Sources/../Sources", isDirectory: true))
        cache.storeSnapshot(GitSnapshot(root: worktree, branch: "feature"), for: worktree)
        XCTAssertEqual(cache.snapshot(for: root)?.files, [changed])
        XCTAssertEqual(cache.snapshot(for: sources)?.files, [changed])
        XCTAssertNil(cache.snapshot(for: sources.appendingPathComponent("nested")))
        XCTAssertNil(cache.snapshot(for: URL(string: "https://example.invalid/repositories/project")!))

        cache.storeSnapshot(GitSnapshot(root: root, branch: "updated", trackedPaths: ["Sources/file.txt"]), for: root)
        XCTAssertEqual(cache.snapshot(for: sources)?.branch, "updated")
        XCTAssertEqual(cache.snapshot(for: sources)?.files, [])
        XCTAssertEqual(cache.snapshot(for: sources)?.trackedPaths, ["Sources/file.txt"])
        XCTAssertEqual(cache.snapshot(for: worktree)?.branch, "feature")
    }

    func testSessionNilResultInvalidatesQueryOrWholeRootWithoutRemovingPersistentHeader() {
        let cache = GitStatusCache(defaults: defaults)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let tests = root.appendingPathComponent("Tests", isDirectory: true)
        let other = URL(fileURLWithPath: "/repositories/other", isDirectory: true)
        cache.store(header(), for: root)
        cache.storeSnapshot(GitSnapshot(root: root, branch: "main"), for: sources)
        cache.storeSnapshot(GitSnapshot(root: root, branch: "main"), for: tests)
        cache.storeSnapshot(GitSnapshot(root: other, branch: "other"), for: other)
        cache.storeSnapshot(nil, for: sources)
        XCTAssertNil(cache.snapshot(for: sources))
        XCTAssertNotNil(cache.snapshot(for: root))
        XCTAssertNotNil(cache.snapshot(for: tests))

        cache.storeSnapshot(nil, for: root)
        XCTAssertNil(cache.snapshot(for: root))
        XCTAssertNil(cache.snapshot(for: tests))
        XCTAssertEqual(cache.snapshot(for: other)?.branch, "other")
        XCTAssertNotNil(cache.header(for: root))
    }

    func testSessionSnapshotAndAliasLimitsEvictWithoutKeepingStaleAliases() {
        let cache = GitStatusCache(defaults: defaults, limit: 2)
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        let third = root.appendingPathComponent("third")
        for query in [first, second, third] {
            cache.storeSnapshot(GitSnapshot(root: root, branch: "main"), for: query)
        }
        XCTAssertNil(cache.snapshot(for: first))
        XCTAssertNotNil(cache.snapshot(for: second))
        XCTAssertNotNil(cache.snapshot(for: third))
        XCTAssertNotNil(cache.snapshot(for: root))

        for name in ["other", "latest"] {
            let worktree = URL(fileURLWithPath: "/repositories/\(name)")
            cache.storeSnapshot(GitSnapshot(root: worktree, branch: name), for: worktree)
        }
        XCTAssertNil(cache.snapshot(for: root))
        XCTAssertNil(cache.snapshot(for: second))
        XCTAssertNil(cache.snapshot(for: third))

        let disabled = GitStatusCache(defaults: defaults, limit: 0)
        disabled.storeSnapshot(GitSnapshot(root: root, branch: "main"), for: root)
        XCTAssertNil(disabled.snapshot(for: root))
    }

    func testSessionFullSnapshotsAreCappedAtTwentyWorktrees() {
        let cache = GitStatusCache(defaults: defaults)
        for index in 0...20 {
            let worktree = URL(fileURLWithPath: "/repositories/project-\(index)")
            cache.storeSnapshot(GitSnapshot(root: worktree, branch: "main"), for: worktree.appendingPathComponent("Sources"))
        }
        XCTAssertNil(cache.snapshot(for: URL(fileURLWithPath: "/repositories/project-0")))
        XCTAssertNil(cache.snapshot(for: URL(fileURLWithPath: "/repositories/project-0/Sources")))
        XCTAssertNotNil(cache.snapshot(for: URL(fileURLWithPath: "/repositories/project-20")))
        XCTAssertNotNil(cache.snapshot(for: URL(fileURLWithPath: "/repositories/project-20/Sources")))
    }
}
