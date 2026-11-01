import Foundation
import XCTest

@testable import PaneRookRemote

final class RemoteTransportContractTests: XCTestCase {
    private final class Transport: RemoteTransport {
        var entries: [RemoteEntry] = []
        var calls: [String] = []
        var failDownload = false
        func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
            calls.append("list " + path)
            return entries
        }
        func createDirectory(_ path: String, token: RemoteCancellation) throws { calls.append("mkdir " + path) }
        func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
            calls.append("download " + path)
            try Data("partial".utf8).write(to: destination)
            if failDownload { throw RemoteError.process("interrupted") }
        }
        func upload(_ source: URL, to path: String, token: RemoteCancellation) throws { calls.append("upload " + path) }
        func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
            calls.append("remove " + path)
        }
    }
    private func bridge(_ transport: Transport) throws -> RemoteFileSystem {
        RemoteFileSystem(
            connection: try RemoteConnection(kind: .sftp, host: "example.org", port: 22, user: "user"),
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
}
