import Foundation
import XCTest

@testable import PaneRookRemote

final class RemoteTransportContractTests: XCTestCase {
    private final class Transport: RemoteTransport {
        var entries: [RemoteEntry] = []
        var calls: [String] = []
        var failDownload = false
        var failUpload = false
        var uploadedData: Data?
        var uploadSource: URL?
        var onList: (() -> Void)?
        var listingsByPath: [String: [RemoteEntry]] = [:]
        var onDownload: (() -> Void)?
        var onUpload: (() -> Void)?
        var onCreateDirectory: ((String) -> Void)?
        func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
            calls.append("list " + path)
            onList?()
            return listingsByPath[path] ?? entries
        }
        func createDirectory(_ path: String, token: RemoteCancellation) throws {
            calls.append("mkdir " + path); onCreateDirectory?(path)
        }
        func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
            calls.append("download " + path)
            try Data("partial".utf8).write(to: destination)
            onDownload?()
            if failDownload { throw RemoteError.process("interrupted") }
        }
        func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
            calls.append("upload " + path)
            uploadSource = source
            uploadedData = try Data(contentsOf: source)
            onUpload?()
            if failUpload { throw RemoteError.process("upload interrupted") }
        }
        func move(_ path: String, to destination: String, token: RemoteCancellation) throws {
            calls.append("move " + path + " -> " + destination)
        }
        func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
            calls.append("remove " + path)
        }
    }
    private func bridge(_ transport: Transport, host: String = "example.org") throws -> RemoteFileSystem {
        RemoteFileSystem(
            connection: try RemoteConnection(kind: .sftp, host: host, port: 22, user: "user"),
            transport: transport)
    }
    func testCollisionPolicyAppliesBeforeCallingAnyProviderMutation() throws {
        let transport = Transport()
        transport.entries = [RemoteEntry(name: "exists", isDirectory: true)]
        XCTAssertThrowsError(try bridge(transport).createDirectory("/exists"))
        XCTAssertEqual(transport.calls, ["list /"])
    }
    func testFailedProviderDownloadCannotPublishPartialFileAndCleansStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = Transport()
        transport.failDownload = true
        XCTAssertThrowsError(
            try bridge(transport).download(
                RemoteEntry(name: "file", isDirectory: false), from: "/", to: root.appendingPathComponent("file")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertEqual(transport.calls, ["download /file"])
    }
    func testCancellationStopsBeforeProviderInvocation() throws {
        let transport = Transport()
        let token = RemoteCancellation()
        token.cancel()
        XCTAssertThrowsError(try bridge(transport).list("/", cancellation: token))
        XCTAssertTrue(transport.calls.isEmpty)
    }
    func testAllProvidersExposeUIAndValidConnectionPolicy() throws {
        XCTAssertEqual(Set(RemoteProtocol.available).count, 4)
        for kind in RemoteProtocol.available {
            let connection = try RemoteConnection(
                kind: kind, host: "example.org", port: kind.provider.defaultPort, user: "user")
            XCTAssertFalse(connection.displayName.isEmpty)
            XCTAssertFalse(kind.provider.menuTitle.isEmpty)
            XCTAssertFalse(kind.provider.notice.isEmpty)
            XCTAssertFalse(kind.provider.deleteNotice.isEmpty)
        }
        XCTAssertEqual(RemoteProtocol.nextcloud.provider.defaultPort, 443)
        XCTAssertTrue(RemoteProtocol.nextcloud.provider.usesPassword)
        XCTAssertFalse(RemoteProtocol.sftp.provider.usesPassword)
    }

    func testNativeMoveNormalizesPathsAndRejectsCollisionsOrDescendants() throws {
        let transport = Transport(), entry = RemoteEntry(name: "folder", isDirectory: true)
        let fs = try bridge(transport)
        try fs.move(entry, from: "/home", to: "../renamed")
        XCTAssertEqual(transport.calls, ["list /", "move /home/folder -> /renamed"])
        transport.calls = []
        try fs.move(entry, from: "/home", to: "folder")
        XCTAssertTrue(transport.calls.isEmpty, "Moving an entry to itself is a no-op")
        XCTAssertThrowsError(try fs.move(entry, from: "/home", to: "/"))
        XCTAssertThrowsError(try fs.move(entry, from: "/home", to: "folder/child"))
        XCTAssertThrowsError(try fs.move(RemoteEntry(name: "..", isDirectory: true), from: "/home", to: "/elsewhere"))
        XCTAssertTrue(transport.calls.isEmpty)
        transport.entries = [RemoteEntry(name: "exists", isDirectory: false)]
        XCTAssertThrowsError(try fs.move(entry, from: "/home", to: "/exists"))
        XCTAssertEqual(transport.calls, ["list /"])
    }

    func testMoveChecksCancellationAgainAfterCollisionQuery() throws {
        let transport = Transport(), token = RemoteCancellation()
        transport.onList = { token.cancel() }
        XCTAssertThrowsError(try bridge(transport).move(RemoteEntry(name: "file", isDirectory: false), from: "/", to: "/new", cancellation: token))
        XCTAssertEqual(transport.calls, ["list /"])
    }

    func testRemoteCopyStagesCompleteBytesAndCleansTemporaryFiles() throws {
        let source = Transport(), target = Transport()
        try bridge(source).copy(RemoteEntry(name: "file", isDirectory: false), from: "/source",
                                to: bridge(target, host: "target.org"), directory: "/destination")
        XCTAssertEqual(source.calls, ["download /source/file"])
        XCTAssertEqual(target.calls, ["list /destination", "list /destination", "upload /destination/file"])
        XCTAssertEqual(target.uploadedData, Data("partial".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(target.uploadSource).deletingLastPathComponent().path))
    }

    func testCrossConnectionMovePreservesSourceOnFailedCopyAndRemovesItAfterSuccess() throws {
        let source = Transport(), target = Transport(), entry = RemoteEntry(name: "file", isDirectory: false)
        let fs = try bridge(source), destination = try bridge(target, host: "target.org")
        source.entries = [entry]
        target.failUpload = true
        XCTAssertThrowsError(try fs.move(entry, from: "/source", to: destination, directory: "/target"))
        XCTAssertEqual(source.calls, ["list /source", "download /source/file"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(target.uploadSource).path))
        source.calls = []; target.calls = []; target.failUpload = false
        try fs.move(entry, from: "/source", to: destination, directory: "/target")
        XCTAssertEqual(source.calls, ["list /source", "download /source/file", "list /source", "list /source", "remove /source/file"])
    }

    func testSameEndpointMoveDoesNotDownloadAndCopyCollisionDoesNotReadSource() throws {
        let source = Transport(), target = Transport(), entry = RemoteEntry(name: "file", isDirectory: false)
        try bridge(source).move(entry, from: "/source", to: bridge(target), directory: "/destination")
        XCTAssertEqual(source.calls, ["list /destination", "move /source/file -> /destination/file"])
        XCTAssertTrue(target.calls.isEmpty)
        source.calls = []; target.entries = [entry]
        XCTAssertThrowsError(try bridge(source).copy(entry, from: "/source", to: bridge(target), directory: "/destination"))
        XCTAssertTrue(source.calls.isEmpty)
        XCTAssertEqual(target.calls, ["list /destination"])
    }

    func testCrossConnectionMoveDoesNotDeleteDestinationNestedViaAnotherAlias() throws {
        let source = Transport(), target = Transport()
        let folder = RemoteEntry(name: "folder", isDirectory: true), sub = RemoteEntry(name: "sub", isDirectory: true)
        source.listingsByPath = ["/source": [folder], "/source/folder": [sub], "/source/folder/sub": []]
        target.onCreateDirectory = { path in
            if path == "/source/folder/sub/folder" { source.listingsByPath["/source/folder/sub"] = [folder] }
        }
        XCTAssertThrowsError(try bridge(source).move(folder, from: "/source", to: bridge(target, host: "alias.org"), directory: "/source/folder/sub")) { error in
            guard case RemoteError.sourceChanged = error else { return XCTFail("Expected changed source, got \(error)") }
        }
        XCTAssertFalse(source.calls.contains { $0.hasPrefix("remove ") })
        XCTAssertTrue(target.calls.contains("mkdir /source/folder/sub/folder"))
        XCTAssertEqual(source.listingsByPath["/source/folder/sub"], [folder])
    }

    func testRemoteToLocalMoveRetainsFilesAddedDuringDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Transport()
        let folder = RemoteEntry(name: "folder", isDirectory: true), file = RemoteEntry(name: "file", isDirectory: false)
        source.listingsByPath = ["/source": [folder], "/source/folder": [file]]
        source.onDownload = { source.listingsByPath["/source/folder"] = [file, RemoteEntry(name: "new", isDirectory: false)] }
        XCTAssertThrowsError(try bridge(source).move(folder, from: "/source", to: root.appendingPathComponent("folder")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/file").path))
        XCTAssertFalse(source.calls.contains { $0.hasPrefix("remove ") })
    }

    func testLocalToRemoteMoveRetainsFilesAddedDuringUpload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("file"))
        let target = Transport()
        target.onUpload = { try? Data("new".utf8).write(to: root.appendingPathComponent("new")) }
        XCTAssertThrowsError(try bridge(target).upload(root, to: "/destination", movingSource: true))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file")), "original")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new")), "new")
    }

    func testLocalToRemoteMoveRemovesUnchangedSourceTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original".utf8).write(to: root.appendingPathComponent("nested/file"))
        let target = Transport()
        try bridge(target).upload(root, to: "/destination", movingSource: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(target.uploadedData, Data("original".utf8))
    }
}
