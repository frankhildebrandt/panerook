import Foundation
import XCTest
@testable import PaneRookCore

final class RemoteFileSystemTests: XCTestCase {
    func testRemotePathsStayAbsoluteAndRejectCommandLines() throws {
        XCTAssertEqual(try RemoteFileSystem.normalizedPath("../folder/./file", relativeTo: "/home/me"), "/home/folder/file")
        XCTAssertEqual(try RemoteFileSystem.normalizedPath("../../.."), "/")
        XCTAssertThrowsError(try RemoteFileSystem.normalizedPath("a\nrm /"))
        XCTAssertThrowsError(try RemoteConnection(kind: .shell, host: "-oProxyCommand=touch /tmp/x", port: 22, user: "me"))
        XCTAssertThrowsError(try RemoteConnection(kind: .ftp, host: "example.test", port: 0, user: "me"))
        XCTAssertThrowsError(try RemoteConnection(kind: .ftp, host: "example.test", port: 21, user: "me", password: "line\nbreak"))
    }

    func testMachineReadableFTPListingPreservesNamesAndMetadata() throws {
        let data = Data("type=cdir; .\r\ntype=pdir; ..\r\ntype=file;size=1234;modify=20261031102559; report one.txt\r\ntype=dir;modify=20261030000000; Assets\r\n".utf8)
        let entries = try RemoteFileSystem.parseMLSD(data)
        XCTAssertEqual(entries.map(\.name), ["Assets", "report one.txt"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].size, 1234)
        XCTAssertNotNil(entries[1].modified)
    }

    func testLongListingPreservesSpacesAndDoesNotFollowLinks() throws {
        let data = Data("total 3\ndrwxr-xr-x 2 501 20 64 Nov  1 10:00 .\n-rw-r--r-- 1 501 20 12 Nov  1 10:00 name with spaces.txt\nlrwxr-xr-x 1 501 20 7 Nov  1 10:00 alias -> /target\ndrwxr-xr-x 2 501 20 64 Nov  1 10:00 folder\n".utf8)
        let entries = try RemoteFileSystem.parseLongListing(data)
        XCTAssertEqual(entries.map(\.name), ["folder", "alias", "name with spaces.txt"])
        XCTAssertTrue(entries[1].isSymbolicLink)
        XCTAssertThrowsError(try RemoteFileSystem.parseLongListing(Data("unknown server format".utf8)))
        XCTAssertThrowsError(try RemoteFileSystem.parseMLSD(Data("type=file; ../escape".utf8)))
    }

    func testSSHAndSFTPQuoteLiteralPaths() throws {
        XCTAssertEqual(RemoteFileSystem.shellQuote("/a'b;$(touch x)"), "'/a'\\''b;$(touch x)'")
        XCTAssertEqual(RemoteFileSystem.sftpQuote("/a [1]*?\""), "\"/a [1]*?\\\"\"")
        var command: RemoteInvocation?
        let connection = try RemoteConnection(kind: .shell, host: "host.test", port: 2200, user: "me")
        let fs = RemoteFileSystem(connection: connection) { invocation, _ in command = invocation; return Data() }
        _ = try fs.list("/a'b;$(touch x)")
        XCTAssertEqual(command?.executable, "/usr/bin/ssh")
        XCTAssertTrue(command?.arguments.contains("-oStrictHostKeyChecking=yes") == true)
        XCTAssertTrue(command?.arguments.last?.hasSuffix("'/a'\\''b;$(touch x)'") == true)
    }

    func testFTPCredentialsAreOnlyInStandardInput() throws {
        var command: RemoteInvocation?
        let connection = try RemoteConnection(kind: .ftp, host: "host.test", port: 21, user: "me", password: "a\"b\\c")
        let fs = RemoteFileSystem(connection: connection) { invocation, _ in command = invocation; return Data() }
        _ = try fs.list("/folder one")
        XCTAssertEqual(command?.arguments, ["--config", "-"])
        let configuration = String(data: command!.input!, encoding: .utf8)!
        XCTAssertTrue(configuration.contains("user = \"me:a\\\"b\\\\c\""))
        XCTAssertTrue(configuration.contains("folder%20one"))
        XCTAssertFalse(configuration.contains("ftp://me:"))
    }

    func testDownloadCommitsOnlyCompleteFilesAndRefusesCollisions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .ftp, host: "host.test", port: 21, user: "")) { invocation, _ in
            if let output = invocation.outputFile { try Data("hello".utf8).write(to: output) }
            return Data()
        }
        let destination = root.appendingPathComponent("hello.txt")
        try fs.download(RemoteEntry(name: "hello.txt", isDirectory: false), from: "/", to: destination)
        XCTAssertEqual(try String(contentsOf: destination), "hello")
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "hello.txt", isDirectory: false), from: "/", to: destination))
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "../escape", isDirectory: false), from: "/", to: root.appendingPathComponent("escape")))
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "link", isDirectory: false, isSymbolicLink: true), from: "/", to: root.appendingPathComponent("link")))
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "fifo", isDirectory: false, isRegularFile: false), from: "/", to: root.appendingPathComponent("fifo")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["hello.txt"])
    }

    func testFailedDownloadsLeaveNoPartialDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "")) { invocation, _ in
            if let output = invocation.outputFile { try Data("partial".utf8).write(to: output) }
            throw RemoteError.process("network disconnected")
        }
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "hello.txt", isDirectory: false), from: "/", to: root.appendingPathComponent("hello.txt")))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCancelledOperationsDoNotStartTransport() throws {
        let token = RemoteCancellation(); token.cancel()
        var ran = false
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "")) { _, _ in ran = true; return Data() }
        XCTAssertThrowsError(try fs.list("/", cancellation: token))
        XCTAssertFalse(ran)
    }

    func testProcessRunnerStreamsInputAndOutput() throws {
        let output = try RemoteFileSystem.run(RemoteInvocation(executable: "/bin/cat", arguments: [], input: Data("pipe data".utf8)), RemoteCancellation())
        XCTAssertEqual(String(data: output, encoding: .utf8), "pipe data")
    }

    func testSFTPAgainstSystemServerHandlesLiteralNamesAndRecursiveTransfers() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System-sftp-server fehlt") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookSFTP-" + UUID().uuidString)
        let local = root.appendingPathComponent("local"), remote = root.appendingPathComponent("remote"), downloaded = root.appendingPathComponent("downloaded")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloaded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "test", port: 22, user: "")) { invocation, token in
            var direct = invocation
            direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            return try RemoteFileSystem.run(direct, token)
        }
        let literal = "  name [1]*?\\\".txt"
        try Data("literal bytes".utf8).write(to: local.appendingPathComponent(literal))
        try fs.upload(local.appendingPathComponent(literal), to: remote.path)
        let entries = try fs.list(remote.path)
        XCTAssertEqual(entries.map(\.name), [literal])
        try fs.download(entries[0], from: remote.path, to: downloaded.appendingPathComponent(literal))
        XCTAssertEqual(try Data(contentsOf: downloaded.appendingPathComponent(literal)), Data("literal bytes".utf8))
        XCTAssertThrowsError(try fs.upload(local.appendingPathComponent(literal), to: remote.path))
        try fs.remove(entries[0], from: remote.path)
        XCTAssertTrue(try fs.list(remote.path).isEmpty)

        let folder = local.appendingPathComponent("folder [2]")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        try fs.upload(folder, to: remote.path)
        let tree = try XCTUnwrap(fs.list(remote.path).first)
        XCTAssertTrue(tree.isDirectory)
        try fs.download(tree, from: remote.path, to: downloaded.appendingPathComponent(tree.name))
        XCTAssertEqual(try String(contentsOf: downloaded.appendingPathComponent(tree.name).appendingPathComponent("nested.txt")), "nested")
        try fs.remove(tree, from: remote.path)
        XCTAssertTrue(try fs.list(remote.path).isEmpty)
    }

    func testCancellingTerminatesRunningTransport() throws {
        let token = RemoteCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { token.cancel() }
        let start = Date()
        XCTAssertThrowsError(try RemoteFileSystem.run(RemoteInvocation(executable: "/bin/sleep", arguments: ["30"]), token))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
