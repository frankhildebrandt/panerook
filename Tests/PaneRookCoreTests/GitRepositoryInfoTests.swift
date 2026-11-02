import XCTest
@testable import PaneRookCore

final class GitRepositoryInfoTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookWorktreeTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                             "-c", "user.name=PaneRook Tests", "-c", "user.email=tests@panerook.invalid"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }

    private func repository(named name: String = "repository", commit: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try git(["init", "--quiet", "--initial-branch=main", directory.path], in: root)
        if commit {
            try git(["commit", "--allow-empty", "--quiet", "-m", "Fixture"], in: directory)
        }
        return directory
    }

    func testEmptyRepositoryIsDiscoveredFromANestedDirectory() throws {
        let directory = try repository()
        let nested = directory.appendingPathComponent("Sources/Feature")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let info = try XCTUnwrap(GitRepositoryReader().repository(containing: nested))
        XCTAssertEqual(info.worktreeRoot.path, directory.resolvingSymlinksInPath().path)
        XCTAssertEqual(info.commonDirectory.path, directory.appendingPathComponent(".git").resolvingSymlinksInPath().path)
        XCTAssertEqual(info.worktrees.count, 1)
        XCTAssertEqual(info.worktrees.first?.branch, "main")
        XCTAssertFalse(try XCTUnwrap(info.worktrees.first).isBare)
    }

    func testMainAndLinkedWorktreesShareRepositoryIdentityAndListAllBranches() throws {
        let directory = try repository(commit: true)
        let linked = root.appendingPathComponent("linked worktree")
        try git(["worktree", "add", "--quiet", "-b", "feature/example", linked.path], in: directory)
        let nested = linked.appendingPathComponent("some/nested/directory")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let mainInfo = try XCTUnwrap(GitRepositoryReader().repository(containing: directory))
        let linkedInfo = try XCTUnwrap(GitRepositoryReader().repository(containing: nested))
        XCTAssertEqual(mainInfo.commonDirectory, linkedInfo.commonDirectory)
        XCTAssertEqual(linkedInfo.worktreeRoot.path, linked.resolvingSymlinksInPath().path)
        XCTAssertEqual(mainInfo.worktrees, linkedInfo.worktrees)
        XCTAssertEqual(Set(mainInfo.worktrees.compactMap(\.branch)), Set(["main", "feature/example"]))
    }

    func testDetachedWorktreeAndPathsWithNewlinesArePreserved() throws {
        let directory = try repository(named: "main\nrepository ß", commit: true)
        let linked = root.appendingPathComponent("linked\nworktree ' ß")
        try git(["worktree", "add", "--quiet", "--detach", linked.path], in: directory)
        let info = try XCTUnwrap(GitRepositoryReader().repository(containing: linked))
        XCTAssertEqual(info.worktreeRoot.path, linked.resolvingSymlinksInPath().path)
        XCTAssertEqual(info.commonDirectory.path, directory.appendingPathComponent(".git").resolvingSymlinksInPath().path)
        let detached = try XCTUnwrap(info.worktrees.first { $0.url.path == info.worktreeRoot.path })
        XCTAssertNil(detached.branch)
        XCTAssertFalse(detached.isBare)
        XCTAssertFalse(detached.isPrunable)
    }

    func testLockedAndMissingWorktreesRemainExplicitlyRepresented() throws {
        let directory = try repository(commit: true)
        let locked = root.appendingPathComponent("locked")
        let missing = root.appendingPathComponent("missing")
        try git(["worktree", "add", "--quiet", "-b", "locked", locked.path], in: directory)
        try git(["worktree", "lock", "--reason", "External\ndrive", locked.path], in: directory)
        try git(["worktree", "add", "--quiet", "-b", "missing", missing.path], in: directory)
        try fm.removeItem(at: missing)
        let info = try XCTUnwrap(GitRepositoryReader().repository(containing: directory))
        XCTAssertTrue(try XCTUnwrap(info.worktrees.first { $0.branch == "locked" }).isLocked)
        XCTAssertTrue(try XCTUnwrap(info.worktrees.first { $0.branch == "missing" }).isPrunable)
    }

    func testSymlinkVisitsResolveToTheSameRootAndIdentity() throws {
        let directory = try repository(commit: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: directory)
        let original = try XCTUnwrap(GitRepositoryReader().repository(containing: directory))
        let aliased = try XCTUnwrap(GitRepositoryReader().repository(containing: alias))
        XCTAssertEqual(aliased, original)
    }

    func testOrdinaryDirectoriesBareRepositoriesAndGitMetadataAreNotWorkingTrees() throws {
        XCTAssertNil(GitRepositoryReader().repository(containing: root))
        let directory = try repository(commit: true)
        XCTAssertNil(GitRepositoryReader().repository(containing: directory.appendingPathComponent(".git")))
        let bare = root.appendingPathComponent("bare.git")
        try git(["clone", "--quiet", "--bare", directory.path, bare.path], in: root)
        XCTAssertNil(GitRepositoryReader().repository(containing: bare))

        let linked = root.appendingPathComponent("bare-linked")
        try git(["worktree", "add", "--quiet", "-b", "from-bare", linked.path], in: bare)
        let info = try XCTUnwrap(GitRepositoryReader().repository(containing: linked))
        XCTAssertEqual(info.commonDirectory.path, bare.resolvingSymlinksInPath().path)
        XCTAssertTrue(info.worktrees.contains { $0.isBare && $0.url.path == bare.resolvingSymlinksInPath().path })
        XCTAssertEqual(info.worktreeRoot.path, linked.resolvingSymlinksInPath().path)
    }

    func testNestedRepositoryIsIndependentFromContainingRepository() throws {
        let directory = try repository(commit: true)
        let nested = directory.appendingPathComponent("nested")
        try git(["init", "--quiet", "--initial-branch=inner", nested.path], in: directory)
        let outerInfo = try XCTUnwrap(GitRepositoryReader().repository(containing: directory))
        let innerInfo = try XCTUnwrap(GitRepositoryReader().repository(containing: nested))
        XCTAssertNotEqual(outerInfo.commonDirectory, innerInfo.commonDirectory)
        XCTAssertEqual(innerInfo.worktrees.first?.branch, "inner")
    }

    func testCancelledAndBoundedReadersDoNotPublishPartialRepositoryInfo() throws {
        let directory = try repository()
        let reader = GitRepositoryReader()
        reader.cancel()
        XCTAssertTrue(reader.isCancelled)
        XCTAssertNil(reader.repository(containing: directory))
        XCTAssertNil(GitRepositoryReader(timeout: 5, outputLimit: 8).repository(containing: directory))
        XCTAssertNil(GitRepositoryReader(timeout: 0, outputLimit: 1024).repository(containing: directory))
    }

    func testParserRejectsIncompleteRecordsAndPreservesNulDelimitedPaths() throws {
        XCTAssertNil(GitWorktree.parseList(Data("worktree /tmp/a\0branch refs/heads/main\0".utf8)))
        XCTAssertNil(GitWorktree.parseList(Data("worktree relative\0bare\0\0".utf8)))
        XCTAssertNil(GitWorktree.parseList(Data("worktree /tmp/a\0\0".utf8)))
        let parsed = try XCTUnwrap(GitWorktree.parseList(Data("worktree /tmp/a\nß\0HEAD 1234\0branch refs/heads/topic/one\0locked external\ndrive\0\0".utf8)))
        XCTAssertEqual(parsed.first?.url.path, URL(fileURLWithPath: "/tmp/a\nß", isDirectory: true).resolvingSymlinksInPath().path)
        XCTAssertEqual(parsed.first?.branch, "topic/one")
        XCTAssertTrue(try XCTUnwrap(parsed.first).isLocked)
    }
}
