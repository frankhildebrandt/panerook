import Foundation
import XCTest
@testable import PaneRookCore

final class GitHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookGitHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try git("init", "-q")
        try git("config", "user.name", "History Test")
        try git("config", "user.email", "history@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try git("config", "core.autocrlf", "false")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult private func git(_ arguments: String...) throws -> String {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw GitError(stderr) }
        return stdout.trimmingCharacters(in: .newlines)
    }

    private func write(_ path: String, _ content: String) throws {
        try Data(content.utf8).write(to: root.appendingPathComponent(path))
    }

    private func commit(_ subject: String) throws {
        try git("add", "--all")
        try git("commit", "-qm", subject)
    }

    func testUnbornRepositoryAndUntrackedFileHaveEmptyHistory() throws {
        let repository = try GitRepository(directory: root)
        XCTAssertEqual(try repository.historyEntries(), [])
        XCTAssertEqual(try repository.historyEntries(path: "new.txt"), [])
        try write("tracked.txt", "initial\n")
        try commit("Initial")
        try write("untracked.txt", "new\n")
        XCTAssertEqual(try repository.historyEntries(path: "untracked.txt"), [])
    }

    func testInitialCommitAndEditsRetainContentWithoutChangingWorkingTree() throws {
        try write("file.txt", "initial\n")
        try commit("Initial")
        try write("file.txt", "updated\n")
        try commit("Update")
        try write("file.txt", "unsaved\n")
        let repository = try GitRepository(directory: root)
        let head = try git("rev-parse", "HEAD")
        let entries = try repository.historyEntries(path: "file.txt")
        XCTAssertEqual(entries.map(\.commit.subject), ["Update", "Initial"])
        XCTAssertEqual(entries.map(\.path), ["file.txt", "file.txt"])
        XCTAssertEqual(try repository.historyFile(entries[0]), "updated\n")
        XCTAssertEqual(try repository.historyFile(entries[1]), "initial\n")
        XCTAssertTrue(try repository.historyDiff(entries[1]).contains("+initial"))
        XCTAssertEqual(try git("rev-parse", "HEAD"), head)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "unsaved\n")
        XCTAssertEqual(try repository.historyEntries(limit: 1).map(\.commit.subject), ["Update"])
        XCTAssertNil(try repository.historyEntries()[0].path)
    }

    func testFileHistoryFollowsRenamesWithLiteralSpecialPaths() throws {
        let original = ":(glob)* [old]\n.txt"
        let renamed = "new name\t[1]\n.txt"
        try write(original, "unchanged\n")
        try write("other.txt", "unrelated\n")
        try commit("Initial")
        try git("mv", "--", original, renamed)
        try commit("Rename")
        try write(renamed, "changed\n")
        try commit("Edit")
        let repository = try GitRepository(directory: root)
        let entries = try repository.historyEntries(path: renamed)
        XCTAssertEqual(entries.map(\.commit.subject), ["Edit", "Rename", "Initial"])
        XCTAssertEqual(entries.map(\.path), [renamed, renamed, original])
        XCTAssertEqual(entries[1].originalPath, original)
        XCTAssertEqual(try repository.historyFile(entries[2]), "unchanged\n")
        let renamePatch = try repository.historyDiff(entries[1])
        XCTAssertTrue(renamePatch.contains("rename from"))
        XCTAssertTrue(renamePatch.contains("rename to"))
        XCTAssertFalse(renamePatch.contains("unrelated"))
    }

    func testDeletionHasPatchAndOlderVersionRemainsReadable() throws {
        try write("deleted.txt", "preserved\n")
        try commit("Add")
        try git("rm", "deleted.txt")
        try commit("Delete")
        let repository = try GitRepository(directory: root)
        let entries = try repository.historyEntries(path: "deleted.txt")
        XCTAssertEqual(entries.map(\.commit.subject), ["Delete", "Add"])
        XCTAssertTrue(try repository.historyDiff(entries[0]).contains("-preserved"))
        XCTAssertThrowsError(try repository.historyFile(entries[0])) { error in
            XCTAssertTrue(error.localizedDescription.contains("nicht verfügbar"))
        }
        XCTAssertEqual(try repository.historyFile(entries[1]), "preserved\n")
    }

    func testDirectoryHistoryAndDiffExcludeSiblingDirectoriesAndFiles() throws {
        let directory = ":(glob) selected [folder]"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(directory + "/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sibling"), withIntermediateDirectories: false)
        try write(directory + "/nested/file.txt", "selected initial\n")
        try write("sibling/file.txt", "sibling initial\n")
        try write(directory + " suffix.txt", "outside initial\n")
        try commit("Initial")
        try write("sibling/file.txt", "unrelated sibling change\n")
        try commit("Sibling edit")
        try write(directory + " suffix.txt", "unrelated prefix change\n")
        try commit("Prefix edit")
        try write(directory + "/nested/file.txt", "selected updated\n")
        try write("sibling/file.txt", "another sibling change\n")
        try commit("Mixed edit")

        let repository = try GitRepository(directory: root)
        let entries = try repository.historyEntries(path: directory, isDirectory: true)
        XCTAssertEqual(entries.map(\.commit.subject), ["Mixed edit", "Initial"])
        XCTAssertEqual(entries.map(\.path), [directory, directory])
        XCTAssertTrue(entries.allSatisfy { $0.isDirectory && $0.originalPath == nil })
        let patch = try repository.historyDiff(entries[0])
        XCTAssertTrue(patch.contains("+selected updated"))
        XCTAssertFalse(patch.contains("sibling/file.txt"))
        XCTAssertFalse(patch.contains("sibling change"))
        let initialPatch = try repository.historyDiff(entries[1])
        XCTAssertTrue(initialPatch.contains("+selected initial"))
        XCTAssertFalse(initialPatch.contains("outside initial"))
        XCTAssertEqual(try repository.historyEntries(path: directory, isDirectory: true, limit: 1).count, 1)
        XCTAssertThrowsError(try repository.historyFile(entries[0])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Verzeichnisse"))
        }
    }

    func testDirectoryHistoryDoesNotFollowFilesOutsideTheSelectedDirectory() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("selected"), withIntermediateDirectories: false)
        try write("outside.txt", "content\n")
        try commit("Outside origin")
        try git("mv", "outside.txt", "selected/file.txt")
        try commit("Move into directory")
        let repository = try GitRepository(directory: root)
        let entries = try repository.historyEntries(path: "selected", isDirectory: true)
        XCTAssertEqual(entries.map(\.commit.subject), ["Move into directory"])
        XCTAssertEqual(entries.first?.path, "selected")
        XCTAssertTrue(entries.first?.isDirectory == true)
        XCTAssertTrue(try repository.historyDiff(entries[0]).contains("+content"))
        XCTAssertEqual(try repository.historyEntries(path: "missing", isDirectory: true), [])
    }

    func testMergeUsesFirstParentTimelineAndPatch() throws {
        try write("file.txt", "initial\n")
        try commit("Initial")
        let main = try git("branch", "--show-current")
        try git("switch", "-qc", "feature")
        try write("file.txt", "from feature\n")
        try commit("Feature edit")
        try git("switch", "-q", main)
        try write("other.txt", "main\n")
        try commit("Main edit")
        try git("merge", "--no-ff", "-qm", "Merge feature", "feature")
        let repository = try GitRepository(directory: root)
        let entries = try repository.historyEntries()
        XCTAssertEqual(entries.map(\.commit.subject), ["Merge feature", "Main edit", "Initial"])
        let patch = try repository.historyDiff(entries[0])
        XCTAssertTrue(patch.contains("+from feature"))
        XCTAssertTrue(patch.contains("-initial"))
        XCTAssertFalse(patch.contains("+main"))
        let fileEntries = try repository.historyEntries(path: "file.txt")
        XCTAssertEqual(fileEntries.map(\.commit.subject), ["Merge feature", "Initial"])
        XCTAssertEqual(try repository.historyFile(fileEntries[0]), "from feature\n")
    }

    func testInvalidPathsMissingFileScopeAndBinaryContentAreRejected() throws {
        try write("binary", "a\0b")
        try commit("Binary")
        let repository = try GitRepository(directory: root)
        for path in ["", "../outside", "/tmp", "nested/../../outside", "nul\0path"] {
            XCTAssertThrowsError(try repository.historyEntries(path: path))
        }
        let entry = try XCTUnwrap(repository.historyEntries().first)
        XCTAssertThrowsError(try repository.historyFile(entry))
        let binary = try XCTUnwrap(repository.historyEntries(path: "binary").first)
        XCTAssertThrowsError(try repository.historyFile(binary)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Binärdateien"))
        }
        XCTAssertThrowsError(try repository.historyDiff(GitHistoryEntry(commit: entry.commit, path: "../outside")))
    }
}
