import XCTest
@testable import PaneRookCore

final class GitRepositoryStatusTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookGitTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL, succeeds: Bool = true) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if succeeds { XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " ")) }
        else { XCTAssertNotEqual(process.terminationStatus, 0) }
        return String(decoding: output, as: UTF8.self)
    }

    private func repository() throws -> URL {
        let directory = root.appendingPathComponent("repository with spaces")
        try git(["init", "--quiet", "--initial-branch=main", directory.path], in: root)
        try git(["config", "user.name", "PaneRook Tests"], in: directory)
        try git(["config", "user.email", "tests@panerook.invalid"], in: directory)
        try git(["config", "core.excludesFile", "/dev/null"], in: directory)
        return directory
    }

    private func write(_ text: String, to name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commit(in directory: URL) throws {
        try git(["add", "--all"], in: directory)
        try git(["commit", "--quiet", "-m", "Fixture"], in: directory)
    }

    func testEmptyAndCommittedRepositoriesAreClean() throws {
        let directory = try repository()
        let empty = try XCTUnwrap(GitStatusReader().status(for: directory))
        XCTAssertEqual(empty, GitRepositoryStatus(branch: "main"))
        XCTAssertTrue(empty.isClean)
        try write("initial", to: "tracked.txt", in: directory)
        try commit(in: directory)
        XCTAssertEqual(GitStatusReader().status(for: directory), empty)
    }

    func testOrdinaryDirectoriesInsideAndOutsideRepositoriesHaveNoStatus() throws {
        XCTAssertNil(GitStatusReader().status(for: root))
        let directory = try repository()
        let ordinary = directory.appendingPathComponent("ordinary")
        try fm.createDirectory(at: ordinary, withIntermediateDirectories: false)
        XCTAssertNil(GitStatusReader().status(for: ordinary))
        try write("not a repository", to: ".git", in: ordinary)
        XCTAssertNil(GitStatusReader().status(for: ordinary))
    }

    func testChangesCountIndexWorktreeAndUntrackedFilesSeparately() throws {
        let directory = try repository()
        try write("original", to: "modified.txt", in: directory)
        try write("original", to: "both.txt", in: directory)
        try write("ignored*\n", to: ".gitignore", in: directory)
        try commit(in: directory)
        try write("index", to: "both.txt", in: directory)
        try write("added", to: "added.txt", in: directory)
        try git(["add", "--", "both.txt", "added.txt"], in: directory)
        try write("worktree", to: "both.txt", in: directory)
        try write("changed", to: "modified.txt", in: directory)
        try write("new", to: "untracked/new file\nß.txt", in: directory)
        try write("new", to: "untracked/second.txt", in: directory)
        try write("ignored", to: "ignored-file", in: directory)
        let status = try XCTUnwrap(GitStatusReader().status(for: directory))
        XCTAssertEqual(status, GitRepositoryStatus(branch: "main", stagedCount: 2, modifiedCount: 2, untrackedCount: 2))
        XCTAssertFalse(status.isClean)
    }

    func testRenameSourceThatLooksLikeAnUntrackedRecordIsNotCounted() throws {
        let directory = try repository()
        let source = "? original\nfile.txt"
        try write("rename fixture", to: source, in: directory)
        try commit(in: directory)
        try git(["mv", "--", source, "renamed\nfile.txt"], in: directory)
        XCTAssertEqual(GitStatusReader().status(for: directory), GitRepositoryStatus(branch: "main", stagedCount: 1))
    }

    func testDeletedFilesCountInTheAppropriateSide() throws {
        let directory = try repository()
        try write("fixture", to: "unstaged.txt", in: directory)
        try write("fixture", to: "staged.txt", in: directory)
        try commit(in: directory)
        try fm.removeItem(at: directory.appendingPathComponent("unstaged.txt"))
        try git(["rm", "--", "staged.txt"], in: directory)
        XCTAssertEqual(GitStatusReader().status(for: directory), GitRepositoryStatus(branch: "main", stagedCount: 1, modifiedCount: 1))
    }

    func testMergeConflictIsDistinctFromOrdinaryChanges() throws {
        let directory = try repository()
        try write("base\n", to: "conflict.txt", in: directory)
        try commit(in: directory)
        try git(["checkout", "--quiet", "-b", "other"], in: directory)
        try write("other\n", to: "conflict.txt", in: directory)
        try commit(in: directory)
        try git(["checkout", "--quiet", "main"], in: directory)
        try write("main\n", to: "conflict.txt", in: directory)
        try commit(in: directory)
        try git(["merge", "--no-edit", "other"], in: directory, succeeds: false)
        let status = try XCTUnwrap(GitStatusReader().status(for: directory))
        XCTAssertEqual(status, GitRepositoryStatus(branch: "main", conflictCount: 1))
        XCTAssertFalse(status.isClean)
    }

    func testLinkedWorktreeAndDetachedHead() throws {
        let directory = try repository()
        try write("fixture", to: "tracked", in: directory)
        try commit(in: directory)
        let worktree = root.appendingPathComponent("linked worktree")
        try git(["worktree", "add", "--quiet", "-b", "feature", worktree.path], in: directory)
        var markerIsDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: worktree.appendingPathComponent(".git").path, isDirectory: &markerIsDirectory))
        XCTAssertFalse(markerIsDirectory.boolValue)
        XCTAssertEqual(GitStatusReader().status(for: worktree), GitRepositoryStatus(branch: "feature"))
        try git(["checkout", "--quiet", "--detach"], in: worktree)
        XCTAssertEqual(GitStatusReader().status(for: worktree), GitRepositoryStatus(branch: nil))
    }

    func testAheadAndBehindUseLocalTrackingInformation() throws {
        let directory = try repository()
        try write("base", to: "tracked", in: directory)
        try commit(in: directory)
        try git(["branch", "upstream"], in: directory)
        try git(["branch", "--set-upstream-to=upstream", "main"], in: directory)
        try write("ahead", to: "ahead", in: directory)
        try commit(in: directory)
        try git(["checkout", "--quiet", "upstream"], in: directory)
        try write("behind", to: "behind", in: directory)
        try commit(in: directory)
        try git(["checkout", "--quiet", "main"], in: directory)
        let status = try XCTUnwrap(GitStatusReader().status(for: directory))
        XCTAssertEqual(status, GitRepositoryStatus(branch: "main", aheadCount: 1, behindCount: 1))
        XCTAssertTrue(status.isClean)
    }

    func testCancelledAndBoundedReadersNeverReturnPartialCleanResults() throws {
        let directory = try repository()
        let reader = GitStatusReader()
        reader.cancel()
        XCTAssertTrue(reader.isCancelled)
        XCTAssertNil(reader.status(for: directory))
        XCTAssertNil(GitStatusReader(timeout: 5, outputLimit: 8).status(for: directory))
        XCTAssertNil(GitStatusReader(timeout: 0, outputLimit: 1024).status(for: directory))
    }

    func testRepositoryFsmonitorCommandsAreDisabled() throws {
        let directory = try repository()
        try write("fixture", to: "tracked", in: directory)
        try commit(in: directory)
        let sentinel = root.appendingPathComponent("fsmonitor-ran")
        let script = root.appendingPathComponent("fsmonitor.sh")
        try Data("#!/bin/sh\n/usr/bin/touch '\(sentinel.path)'\nexit 1\n".utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try git(["config", "core.fsmonitor", script.path], in: directory)
        XCTAssertEqual(GitStatusReader().status(for: directory), GitRepositoryStatus(branch: "main"))
        XCTAssertFalse(fm.fileExists(atPath: sentinel.path))
    }

    func testReadingStatusDoesNotRefreshOrLockTheIndex() throws {
        let directory = try repository()
        try write("fixture", to: "tracked", in: directory)
        try commit(in: directory)
        let index = directory.appendingPathComponent(".git/index")
        let original = try Data(contentsOf: index)
        let originalDate = try fm.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        try write("changed content", to: "tracked", in: directory)
        XCTAssertEqual(GitStatusReader().status(for: directory), GitRepositoryStatus(branch: "main", modifiedCount: 1))
        XCTAssertEqual(try Data(contentsOf: index), original)
        XCTAssertEqual(try fm.attributesOfItem(atPath: index.path)[.modificationDate] as? Date, originalDate)
        XCTAssertFalse(fm.fileExists(atPath: directory.appendingPathComponent(".git/index.lock").path))
    }

    func testParserRejectsTruncatedOrMalformedStatus() {
        XCTAssertNil(GitRepositoryStatus.parse(Data("# branch.head main".utf8)))
        XCTAssertNil(GitRepositoryStatus.parse(Data("# branch.head main\0? \0".utf8)))
        XCTAssertNil(GitRepositoryStatus.parse(Data("# branch.head main\0# branch.ab +x -1\0".utf8)))
        XCTAssertNil(GitRepositoryStatus.parse(Data("# branch.head main\0invalid\0".utf8)))
        XCTAssertNil(GitRepositoryStatus.parse(Data("# branch.oid (initial)\0".utf8)))
    }
}
