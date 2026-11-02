import Foundation
import XCTest
@testable import PaneRookCore

final class GitRepositoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookGitTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        _ = try git("init", "-q")
        _ = try git("config", "user.name", "PaneRook Test")
        _ = try git("config", "user.email", "tests@example.invalid")
        _ = try git("config", "commit.gpgsign", "false")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func git(_ arguments: String...) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"; process.environment = environment
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw GitError(stderr) }
        return stdout.trimmingCharacters(in: .newlines)
    }
    private func write(_ path: String, _ content: String = "initial\n") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    private func initialCommit() throws {
        try write("tracked.txt"); _ = try git("add", "."); _ = try git("commit", "-qm", "Initial")
    }

    func testDiscoveryUnbornAndInitializationOutsideRepository() throws {
        let repository = try GitRepository(directory: root)
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.root.resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
        XCTAssertNil(snapshot.head)
        XCTAssertFalse(snapshot.branch.isEmpty)
        XCTAssertEqual(try repository.history(), [])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookOutside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertNil(try GitRepository.discover(in: outside))
        XCTAssertNotNil(try GitRepository.initialize(in: outside).snapshot())
    }

    func testLiteralPathsRenamesIgnoredAndDualStatus() throws {
        try initialCommit()
        let repository = try GitRepository(directory: root)
        let special = ":(glob)* [odd]\n.txt"
        try write(special); try write("other.txt"); try write(".gitignore", "ignored/\n")
        try write("ignored/secret")
        try repository.run(.stage([special]))
        let snapshot = try repository.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first { $0.path == special }).isStaged)
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first { $0.path == "other.txt" }).isUntracked)
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first { $0.path == "ignored/" }).isIgnored)
        XCTAssertTrue(snapshot.trackedPaths.contains(special))
        try repository.run(.commit("Add special"))
        _ = try git("mv", "--", special, "renamed\n.txt")
        let renamed = try XCTUnwrap(repository.snapshot().files.first { $0.originalPath != nil })
        XCTAssertEqual(renamed.path, "renamed\n.txt")
        XCTAssertEqual(renamed.originalPath, special)
        try write("tracked.txt", "staged\n")
        try repository.run(.stage(["tracked.txt"]))
        try write("tracked.txt", "working\n")
        let dual = try XCTUnwrap(repository.snapshot().files.first { $0.path == "tracked.txt" })
        XCTAssertEqual(dual.indexStatus, "M"); XCTAssertEqual(dual.workTreeStatus, "M")
        XCTAssertTrue(try repository.diff(path: "tracked.txt").contains("+working"))
        XCTAssertTrue(try repository.diff(path: "tracked.txt", staged: true).contains("+staged"))
        try repository.run(.unstage(["tracked.txt"]))
        XCTAssertFalse(try XCTUnwrap(repository.snapshot().files.first { $0.path == "tracked.txt" }).isStaged)
    }

    func testUnstageBeforeFirstCommitAndRejectUnsafePaths() throws {
        let repository = try GitRepository(directory: root)
        try write("-n"); try repository.run(.stage(["-n"]))
        XCTAssertTrue(try repository.snapshot().trackedPaths.contains("-n"))
        try repository.run(.unstage(["-n"]))
        XCTAssertFalse(try repository.snapshot().trackedPaths.contains("-n"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("-n"), encoding: .utf8), "initial\n")
        for invalid in ["", "../outside", "/tmp", "nested/../../outside"] {
            XCTAssertThrowsError(try repository.run(.stage([invalid])))
        }
        XCTAssertThrowsError(try repository.run(.stage([])))
        XCTAssertThrowsError(try repository.run(.createBranch("--help")))
        XCTAssertThrowsError(try repository.run(.checkoutRevision("--help")))
    }

    func testStashesIncludeTrackedIndexAndUntrackedPaths() throws {
        try initialCommit()
        let repository = try GitRepository(directory: root)
        try write("tracked.txt", "first stash\n"); try write("new\nfile.txt")
        try repository.run(.stashSave("First"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new\nfile.txt").path))
        try write("second.txt"); try repository.run(.stage(["second.txt"]))
        try repository.run(.stashSave("Second"))
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.stashes.count, 2)
        XCTAssertEqual(snapshot.stashes.first?.id, "stash@{0}")
        XCTAssertTrue(snapshot.stashes.first?.subject.contains("Second") == true)
        XCTAssertEqual(snapshot.stashedPaths, Set(["tracked.txt", "new\nfile.txt", "second.txt"]))
        XCTAssertTrue(try repository.diff(revision: "stash@{1}").contains("first stash"))
        try repository.run(.stashApply("stash@{0}"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
        try repository.run(.stashDrop("stash@{0}"))
        XCTAssertEqual(try repository.snapshot().stashes.count, 1)
        try repository.run(.unstage(["second.txt"]))
        try repository.run(.stashPop("stash@{0}"))
        XCTAssertTrue(try repository.snapshot().stashes.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new\nfile.txt"), encoding: .utf8), "initial\n")
        XCTAssertThrowsError(try repository.run(.stashDrop("--all")))
    }

    func testBranchSwitchDetachedTagsHistoryAndDirtyProtection() throws {
        try initialCommit()
        let repository = try GitRepository(directory: root)
        let main = try repository.snapshot().branch
        try repository.run(.createBranch("feature"))
        try write("tracked.txt", "feature\n")
        try repository.run(.stage(["tracked.txt"])); try repository.run(.commit("Feature change"))
        try repository.run(.createTag("v1"))
        XCTAssertEqual(try repository.tags(), ["v1"])
        let commits = try repository.history(path: "tracked.txt")
        XCTAssertEqual(commits.map(\.subject), ["Feature change", "Initial"])
        XCTAssertEqual(try repository.show(revision: commits.last!.id, path: "tracked.txt"), "initial\n")
        XCTAssertTrue(try repository.diff(revision: commits.first!.id).contains("Feature change"))
        try write("tracked.txt", "unsaved\n")
        XCTAssertThrowsError(try repository.run(.switchBranch(main)))
        XCTAssertEqual(try repository.snapshot().branch, "feature")
        try repository.run(.stashSave("Save unsaved"))
        try repository.run(.switchBranch(main))
        XCTAssertTrue(try repository.branches().contains { $0.name == main && $0.current })
        try repository.run(.checkoutRevision("v1"))
        XCTAssertTrue(try repository.snapshot().branch.hasPrefix("HEAD · "))
        try repository.run(.switchBranch(main))
        XCTAssertThrowsError(try repository.run(.deleteBranch("feature")), "Unmerged branches must remain protected")
        try repository.run(.merge("feature"))
        try repository.run(.deleteBranch("feature"))
        XCTAssertFalse(try repository.branches().contains { $0.name == "feature" })
    }

    func testConflictStatusAndLinkedWorktree() throws {
        try initialCommit()
        let repository = try GitRepository(directory: root)
        let main = try repository.snapshot().branch
        try repository.run(.createBranch("conflict"))
        try write("tracked.txt", "branch\n"); try repository.run(.stage(["tracked.txt"])); try repository.run(.commit("Branch"))
        try repository.run(.switchBranch(main))
        try write("tracked.txt", "main\n"); try repository.run(.stage(["tracked.txt"])); try repository.run(.commit("Main"))
        XCTAssertThrowsError(try repository.run(.merge("conflict")))
        let snapshot = try repository.snapshot()
        XCTAssertEqual(snapshot.operation, "Merge")
        XCTAssertTrue(try XCTUnwrap(snapshot.files.first { $0.path == "tracked.txt" }).isConflicted)
        _ = try git("merge", "--abort")
        let worktree = root.appendingPathComponent("linked")
        _ = try git("worktree", "add", "-b", "linked", worktree.path)
        let linked = try GitRepository(directory: worktree)
        XCTAssertEqual(try linked.snapshot().branch, "linked")
        XCTAssertTrue(try linked.snapshot().trackedPaths.contains("tracked.txt"))
    }

    func testLocalRemoteTrackingFetchPushPullAndRemoteBranchSwitch() throws {
        try initialCommit()
        let repository = try GitRepository(directory: root)
        let main = try repository.snapshot().branch
        let remote = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookGitRemote-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: remote) }
        _ = try git("init", "--bare", "-q", remote.path)
        _ = try git("remote", "add", "origin", remote.path)
        _ = try git("push", "-u", "origin", main)
        XCTAssertEqual(try repository.snapshot().upstream, "origin/" + main)
        try write("tracked.txt", "ahead\n")
        try repository.run(.stage(["tracked.txt"])); try repository.run(.commit("Ahead"))
        XCTAssertEqual(try repository.snapshot().ahead, 1)
        try repository.run(.push)
        XCTAssertEqual(try repository.snapshot().ahead, 0)
        try repository.run(.fetch)
        try repository.run(.pull)
        _ = try git("branch", "remote-feature")
        _ = try git("push", "origin", "remote-feature")
        _ = try git("branch", "-d", "remote-feature")
        XCTAssertTrue(try repository.branches().contains { $0.name == "origin/remote-feature" && $0.remote })
        try repository.run(.switchBranch("origin/remote-feature"))
        XCTAssertEqual(try repository.snapshot().branch, "remote-feature")
        XCTAssertEqual(try repository.snapshot().upstream, "origin/remote-feature")
    }
}
