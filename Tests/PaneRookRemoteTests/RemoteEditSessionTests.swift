import Foundation
import XCTest
@testable import PaneRookRemote

final class RemoteEditSessionTests: XCTestCase {
    private final class Transport: RemoteTransport {
        var supportsExclusiveRename = true
        var files: [String: Data] = ["/docs/file.txt": Data("original".utf8)]
        var modified = Date(timeIntervalSince1970: 100)
        var failUpload = false
        var failPublish = false
        var onUpload: (() throws -> Void)?
        var onMove: ((String, String) throws -> Void)?
        var onDownload: ((String) throws -> Void)?
        var calls: [String] = []
        func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
            try token.check()
            return files.compactMap { key, bytes in
                guard (key as NSString).deletingLastPathComponent == path else { return nil }
                return RemoteEntry(name: (key as NSString).lastPathComponent, isDirectory: false, size: Int64(bytes.count), modified: modified)
            }
        }
        func createDirectory(_ path: String, token: RemoteCancellation) throws {}
        func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
            try token.check()
            guard let bytes = files[path] else { throw RemoteError.process("missing") }
            try bytes.write(to: destination); try onDownload?(path)
        }
        func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
            try token.check(); calls.append("upload " + path)
            if failUpload { throw RemoteError.process("offline") }
            files[path] = try Data(contentsOf: source)
            try onUpload?()
        }
        func move(_ path: String, to destination: String, token: RemoteCancellation) throws {
            try token.check(); calls.append("move " + path)
            try onMove?(path, destination)
            if failPublish && destination == "/docs/file.txt" { throw RemoteError.process("publish failed") }
            guard files[destination] == nil else { throw RemoteError.collision(destination) }
            guard let bytes = files.removeValue(forKey: path) else { throw RemoteError.process("missing") }
            files[destination] = bytes
        }
        func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws { files.removeValue(forKey: path) }
    }
    private func fixture(_ transport: Transport = Transport()) throws -> (Transport, RemoteFileSystem, URL, RemoteEditSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let connection = try RemoteConnection(kind: .sftp, host: "host.test", port: 22, user: "me", password: "not-persisted")
        let fs = RemoteFileSystem(connection: connection, transport: transport)
        let session = try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/file.txt", root: root)
        return (transport, fs, root, session)
    }
    private func change(_ session: RemoteEditSession, to text: String = "my changes") throws {
        try Data(text.utf8).write(to: session.workingURL, options: .atomic)
        try session.pollChanges(now: Date(timeIntervalSince1970: 1000))
        try session.pollChanges(now: Date(timeIntervalSince1970: 1002))
    }
    func testWritableCopyStableBurstDetectionAndAtomicSave() throws {
        let (_, _, _, session) = try fixture()
        let permissions = try FileManager.default.attributesOfItem(atPath: session.workingURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertFalse(session.snapshot.hasChanges)
        try Data("new".utf8).write(to: session.workingURL, options: .atomic)
        try session.pollChanges(now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(session.snapshot.message.contains("abgewartet"))
        try Data("newest".utf8).write(to: session.workingURL, options: .atomic)
        try session.pollChanges(now: Date(timeIntervalSince1970: 1.5))
        try session.pollChanges(now: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(session.snapshot.message.contains("abgewartet"))
        try session.pollChanges(now: Date(timeIntervalSince1970: 3))
        XCTAssertTrue(session.snapshot.hasChanges)
        XCTAssertTrue(session.snapshot.message.contains("bereit"))
    }
    func testSuccessfulUploadRetainsServerBackupAndWorkingCopy() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        XCTAssertEqual(try session.upload(), .uploaded)
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("my changes".utf8))
        let backup = try XCTUnwrap(session.snapshot.serverArtifacts.first { $0.hasSuffix(".backup") })
        XCTAssertEqual(transport.files[backup], Data("original".utf8))
        XCTAssertFalse(session.snapshot.hasChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workingURL.path))
        XCTAssertEqual(try session.upload(), .unchanged)
    }
    func testSameSizeAndTimestampConflictRequiresExactApproval() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        transport.files["/docs/file.txt"] = Data("external".utf8) // same size, same timestamp
        guard case .conflict(let first) = try session.upload() else { return XCTFail("Expected conflict") }
        XCTAssertFalse(transport.calls.contains { $0.hasPrefix("upload") })
        transport.files["/docs/file.txt"] = Data("another!".utf8)
        guard case .conflict(let second) = try session.upload(approving: first) else { return XCTFail("Must revalidate approval") }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try session.upload(approving: second), .uploaded)
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("my changes".utf8))
        XCTAssertTrue(transport.files.values.contains(Data("another!".utf8)))
    }
    func testChangesDuringUploadStayDirtyAndDoNotEnterUploadedSnapshot() throws {
        let (transport, _, _, session) = try fixture()
        try change(session, to: "first save")
        transport.onUpload = { try Data("second save".utf8).write(to: session.workingURL, options: .atomic) }
        XCTAssertEqual(try session.upload(), .uploaded)
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("first save".utf8))
        XCTAssertEqual(try String(contentsOf: session.workingURL), "second save")
        XCTAssertTrue(session.snapshot.hasChanges)
    }
    func testServerChangesDuringStagingAndAtBackupArePreserved() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        transport.onUpload = { transport.files["/docs/file.txt"] = Data("external".utf8) }
        guard case .conflict = try session.upload() else { return XCTFail("Expected conflict") }
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("external".utf8))
        transport.onUpload = nil
        let revision = try XCTUnwrap(session.snapshot.conflict)
        transport.onMove = { source, _ in
            if source == "/docs/file.txt" { transport.files[source] = Data("racing writer".utf8) }
        }
        XCTAssertThrowsError(try session.upload(approving: revision))
        XCTAssertTrue(transport.files.values.contains(Data("racing writer".utf8)))
        XCTAssertFalse(transport.files.values.contains(Data("my changes".utf8)) && transport.files["/docs/file.txt"] != nil)
        XCTAssertTrue(session.snapshot.hasChanges)
    }
    func testTargetCreatedBeforePublicationIsNeverOverwritten() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        transport.onMove = { source, destination in
            if source.hasSuffix(".upload") { transport.files[destination] = Data("new writer".utf8) }
        }
        XCTAssertThrowsError(try session.upload())
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("new writer".utf8))
        XCTAssertTrue(transport.files.values.contains(Data("original".utf8)))
        XCTAssertEqual(try String(contentsOf: session.workingURL), "my changes")
    }
    func testNetworkFailureRetryAndCancellationKeepCopy() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        transport.failUpload = true
        XCTAssertThrowsError(try session.upload())
        XCTAssertEqual(session.snapshot.phase, .failed)
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("original".utf8))
        let token = RemoteCancellation(); token.cancel()
        XCTAssertThrowsError(try session.upload(cancellation: token))
        XCTAssertEqual(try String(contentsOf: session.workingURL), "my changes")
        transport.failUpload = false
        XCTAssertEqual(try session.upload(), .uploaded)
    }
    func testInterruptedPublicationCanBeRecoveredWithExplicitMissingRevisionApproval() throws {
        let (transport, fs, root, session) = try fixture()
        try change(session)
        transport.failPublish = true
        XCTAssertThrowsError(try session.upload())
        XCTAssertNil(transport.files["/docs/file.txt"])
        XCTAssertTrue(transport.files.values.contains(Data("original".utf8)))
        let reopened = try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/file.txt", root: root)
        XCTAssertTrue(reopened.snapshot.hasChanges)
        XCTAssertFalse(reopened.snapshot.serverArtifacts.isEmpty)
        transport.failPublish = false
        guard case .conflict(let missing) = try reopened.upload() else { return XCTFail("Expected missing revision conflict") }
        XCTAssertNil(missing.digest)
        XCTAssertEqual(try reopened.upload(approving: missing), .uploaded)
    }
    func testResumingNeverRedownloadsOrPersistsPasswordAndSeparatesFilesAndEndpoints() throws {
        let (transport, fs, root, session) = try fixture()
        try change(session)
        transport.onDownload = { _ in XCTFail("Resume must not download") }
        let reopened = try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/./file.txt", root: root)
        XCTAssertEqual(reopened.workingURL.resolvingSymlinksInPath().path, session.workingURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: reopened.workingURL), "my changes")
        XCTAssertTrue(reopened.snapshot.hasChanges)
        XCTAssertFalse(try String(contentsOf: session.workspace.appendingPathComponent("session.json")).contains("not-persisted"))
        transport.onDownload = nil; transport.files["/elsewhere/file.txt"] = Data("second file".utf8)
        let second = try RemoteEditSession.prepare(fileSystem: fs, path: "/elsewhere/file.txt", root: root)
        XCTAssertNotEqual(second.workingURL, session.workingURL)
        let otherFS = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "other.test", port: 22, user: "me"), transport: transport)
        XCTAssertNotEqual(try RemoteEditSession.prepare(fileSystem: otherFS, path: "/docs/file.txt", root: root).workingURL, session.workingURL)
    }
    func testMissingOrSymlinkLocalFileAndUnsafeFTPLeaveServerUntouched() throws {
        let (transport, _, _, session) = try fixture()
        try FileManager.default.removeItem(at: session.workingURL)
        XCTAssertThrowsError(try session.pollChanges())
        XCTAssertThrowsError(try session.upload())
        let unrelated = session.workspace.appendingPathComponent("unrelated")
        try Data("not for upload".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: session.workingURL, withDestinationURL: unrelated)
        XCTAssertThrowsError(try session.upload())
        try FileManager.default.removeItem(at: session.workingURL)
        try change(session)
        transport.supportsExclusiveRename = false
        XCTAssertThrowsError(try session.upload())
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertEqual(transport.files["/docs/file.txt"], Data("original".utf8))
    }
    func testPrepareRejectsCancellationAndChangingServerWithoutExposingCopy() throws {
        let (transport, fs, root, _) = try fixture()
        transport.files["/docs/second.txt"] = Data("second".utf8)
        let token = RemoteCancellation(); token.cancel()
        XCTAssertThrowsError(try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/second.txt", root: root, cancellation: token))
        transport.onDownload = { _ in transport.modified = transport.modified.addingTimeInterval(1) }
        XCTAssertThrowsError(try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/second.txt", root: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }
    func testSystemSFTPEditPublishesAndRenameRejectsConcurrentTarget() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System-sftp-server fehlt") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("edit [1]*?.txt")
        try Data("server original".utf8).write(to: file)
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "test", port: 22, user: "")) { invocation, token in
            var direct = invocation
            if invocation.executable == "/usr/bin/ssh" {
                direct.executable = "/usr/libexec/sftp-server"; direct.arguments = []
            } else {
                direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            }
            return try RemoteFileSystem.run(direct, token)
        }
        let session = try RemoteEditSession.prepare(fileSystem: fs, path: file.path, root: root.appendingPathComponent("copies"))
        try change(session)
        XCTAssertEqual(try session.upload(), .uploaded)
        XCTAssertEqual(try String(contentsOf: file), "my changes")
        let backup = try XCTUnwrap(session.snapshot.serverArtifacts.first { $0.hasSuffix(".backup") })
        XCTAssertEqual(try String(contentsOfFile: backup), "server original")
        let candidate = root.appendingPathComponent("candidate")
        try Data("candidate".utf8).write(to: candidate)
        XCTAssertThrowsError(try fs.transport.moveExclusively(candidate.path, to: file.path, token: RemoteCancellation()))
        XCTAssertEqual(try String(contentsOf: file), "my changes")
        XCTAssertEqual(try String(contentsOf: candidate), "candidate")
    }
    func testReentrantUploadIsRejectedAndCancellationAfterBackupRetainsBothCopies() throws {
        let (transport, _, _, session) = try fixture()
        try change(session)
        let token = RemoteCancellation()
        transport.onUpload = {
            XCTAssertEqual(session.snapshot.phase, .uploading)
            XCTAssertThrowsError(try session.upload()) { error in
                guard case RemoteEditError.busy = error else { return XCTFail("Expected busy") }
            }
        }
        transport.onMove = { source, _ in if source == "/docs/file.txt" { token.cancel() } }
        XCTAssertThrowsError(try session.upload(cancellation: token))
        XCTAssertTrue(transport.files.values.contains(Data("original".utf8)))
        XCTAssertEqual(try String(contentsOf: session.workingURL), "my changes")
        XCTAssertTrue(session.snapshot.hasChanges)
        XCTAssertFalse(session.snapshot.isBusy)
    }
    func testCorruptManifestIsReportedWithoutDeletingLocalChanges() throws {
        let (_, fs, root, session) = try fixture()
        try change(session)
        try Data("corrupt".utf8).write(to: session.workspace.appendingPathComponent("session.json"))
        XCTAssertThrowsError(try RemoteEditSession.prepare(fileSystem: fs, path: "/docs/file.txt", root: root))
        XCTAssertEqual(try String(contentsOf: session.workingURL), "my changes")
    }

    func testExclusiveSFTPResponseRequiresVersionMatchingStatusAndCompleteFrames() throws {
        let version = SFTPRenamePacket.packet(Data([2]) + SFTPRenamePacket.integer(3))
        let success = SFTPRenamePacket.packet(Data([101]) + SFTPRenamePacket.integer(1) + SFTPRenamePacket.integer(0))
        XCTAssertNoThrow(try SFTPRenamePacket.validate(version + success))
        for response in [Data(), Data([0, 0, 0]), version, success, version + success.dropLast(),
                         version + SFTPRenamePacket.packet(Data([101]) + SFTPRenamePacket.integer(2) + SFTPRenamePacket.integer(0)),
                         version + SFTPRenamePacket.packet(Data([101]) + SFTPRenamePacket.integer(1) + SFTPRenamePacket.integer(4))] {
            XCTAssertThrowsError(try SFTPRenamePacket.validate(response))
        }
    }

}
