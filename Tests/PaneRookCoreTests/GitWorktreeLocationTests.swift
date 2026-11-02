import Foundation
import XCTest
@testable import PaneRookCore

final class GitWorktreeLocationTests: XCTestCase {
    private var temporary: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent("PaneRookGitLocation-\(UUID())")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        temporary = temporary.resolvingSymlinksInPath().standardizedFileURL
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    @discardableResult
    private func directory(_ path: String) throws -> URL {
        let url = temporary.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRootAndPreviouslyUnvisitedDescendantsShareNearestBoundary() throws {
        let root = try directory("project")
        try directory("project/.git")
        let deep = try directory("project/Sources/new/deep/folder")
        let sibling = try directory("project/Tests")
        XCTAssertEqual(GitWorktreeLocation.root(containing: root), root)
        XCTAssertEqual(GitWorktreeLocation.root(containing: deep), root)
        XCTAssertEqual(GitWorktreeLocation.root(containing: sibling), root)
        XCTAssertNil(GitWorktreeLocation.root(containing: try directory("project-other/Sources")))
        XCTAssertNil(GitWorktreeLocation.root(containing: temporary))
    }

    func testNestedRepositoryDirectoryStopsAtItsOwnBoundary() throws {
        let outer = try directory("outer")
        try directory("outer/.git")
        let nested = try directory("outer/nested")
        try directory("outer/nested/.git")
        let deep = try directory("outer/nested/Sources/deep")
        XCTAssertEqual(GitWorktreeLocation.root(containing: deep), nested)
        XCTAssertEqual(GitWorktreeLocation.root(containing: try directory("outer/ordinary")), outer)
        try fm.removeItem(at: nested.appendingPathComponent(".git"))
        XCTAssertEqual(GitWorktreeLocation.root(containing: deep), outer)
    }

    func testGitFilesStopTraversalWithoutValidatingTheirContents() throws {
        try directory("outer/.git")
        for (name, contents) in [("worktree", "gitdir: /missing/metadata\n"),
                                 ("invalid", "This is not a valid Git file")] {
            let root = try directory("outer/\(name)")
            let deep = try directory("outer/\(name)/Sources/deep")
            try Data(contents.utf8).write(to: root.appendingPathComponent(".git"))
            XCTAssertEqual(GitWorktreeLocation.root(containing: deep), root)
        }
    }

    func testBrokenGitMarkerSymlinkDoesNotLeakOuterRepository() throws {
        try directory("outer/.git")
        let root = try directory("outer/nested")
        let deep = try directory("outer/nested/Sources")
        let marker = root.appendingPathComponent(".git")
        try fm.createSymbolicLink(at: marker, withDestinationURL: temporary.appendingPathComponent("missing"))
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        XCTAssertEqual(GitWorktreeLocation.root(containing: deep), root)
    }

    func testGitMarkerSymlinkCountsAsItsOwnBoundary() throws {
        try directory("outer/.git")
        let root = try directory("outer/linked")
        let metadata = try directory("metadata")
        try fm.createSymbolicLink(at: root.appendingPathComponent(".git"), withDestinationURL: metadata)
        XCTAssertEqual(GitWorktreeLocation.root(containing: try directory("outer/linked/Sources")), root)
    }

    func testDirectorySymlinksUseTheirPhysicalTargetRepository() throws {
        try directory("outer/.git")
        let target = try directory("outside")
        let child = try directory("outside/Sources/deep")
        let link = temporary.appendingPathComponent("outer/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedChild = link.appendingPathComponent("Sources/deep", isDirectory: true)
        XCTAssertNil(GitWorktreeLocation.root(containing: linkedChild))
        try directory("outside/.git")
        XCTAssertEqual(GitWorktreeLocation.root(containing: linkedChild), target)
        XCTAssertEqual(GitWorktreeLocation.root(containing: child), target)
    }

    func testGitMetadataAndNonFileURLsDoNotInheritAWorktree() throws {
        let metadata = try directory("project/.git/objects/deep")
        XCTAssertNil(GitWorktreeLocation.root(containing: metadata))
        XCTAssertNil(GitWorktreeLocation.root(containing: URL(string: "https://example.invalid/project")!))
    }
}
