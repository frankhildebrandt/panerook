import Foundation
import XCTest
@testable import PaneRookCore

final class ArchiveFileSystemTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    private enum Format: String, CaseIterable {
        case zip, tar, gzip = "tar.gz", tgz
    }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookArchiveTests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult private func file(_ name: String, contents: String = "fixture", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func archive(_ format: Format, files: [String: String], name: String = UUID().uuidString) throws -> URL {
        let input = try directory("input-" + UUID().uuidString)
        for (path, contents) in files { try file(path, contents: contents, in: input) }
        let output = root.appendingPathComponent(name + "." + format.rawValue)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        switch format {
        case .zip: process.arguments = ["--format=zip", "-cf", output.path, "-C", input.path] + files.keys.sorted()
        case .tar: process.arguments = ["-cf", output.path, "-C", input.path] + files.keys.sorted()
        case .gzip, .tgz: process.arguments = ["-czf", output.path, "-C", input.path] + files.keys.sorted()
        }
        process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ArchiveFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: errorData, as: UTF8.self)])
        }
        return output
    }

    private func names(_ directory: URL, hidden: Bool = true) throws -> [String] {
        try FileSystem.list(directory, showHidden: hidden).map(\.name)
    }

    private func exportedContents(_ source: URL) throws -> String {
        let target = try directory("export-" + UUID().uuidString)
        let files = try ArchiveFileSystem.extract([source], to: target)
        return try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
    }

    func testBrowseSupportedArchivesWithImplicitDirectoriesAndLiteralNames() throws {
        for format in Format.allCases {
            let archive = try archive(format, files: [
                "folder/nested.txt": "nested", "10.txt": "ten", "2.txt": "two",
                ".hidden": "hidden", "Grüße [1] $(literal).txt": "Unicode"
            ])
            let before = try fm.contentsOfDirectory(atPath: root.path).sorted()
            let bytes = try Data(contentsOf: archive)
            let entries = try FileSystem.list(archive, showHidden: false)
            XCTAssertEqual(entries.map(\.name), ["folder", "2.txt", "10.txt", "Grüße [1] $(literal).txt"])
            XCTAssertTrue(entries[0].isDirectory)
            XCTAssertEqual(entries[0].url.standardizedFileURL.path, archive.appendingPathComponent("folder").standardizedFileURL.path)
            XCTAssertEqual(try names(archive.appendingPathComponent("folder")), ["nested.txt"])
            XCTAssertTrue(try names(archive).contains(".hidden"))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), before)
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            XCTAssertEqual(try exportedContents(archive.appendingPathComponent("Grüße [1] $(literal).txt")), "Unicode")
        }
    }

    func testVirtualDirectoryResolutionAndArchiveLocation() throws {
        let archive = try archive(.zip, files: ["folder/nested.txt": "hello"])
        XCTAssertEqual(try FileSystem.directory(from: archive.path, relativeTo: root).path, archive.standardizedFileURL.path)
        let folder = archive.appendingPathComponent("folder")
        XCTAssertEqual(try FileSystem.directory(from: "folder", relativeTo: archive).path, folder.standardizedFileURL.path)
        XCTAssertEqual(try FileSystem.directory(from: "..", relativeTo: folder).path, archive.standardizedFileURL.path)
        XCTAssertEqual(ArchiveFileSystem.location(for: folder)?.archiveURL.standardizedFileURL.path, archive.standardizedFileURL.path)
        XCTAssertEqual(ArchiveFileSystem.location(for: folder)?.memberPath, "folder")
        XCTAssertThrowsError(try FileSystem.directory(from: "missing", relativeTo: archive))
        XCTAssertThrowsError(try FileSystem.directory(from: "nested.txt", relativeTo: folder))
        XCTAssertNil(ArchiveFileSystem.location(for: root))
    }

    func testCopyIntoAndOutOfArchivesPreservesExistingMembers() throws {
        for format in [Format.zip, .gzip] {
            let archive = try archive(format, files: ["existing.txt": "keep these bytes"])
            let source = try directory("source-" + UUID().uuidString)
            try file("nested/Grüße.txt", contents: "new content", in: source)
            try TransferPlan(sources: [source], destination: archive, kind: .copy).execute()
            XCTAssertEqual(try exportedContents(archive.appendingPathComponent("existing.txt")), "keep these bytes")
            XCTAssertEqual(try exportedContents(archive.appendingPathComponent(source.lastPathComponent + "/nested/Grüße.txt")), "new content")
            XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("nested/Grüße.txt").path))

            let target = try directory("target-" + UUID().uuidString)
            try TransferPlan(sources: [archive.appendingPathComponent(source.lastPathComponent)], destination: target, kind: .copy).execute()
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(source.lastPathComponent + "/nested/Grüße.txt")), "new content")
            XCTAssertTrue(try names(archive).contains(source.lastPathComponent))
        }
    }

    func testCreateFolderRenameMoveAndRemoveInsideArchives() throws {
        for format in [Format.zip, .gzip] {
            let archive = try archive(format, files: ["original.txt": "rename me", "keep.txt": "keep"])
            let folder = try FileActions.createDirectory(named: "new folder", in: archive)
            XCTAssertTrue(try FileSystem.list(archive, showHidden: true).first { $0.name == "new folder" }?.isDirectory == true)
            XCTAssertTrue(try names(folder).isEmpty)
            try TransferPlan(sources: [archive.appendingPathComponent("original.txt")], sourcePattern: "*",
                             destinationPath: "new folder/renamed.txt", relativeTo: archive, kind: .move).execute()
            XCTAssertFalse(try names(archive).contains("original.txt"))
            XCTAssertEqual(try exportedContents(folder.appendingPathComponent("renamed.txt")), "rename me")
            try ArchiveFileSystem.remove([folder])
            XCTAssertEqual(try names(archive), ["keep.txt"])
            XCTAssertEqual(try exportedContents(archive.appendingPathComponent("keep.txt")), "keep")
        }
    }

    func testMoveBetweenLocalAndArchiveDeletesSourceOnlyAfterTransfer() throws {
        let archive = try archive(.gzip, files: ["keep.txt": "untouched"])
        let local = try file("move me.txt", contents: "moving bytes")
        try TransferPlan(sources: [local], destination: archive, kind: .move).execute()
        XCTAssertFalse(fm.fileExists(atPath: local.path))
        XCTAssertEqual(try exportedContents(archive.appendingPathComponent("move me.txt")), "moving bytes")
        let target = try directory("move-target")
        try TransferPlan(sources: [archive.appendingPathComponent("move me.txt")], destination: target, kind: .move).execute()
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("move me.txt")), "moving bytes")
        XCTAssertEqual(try names(archive), ["keep.txt"])
    }

    func testCopyAndMoveAcrossArchives() throws {
        let source = try archive(.zip, files: ["nested/item.txt": "cross archive", "keep.txt": "source keep"])
        let target = try archive(.gzip, files: ["existing.txt": "target keep"])
        try TransferPlan(sources: [source.appendingPathComponent("nested")], destination: target, kind: .copy).execute()
        XCTAssertEqual(try exportedContents(target.appendingPathComponent("nested/item.txt")), "cross archive")
        XCTAssertTrue(try names(source).contains("nested"))
        try TransferPlan(sources: [source.appendingPathComponent("keep.txt")], destination: target, kind: .move).execute()
        XCTAssertFalse(try names(source).contains("keep.txt"))
        XCTAssertEqual(try exportedContents(target.appendingPathComponent("keep.txt")), "source keep")
        XCTAssertEqual(try exportedContents(target.appendingPathComponent("existing.txt")), "target keep")
    }

    func testSourceMaskAndNewDestinationNameWorkInsideArchive() throws {
        let archive = try archive(.zip, files: ["existing.txt": "keep"])
        let text = try file("notes.txt", contents: "notes")
        let image = try file("image.png", contents: "image")
        let plan = try TransferPlan(sources: [text, image], sourcePattern: "*.txt", destinationPath: archive.path,
                                    relativeTo: root, kind: .copy)
        XCTAssertEqual(plan.items.map(\.source), [text])
        try plan.execute()
        XCTAssertEqual(try names(archive), ["existing.txt", "notes.txt"])
        let target = try directory("renamed-export")
        try TransferPlan(sources: [archive.appendingPathComponent("notes.txt")], sourcePattern: "*",
                         destinationPath: target.appendingPathComponent("renamed.txt").path,
                         relativeTo: archive, kind: .copy).execute()
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("renamed.txt")), "notes")
    }

    func testCollisionPreflightsEntireArchiveBatchWithoutChangingBytesOrSources() throws {
        let archive = try archive(.gzip, files: ["second.txt": "existing"])
        let first = try file("first.txt")
        let second = try file("second.txt", contents: "must not replace")
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try TransferPlan(sources: [first, second], destination: archive, kind: .move))
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try names(archive), ["second.txt"])
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertTrue(fm.fileExists(atPath: second.path))
        XCTAssertThrowsError(try FileActions.createDirectory(named: "second.txt", in: archive))
        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    func testCollisionIntroducedAfterPlanningCannotOverwriteArchive() throws {
        let archive = try archive(.zip, files: ["keep.txt": "keep"])
        let source = try file("late.txt", contents: "old plan")
        let plan = try TransferPlan(sources: [source], destination: archive, kind: .move)
        let concurrent = try file("late.txt", contents: "new archive contents", in: directory("concurrent"))
        try TransferPlan(sources: [concurrent], destination: archive, kind: .copy).execute()
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try plan.execute())
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try exportedContents(archive.appendingPathComponent("late.txt")), "new archive contents")
    }

    func testSameLocationAndRecursiveVirtualTargetsAreRejected() throws {
        let archive = try archive(.zip, files: ["folder/child/item.txt": "nested"])
        let folder = archive.appendingPathComponent("folder")
        XCTAssertThrowsError(try TransferPlan(sources: [folder], destination: archive, kind: .copy))
        XCTAssertThrowsError(try TransferPlan(sources: [folder], destination: folder.appendingPathComponent("child"), kind: .move))
        XCTAssertThrowsError(try TransferPlan(sources: [archive], destination: folder, kind: .copy).execute())
    }

    func testSelectingPhysicalArchiveCopiesArchiveBytes() throws {
        let archive = try archive(.zip, files: ["inside.txt": "inside"])
        let destination = try directory("physical-copy")
        try TransferPlan(sources: [archive], destination: destination, kind: .copy).execute()
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(archive.lastPathComponent)), try Data(contentsOf: archive))
    }

    func testPhysicalArchiveCannotBeMovedIntoItself() throws {
        for format in [Format.zip, .gzip] {
            let archive = try archive(format, files: ["inside.txt": "keep original bytes"])
            let before = try Data(contentsOf: archive)
            XCTAssertThrowsError(try TransferPlan(sources: [archive], destination: archive, kind: .move).execute())
            XCTAssertEqual(try Data(contentsOf: archive), before)
            XCTAssertThrowsError(try TransferPlan(sources: [archive], sourcePattern: "*",
                destinationPath: archive.appendingPathComponent("backup.zip").path,
                relativeTo: root, kind: .move).execute())
            XCTAssertEqual(try Data(contentsOf: archive), before)
            XCTAssertEqual(try names(archive), ["inside.txt"])
        }
    }

    func testEmptyZIPCanReceiveFilesAndBecomeEmptyAgain() throws {
        let archive = root.appendingPathComponent("empty.zip")
        try Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: archive)
        XCTAssertTrue(try names(archive).isEmpty)
        let source = try file("added.txt", contents: "new member")
        try TransferPlan(sources: [source], destination: archive, kind: .copy).execute()
        XCTAssertEqual(try exportedContents(archive.appendingPathComponent("added.txt")), "new member")
        try ArchiveFileSystem.remove([archive.appendingPathComponent("added.txt")])
        XCTAssertTrue(try names(archive).isEmpty)
    }

    func testCorruptArchivesFailWithoutChangingFiles() throws {
        let archive = try file("corrupt.zip", contents: "not an archive")
        let source = try file("source.txt")
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try FileSystem.list(archive, showHidden: true))
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: archive, kind: .move).execute())
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    func testIncomingLinksAreRejectedAndArchiveRemainsUnchanged() throws {
        let archive = try archive(.gzip, files: ["keep.txt": "keep"])
        let outside = try file("outside.txt", contents: "outside")
        let link = root.appendingPathComponent("link.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try TransferPlan(sources: [link], destination: archive, kind: .move).execute())
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(try String(contentsOf: outside), "outside")
    }

    func testIncomingDirectoryContainingLinkCannotPartiallyChangeArchive() throws {
        let archive = try archive(.zip, files: ["keep.txt": "keep"])
        let source = try directory("incoming")
        try file("first.txt", contents: "regular file", in: source)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("last-link").path, withDestinationPath: "/does-not-exist-panerook")
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: archive, kind: .move).execute())
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("first.txt").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent("last-link").path), "/does-not-exist-panerook")
    }

    func testUnsafeArchivePathsCannotEscapeExtractionDirectory() throws {
        for path in ["../escaped.txt", "/tmp/PaneRook-absolute-escape.txt", "folder/../../escaped.txt"] {
            let archive = try rawTar([(path, "attack", "0", "")])
            let destination = try directory("unsafe-" + UUID().uuidString)
            XCTAssertThrowsError(try FileSystem.list(archive, showHidden: true))
            XCTAssertThrowsError(try ArchiveFileSystem.extract([archive.appendingPathComponent("escaped.txt")], to: destination))
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        }
    }

    func testArchiveSymlinksAndHardlinksCannotBeExtractedOrFollowed() throws {
        let outside = try file("outside.txt", contents: "outside remains")
        for kind in ["1", "2"] {
            let archive = try rawTar([("link.txt", "", kind, outside.path)])
            let target = try directory("links-" + UUID().uuidString)
            XCTAssertThrowsError(try ArchiveFileSystem.extract([archive.appendingPathComponent("link.txt")], to: target))
            XCTAssertTrue(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
            XCTAssertEqual(try String(contentsOf: outside), "outside remains")
        }
    }

    func testExistingExtractionSymlinkIsNeverFollowed() throws {
        let archive = try archive(.zip, files: ["folder/nested.txt": "new"])
        let target = try directory("symlink-target")
        let outside = try directory("outside-folder")
        try fm.createSymbolicLink(at: target.appendingPathComponent("folder"), withDestinationURL: outside)
        XCTAssertThrowsError(try ArchiveFileSystem.extract([archive.appendingPathComponent("folder")], to: target))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testSameArchiveRenamePreservesExecutablePermissions() throws {
        let archive = try rawTar([("run.sh", "#!/bin/sh\nexit 0\n", "0", "")], mode: 0o755)
        try TransferPlan(sources: [archive.appendingPathComponent("run.sh")], sourcePattern: "*",
                         destinationPath: "renamed.sh", relativeTo: archive, kind: .move).execute()
        let destination = try directory("executable-export")
        let outputs = try ArchiveFileSystem.extract([archive.appendingPathComponent("renamed.sh")], to: destination)
        let output = try XCTUnwrap(outputs.first)
        let mode = try XCTUnwrap(fm.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o755)
    }

    func testDuplicateMemberPathsRejectMutationWithoutChangingArchive() throws {
        let archive = try rawTar([("duplicate.txt", "first", "0", ""), ("duplicate.txt", "second", "0", "")])
        let before = try Data(contentsOf: archive)
        XCTAssertThrowsError(try FileSystem.list(archive, showHidden: true))
        XCTAssertThrowsError(try FileActions.createDirectory(named: "new", in: archive))
        XCTAssertEqual(try Data(contentsOf: archive), before)
    }

    /// Minimal ustar fixtures allow intentionally invalid member paths and links
    /// without invoking a shell or depending on a third-party ZIP/TAR writer.
    private func rawTar(_ entries: [(path: String, contents: String, type: String, link: String)], mode: Int = 0o644) throws -> URL {
        var data = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ value: String, at offset: Int, length: Int) {
                for (index, byte) in value.utf8.prefix(length).enumerated() { header[offset + index] = byte }
            }
            let body = Data(entry.contents.utf8)
            field(entry.path, at: 0, length: 100)
            field(String(format: "%07o", mode), at: 100, length: 8)
            field("0000000", at: 108, length: 8)
            field("0000000", at: 116, length: 8)
            field(String(format: "%011o", body.count), at: 124, length: 12)
            field("00000000000", at: 136, length: 12)
            field("        ", at: 148, length: 8)
            field(entry.type, at: 156, length: 1)
            field(entry.link, at: 157, length: 100)
            field("ustar", at: 257, length: 6)
            field("00", at: 263, length: 2)
            let checksum = header.reduce(0) { $0 + Int($1) }
            field(String(format: "%06o", checksum) + "\0 ", at: 148, length: 8)
            data.append(contentsOf: header)
            data.append(body)
            if body.count % 512 != 0 { data.append(Data(repeating: 0, count: 512 - body.count % 512)) }
        }
        data.append(Data(repeating: 0, count: 1024))
        let url = root.appendingPathComponent(UUID().uuidString + ".tar")
        try data.write(to: url)
        return url
    }
}
