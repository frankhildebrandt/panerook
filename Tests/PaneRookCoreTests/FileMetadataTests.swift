import XCTest
import Darwin
@testable import PaneRookCore

final class FileMetadataTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookMetadataTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("original".utf8).write(to: url)
        return url
    }

    func testPermissionMaskPreservesUnselectedBitsAcrossBatch() throws {
        let a = try file("a")
        let b = try file("b")
        try FileMetadata.changePermissions(of: [a], values: 0o640)
        try FileMetadata.changePermissions(of: [b], values: 0o600)
        try FileMetadata.changePermissions(of: [a, b], values: 0o100, mask: 0o100)
        XCTAssertEqual(try FileMetadata.inspect(a).permissions, 0o740)
        XCTAssertEqual(try FileMetadata.inspect(b).permissions, 0o700)
    }

    func testChmodDoesNotFollowSymbolicLink() throws {
        let source = try file("source")
        let link = root.appendingPathComponent("link")
        try FileMetadata.changePermissions(of: [source], values: 0o600)
        try FileMetadata.createSymbolicLink(to: source, at: link, relative: false)
        try FileMetadata.changePermissions(of: [link], values: 0o700)
        XCTAssertEqual(try FileMetadata.inspect(source).permissions, 0o600)
        XCTAssertTrue(try FileMetadata.inspect(link).isSymbolicLink)
        XCTAssertEqual(try FileMetadata.inspect(link).permissions, 0o700)
    }

    func testHardLinkSharesInodeAndNeverOverwrites() throws {
        let source = try file("source")
        let link = root.appendingPathComponent("link")
        try FileMetadata.createHardLink(to: source, at: link)
        var originalStat = stat()
        var linkStat = stat()
        XCTAssertEqual(lstat(source.path, &originalStat), 0)
        XCTAssertEqual(lstat(link.path, &linkStat), 0)
        XCTAssertEqual(originalStat.st_ino, linkStat.st_ino)
        XCTAssertThrowsError(try FileMetadata.createHardLink(to: source, at: link))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        let folder = root.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FileMetadata.createHardLink(to: folder, at: root.appendingPathComponent("folderlink")))
    }

    func testRelativeLinkResolvesFromDestinationDirectory() throws {
        let source = try file("source")
        let directory = root.appendingPathComponent("nested/links")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("relative")
        try FileMetadata.createSymbolicLink(to: source, at: link, relative: true)
        XCTAssertEqual(try FileMetadata.symbolicLinkTarget(at: link), "../../source")
        XCTAssertEqual(try Data(contentsOf: link), Data("original".utf8))
        XCTAssertEqual(FileMetadata.relativePath(to: root, from: root), ".")
    }

    func testDanglingLinkCanBeEditedAndCollisionsPreserveTarget() throws {
        let link = root.appendingPathComponent("dangling")
        try FileMetadata.createSymbolicLink(target: "old-missing", at: link)
        XCTAssertFalse(fm.fileExists(atPath: link.path))
        XCTAssertTrue(try FileMetadata.inspect(link).isSymbolicLink)
        try FileMetadata.editSymbolicLink(at: link, target: "new-missing")
        XCTAssertEqual(try FileMetadata.symbolicLinkTarget(at: link), "new-missing")
        XCTAssertThrowsError(try FileMetadata.createSymbolicLink(target: "third-missing", at: link))
        XCTAssertEqual(try FileMetadata.symbolicLinkTarget(at: link), "new-missing")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), ["dangling"])
        let regular = try file("regular")
        XCTAssertThrowsError(try FileMetadata.editSymbolicLink(at: regular, target: "missing"))
        XCTAssertEqual(try Data(contentsOf: regular), Data("original".utf8))
    }

    func testRelativeLinkThroughSymbolicParentStillResolvesCorrectly() throws {
        let source = try file("source")
        let physical = root.appendingPathComponent("physical/nested")
        try fm.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: physical)
        let link = alias.appendingPathComponent("link")
        try FileMetadata.createSymbolicLink(to: source, at: link, relative: true)
        XCTAssertEqual(try FileMetadata.symbolicLinkTarget(at: link), "../../source")
        XCTAssertEqual(try Data(contentsOf: link), Data("original".utf8))
    }

    func testOwnershipOfDanglingLinkAndInvalidIdentityPreflight() throws {
        let file = try file("file")
        let before = try FileMetadata.inspect(file)
        XCTAssertThrowsError(try FileMetadata.changeOwnership(of: [file], owner: "PaneRookNoSuchUser-\(UUID())", group: nil))
        XCTAssertEqual(try FileMetadata.inspect(file).ownerID, before.ownerID)
        let link = root.appendingPathComponent("dangling")
        try FileMetadata.createSymbolicLink(target: "missing", at: link)
        try FileMetadata.changeOwnership(of: [link], owner: String(getuid()), group: nil)
        XCTAssertEqual(try FileMetadata.inspect(link).ownerID, getuid())
        XCTAssertTrue(try FileMetadata.inspect(link).isSymbolicLink)
    }

    func testNullAndEmptyLinkTargetsAreRejected() throws {
        for target in ["", "one\0two"] {
            XCTAssertThrowsError(try FileMetadata.createSymbolicLink(target: target, at: root.appendingPathComponent("link")))
        }
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("link").path))
    }
}
