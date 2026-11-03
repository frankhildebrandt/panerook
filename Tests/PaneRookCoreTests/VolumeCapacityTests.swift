import Foundation
import XCTest
@testable import PaneRookCore

final class VolumeCapacityTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookCapacityTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    func testRealDirectoryReturnsNonnegativeCapacity() throws {
        let capacity = try XCTUnwrap(FileSystem.availableCapacity(at: root))
        XCTAssertGreaterThanOrEqual(capacity, 0)
    }

    func testSymlinkToDirectoryReturnsCapacity() throws {
        let target = root.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertGreaterThanOrEqual(try XCTUnwrap(FileSystem.availableCapacity(at: target)), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(FileSystem.availableCapacity(at: link)), 0)
    }

    func testMissingFilesDanglingLinksAndNonlocalURLsHaveNoCapacity() throws {
        let file = root.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let link = root.appendingPathComponent("dangling")
        try fm.createSymbolicLink(at: link, withDestinationURL: missing)

        for url in [file, missing, link,
                    URL(fileURLWithPath: root.path + "/invalid\0directory"),
                    try XCTUnwrap(URL(string: "https://example.invalid/directory")),
                    try XCTUnwrap(URL(string: "sftp://example.invalid/directory")),
                    try XCTUnwrap(URL(string: "file://example.invalid" + root.path))] {
            XCTAssertNil(FileSystem.availableCapacity(at: url), url.absoluteString)
        }
    }

    func testRealDirectoryWithArchiveExtensionStillHasCapacity() throws {
        let directory = root.appendingPathComponent("directory.zip", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertNotNil(FileSystem.availableCapacity(at: directory))
    }

    func testArchiveAndSyntheticMemberDirectoryHaveNoCapacity() throws {
        let input = root.appendingPathComponent("input", isDirectory: true)
        let folder = input.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let archive = root.appendingPathComponent("fixture.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", archive.path, "-C", input.path, "folder"]
        process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let member = archive.appendingPathComponent("folder")
        XCTAssertEqual(try FileSystem.list(member, showHidden: true).map(\.name), ["file.txt"])

        XCTAssertNil(FileSystem.availableCapacity(at: archive))
        XCTAssertNil(FileSystem.availableCapacity(at: member))
        let link = root.appendingPathComponent("archive-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: archive)
        XCTAssertNil(FileSystem.availableCapacity(at: link))
    }
}
