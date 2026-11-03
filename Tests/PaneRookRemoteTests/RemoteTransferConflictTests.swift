import XCTest
@testable import PaneRookRemote

final class RemoteTransferConflictTests: XCTestCase {
    /// Stateful transport contract fixture: primitive mutations are real file
    /// operations, with failures injected at the upload/publication boundaries.
    private final class Transport: RemoteTransport {
        let root: URL
        var onUpload: ((String) throws -> Void)?
        var onMove: ((String, String, RemoteCancellation) throws -> Void)?
        var failDownload = false
        let fm = FileManager.default
        init(root: URL) { self.root = root }
        func url(_ path: String) -> URL { root.appendingPathComponent(String(path.dropFirst())) }
        func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
            try token.check()
            return try fm.contentsOfDirectory(at: url(path), includingPropertiesForKeys: nil).map {
                let attributes = try fm.attributesOfItem(atPath: $0.path)
                return RemoteEntry(name: $0.lastPathComponent, isDirectory: attributes[.type] as? FileAttributeType == .typeDirectory,
                                   isSymbolicLink: attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                                   size: (attributes[.size] as? NSNumber)?.int64Value ?? 0, modified: attributes[.modificationDate] as? Date)
            }
        }
        func createDirectory(_ path: String, token: RemoteCancellation) throws { try token.check(); try fm.createDirectory(at: url(path), withIntermediateDirectories: false) }
        func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
            try token.check(); try fm.copyItem(at: url(path), to: destination)
            if failDownload { throw RemoteError.process("download failed") }
        }
        func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
            try token.check(); try fm.copyItem(at: source, to: url(path)); try onUpload?(path)
        }
        func move(_ path: String, to destination: String, token: RemoteCancellation) throws {
            try token.check(); try onMove?(path, destination, token); try fm.moveItem(at: url(path), to: url(destination))
        }
        func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
            try token.check()
            if directory {
                guard try fm.contentsOfDirectory(atPath: url(path).path).isEmpty else { throw RemoteError.sourceChanged }
            }
            try fm.removeItem(at: url(path))
        }
    }
    private var root: URL!
    private var local: URL!
    private var remote: URL!
    private var transport: Transport!
    private var fs: RemoteFileSystem!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookRemoteConflicts-" + UUID().uuidString)
        local = root.appendingPathComponent("local"); remote = root.appendingPathComponent("remote")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: remote, withIntermediateDirectories: false)
        transport = Transport(root: remote)
        fs = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "test", port: 22, user: "user"), transport: transport)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func file(_ path: String, _ text: String = "new", in parent: URL? = nil) throws -> URL {
        let result = (parent ?? local).appendingPathComponent(path)
        try fm.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: result); return result
    }
    private func assertClean() throws {
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: remote.path).contains { $0.hasPrefix(".panerook-") })
    }
    func testUploadSkipMovePreservesSourceAndKeepBothUsesUnusedName() throws {
        let source = try file("file.txt")
        try file("file.txt", "old", in: remote); try file("file (2).txt", "other", in: remote)
        try fs.upload(source, to: "/", movingSource: true, resolveConflict: { _ in .skip })
        XCTAssertEqual(try String(contentsOf: source), "new")
        try fs.upload(source, to: "/", movingSource: true, resolveConflict: { _ in .keepBoth })
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file (3).txt")), "new")
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file.txt")), "old")
    }
    func testUploadReplaceAndMoveCleanBackup() throws {
        let source = try file("file")
        try file("file", "old", in: remote)
        try fs.upload(source, to: "/", movingSource: true, resolveConflict: { _ in .replace })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file")), "new")
        XCTAssertFalse(fm.fileExists(atPath: source.path)); try assertClean()
    }
    func testFailedUploadReplacementLeavesOldTargetAndSource() throws {
        let source = try file("file")
        try file("file", "old", in: remote)
        transport.onUpload = { _ in throw RemoteError.process("disconnected") }
        XCTAssertThrowsError(try fs.upload(source, to: "/", movingSource: true, resolveConflict: { _ in .replace }))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file")), "old")
        XCTAssertTrue(fm.fileExists(atPath: source.path)); try assertClean()
    }
    func testFailedPublicationRestoresOriginalFromBackup() throws {
        let source = try file("file")
        try file("file", "old", in: remote)
        transport.onMove = { from, to, _ in
            if from.hasPrefix("/.panerook-transfer-") && to == "/file" { throw RemoteError.process("publish failed") }
        }
        XCTAssertThrowsError(try fs.upload(source, to: "/", resolveConflict: { _ in .replace }))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file")), "old"); try assertClean()
    }
    func testCancellationAfterBackupUsesIndependentRestorationToken() throws {
        let source = try file("file")
        try file("file", "old", in: remote)
        let token = RemoteCancellation()
        transport.onMove = { from, _, token in if from == "/file" { token.cancel() } }
        XCTAssertThrowsError(try fs.upload(source, to: "/", resolveConflict: { _ in .replace }, cancellation: token))
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("file")), "old"); try assertClean()
    }
    func testFailedRestorationRetainsBackupAndReportsItsPath() throws {
        let source = try file("file")
        try file("file", "old", in: remote)
        transport.onMove = { from, _, _ in
            if from.hasPrefix("/.panerook-transfer-") || from.hasPrefix("/.panerook-backup-") { throw RemoteError.process("rename failed") }
        }
        XCTAssertThrowsError(try fs.upload(source, to: "/", resolveConflict: { _ in .replace })) {
            XCTAssertTrue($0.localizedDescription.contains("/.panerook-backup-"))
        }
        let backup = try XCTUnwrap(fm.contentsOfDirectory(atPath: remote.path).first { $0.hasPrefix(".panerook-backup-") })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent(backup)), "old")
    }
    func testConcurrentTargetChangeDuringPromptIsPreserved() throws {
        let source = try file("file")
        let old = try file("file", "old", in: remote)
        XCTAssertThrowsError(try fs.upload(source, to: "/", resolveConflict: { _ in
            try Data("newer version".utf8).write(to: old); return .replace
        }))
        XCTAssertEqual(try String(contentsOf: old), "newer version"); try assertClean()
    }
    func testUploadMergeMoveRemovesOnlyTransferredChildren() throws {
        let source = try file("folder/skip").deletingLastPathComponent()
        try file("folder/new"); try file("folder/skip", "old", in: remote); try file("folder/unrelated", in: remote)
        try fs.upload(source, to: "/", movingSource: true, resolveConflict: {
            $0.sourceEntry.isDirectory ? .merge : .skip
        })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.path), ["skip"])
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("folder/new")), "new")
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("folder/skip")), "old")
    }
    func testFailedDownloadReplaceKeepsLocalOriginal() throws {
        try file("file", in: remote)
        let old = try file("file", "old")
        transport.failDownload = true
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "file", isDirectory: false), from: "/", to: old, resolveConflict: { _ in .replace }))
        XCTAssertEqual(try String(contentsOf: old), "old")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: local.path), ["file"])
    }
    func testDownloadMergeMoveKeepsSkippedRemoteChildren() throws {
        try file("folder/skip", in: remote); try file("folder/new", in: remote)
        try file("folder/skip", "old"); try file("folder/unrelated")
        let entry = try XCTUnwrap(fs.list("/").first { $0.name == "folder" })
        try fs.move(entry, from: "/", to: local.appendingPathComponent("folder"), resolveConflict: { $0.sourceEntry.isDirectory ? .merge : .skip })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: remote.appendingPathComponent("folder").path), ["skip"])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("folder/new")), "new")
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent("folder/skip")), "old")
    }
    func testRemoteMergeMoveAndSelfCopyKeepBoth() throws {
        try file("from/folder/skip", in: remote); try file("from/folder/new", in: remote)
        try file("to/folder/skip", "old", in: remote); try file("to/folder/unrelated", in: remote)
        let entry = try XCTUnwrap(fs.list("/from").first)
        try fs.move(entry, from: "/from", to: fs, directory: "/to", resolveConflict: { $0.sourceEntry.isDirectory ? .merge : .skip })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: remote.appendingPathComponent("from/folder").path), ["skip"])
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("to/folder/new")), "new")
        try fs.copy(entry, from: "/from", to: fs, directory: "/from", resolveConflict: {
            XCTAssertEqual($0.allowedActions, [.skip, .keepBoth]); return .keepBoth
        })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("from/folder (2)/skip")), "new")
    }
    func testAcrossConnectionsReplaceMoveAndSelfMovePreserveTarget() throws {
        try file("from/file", in: remote); try file("to/file", "old", in: remote)
        let other = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "other", port: 22, user: "user"), transport: transport)
        let entry = try XCTUnwrap(fs.list("/from").first)
        try fs.move(entry, from: "/from", to: other, directory: "/to", resolveConflict: { conflict in
            XCTAssertTrue(conflict.source.hasPrefix("sftp://user@test:22/from/file"))
            return .replace
        })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("to/file")), "new")
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("from/file").path))
        let moved = try XCTUnwrap(fs.list("/to").first)
        try fs.move(moved, from: "/to", to: fs, directory: "/to", resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("to/file")), "new")
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("to/file (2)")), "new")
        try assertClean()
    }
    func testRemoteTypeConflictReplaceAndLinksStayUnsupported() throws {
        let source = try file("folder/new").deletingLastPathComponent()
        try file("folder", "old", in: remote)
        try fs.upload(source, to: "/", resolveConflict: { conflict in
            XCTAssertFalse(conflict.allowedActions.contains(.merge)); return .replace
        })
        XCTAssertEqual(try String(contentsOf: remote.appendingPathComponent("folder/new")), "new")
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "link", isDirectory: false, isSymbolicLink: true), from: "/", to: local.appendingPathComponent("link"), resolveConflict: { _ in .replace }))
        try assertClean()
    }
}
