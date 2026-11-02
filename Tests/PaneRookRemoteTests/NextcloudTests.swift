import Foundation
import XCTest
@testable import PaneRookRemote

final class NextcloudTests: XCTestCase {
    private let davRoot = "/nextcloud/remote.php/dav/files/me/"

    private func connection(host: String = "https://cloud.example/nextcloud", user: String = "me", password: String = "app-password") throws -> RemoteConnection {
        try RemoteConnection(kind: .nextcloud, host: host, port: 443, user: user, password: password)
    }

    private func response(_ href: String, directory: Bool = false, size: Int = 12, status: Int = 200) -> String {
        """
        <d:response><d:href>\(href.replacingOccurrences(of: "&", with: "&amp;"))</d:href><d:propstat><d:prop>
        <d:resourcetype>\(directory ? "<d:collection/>" : "")</d:resourcetype>
        <d:displayname>Misleading display name</d:displayname><d:getcontentlength>\(size)</d:getcontentlength>
        <d:getlastmodified>Sun, 01 Nov 2026 10:25:59 GMT</d:getlastmodified>
        </d:prop><d:status>HTTP/1.1 \(status) Test</d:status></d:propstat></d:response>
        """
    }

    private func listing(_ responses: [String]) -> Data {
        Data(("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">" + responses.joined() + "</d:multistatus>\n207").utf8)
    }

    private func config(_ invocation: RemoteInvocation) -> String {
        String(decoding: invocation.input ?? Data(), as: UTF8.self)
    }

    private func configValue(_ key: String, in configuration: String) throws -> String {
        let line = try XCTUnwrap(configuration.split(separator: "\n").first {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key
        })
        let parts = line.split(separator: "=", maxSplits: 1)
        var value = try XCTUnwrap(parts.last).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        return value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookNextcloud-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func testServerURLsPreserveInstallationPathAndExplicitPort() throws {
        let bare = try connection(host: "cloud.example")
        XCTAssertEqual(bare.host, "https://cloud.example")
        XCTAssertEqual(bare.port, 443)
        let installed = try connection(host: "https://cloud.example:8443/nextcloud/")
        XCTAssertEqual(installed.host, "https://cloud.example/nextcloud")
        XCTAssertEqual(installed.port, 8443)
        XCTAssertFalse(installed.displayName.contains("app-password"))
        XCTAssertFalse(installed.displayName.contains("https://https://"))
        for invalid in ["http://cloud.example", "ftp://cloud.example", "https://me:secret@cloud.example", "https://cloud.example/?token=secret", "https://cloud.example/#fragment", "https://cloud.example/\nother"] {
            XCTAssertThrowsError(try connection(host: invalid), invalid)
        }
        XCTAssertThrowsError(try connection(user: ""))
        XCTAssertThrowsError(try connection(user: "me:password"))
        XCTAssertThrowsError(try connection(user: "."))
        XCTAssertThrowsError(try connection(user: ".."))
    }

    func testListingUsesDAVHrefNamesAndMetadataAndOmitsSelf() throws {
        let data = listing([
            response(davRoot + "Documents/", directory: true),
            response(davRoot + "Documents/report%20one.txt", size: 1234),
            response("https://cloud.example" + davRoot + "Documents/Assets/", directory: true),
            response(davRoot + "Documents/%20%20Gr%C3%BC%C3%9Fe%20%25%23%3F.txt", size: 42)
        ])
        let fs = RemoteFileSystem(connection: try connection()) { _, _ in data }
        let entries = try fs.list("/Documents")
        XCTAssertEqual(entries.map(\.name), ["Assets", "  Grüße %#?.txt", "report one.txt"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertFalse(entries[0].isRegularFile)
        XCTAssertTrue(entries[2].isRegularFile)
        XCTAssertEqual(entries[2].size, 1234)
        XCTAssertEqual(entries[2].modified, Date(timeIntervalSince1970: 1_793_528_759))
    }

    func testListingEncodesURLOnceAndPassesCredentialsOnlyThroughStandardInput() throws {
        var invocation: RemoteInvocation?
        let fs = RemoteFileSystem(connection: try connection(password: "a\"b\\c")) { command, _ in
            invocation = command
            return self.listing([self.response(self.davRoot + "Gr%C3%BC%C3%9Fe%20%25%23%3F/", directory: true)])
        }
        XCTAssertEqual(try fs.list("/Grüße %#?"), [])
        let command = try XCTUnwrap(invocation)
        XCTAssertEqual(command.executable, "/usr/bin/curl")
        XCTAssertEqual(command.arguments, ["-q", "--config", "-"])
        let configuration = config(command)
        XCTAssertEqual(try configValue("url", in: configuration), "https://cloud.example:443" + davRoot + "Gr%C3%BC%C3%9Fe%20%25%23%3F/")
        XCTAssertEqual(try configValue("user", in: configuration), "me:a\"b\\c")
        XCTAssertEqual(try configValue("request", in: configuration), "PROPFIND")
        XCTAssertTrue(configuration.contains("Depth: 1"))
        XCTAssertTrue(configuration.contains("resourcetype"))
        XCTAssertFalse(configuration.contains("insecure"))
        XCTAssertFalse(configuration.contains("location"))
        XCTAssertFalse(command.arguments.joined().contains("a\"b\\c"))
    }

    func testListingRejectsMalformedFailedAndOutOfScopeResponses() throws {
        let selfResponse = response(davRoot, directory: true)
        let badResponses = [
            listing([selfResponse, response("/elsewhere/file.txt")]),
            listing([selfResponse, response("https://other.example" + davRoot + "file.txt")]),
            listing([selfResponse, response(davRoot + "nested/file.txt")]),
            listing([selfResponse, response(davRoot + "bad%2Fname.txt")]),
            listing([selfResponse, response(davRoot + "%2E%2E")]),
            listing([selfResponse, response(davRoot + "duplicate.txt"), response(davRoot + "duplicate.txt")]),
            listing([selfResponse, response(davRoot + "inaccessible.txt", status: 404)]),
            listing([response(davRoot + "file.txt")]),
            Data("<d:multistatus xmlns:d=\"DAV:\"><d:response>\n207".utf8),
            Data("<html>Sign in</html>\n207".utf8)
        ]
        for data in badResponses {
            let fs = RemoteFileSystem(connection: try connection()) { _, _ in data }
            XCTAssertThrowsError(try fs.list("/"), String(decoding: data, as: UTF8.self))
        }
    }

    func testListingAcceptsNamespacePrefixesAndUnavailableOptionalProperties() throws {
        let file = """
        <d:response><d:href>\(davRoot)file.txt</d:href>
        <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>5</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
        <d:propstat><d:prop><d:getlastmodified/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
        """
        let data = listing([response(davRoot, directory: true), file])
        let renamed = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "d:", with: "dav:")
            .replacingOccurrences(of: "xmlns:d=", with: "xmlns:dav=")
        let fs = RemoteFileSystem(connection: try connection()) { _, _ in Data(renamed.utf8) }
        let entries = try fs.list("/")
        XCTAssertEqual(entries.map(\.name), ["file.txt"])
        XCTAssertEqual(entries.first?.size, 5)
        XCTAssertNil(entries.first?.modified)
    }

    func testHTTPFailuresAndRedirectsDoNotBecomeSuccessfulListings() throws {
        for status in [301, 302, 401, 403, 404, 500, 507] {
            let fs = RemoteFileSystem(connection: try connection()) { _, _ in Data("<html>Server response</html>\n\(status)".utf8) }
            XCTAssertThrowsError(try fs.list("/"), "HTTP \(status)")
        }
    }

    func testUserIDsAreEncodedAsOneDAVPathComponentAndEntitiesAreRejected() throws {
        let user = "user+tag@example.org"
        let encodedRoot = "/nextcloud/remote.php/dav/files/user%2Btag%40example.org/"
        let fs = RemoteFileSystem(connection: try connection(user: user)) { command, _ in
            let url = try self.configValue("url", in: self.config(command))
            XCTAssertEqual(url, "https://cloud.example:443" + encodedRoot)
            return self.listing([self.response(encodedRoot, directory: true)])
        }
        XCTAssertEqual(try fs.list("/"), [])

        let entity = Data(("<?xml version=\"1.0\"?><!DOCTYPE d:multistatus [<!ENTITY alias \"file.txt\">]>"
            + "<d:multistatus xmlns:d=\"DAV:\">" + response(davRoot, directory: true)
            + response(davRoot + "&alias;").replacingOccurrences(of: "&amp;alias;", with: "&alias;")
            + "</d:multistatus>\n207").utf8)
        let untrusted = RemoteFileSystem(connection: try connection()) { _, _ in entity }
        XCTAssertThrowsError(try untrusted.list("/"))
    }

    func testConditionalUploadRejectsFileCreatedAfterPreflight() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raced.txt")
        try Data("local content".utf8).write(to: source)
        var methods: [String] = []
        let fs = RemoteFileSystem(connection: try connection()) { command, _ in
            let configuration = self.config(command)
            let method = try self.configValue("request", in: configuration)
            methods.append(method)
            if method == "PROPFIND" { return self.listing([self.response(self.davRoot, directory: true)]) }
            XCTAssertEqual(method, "PUT")
            XCTAssertTrue(configuration.contains("If-None-Match: *"))
            return Data("\n412".utf8)
        }
        XCTAssertThrowsError(try fs.upload(source, to: "/")) { error in
            guard case RemoteError.collision(let name) = error else { return XCTFail("Expected collision, got \(error)") }
            XCTAssertEqual(name, "raced.txt")
        }
        XCTAssertEqual(methods, ["PROPFIND", "PUT"])
    }

    func testMoveEncodesDestinationAndRejectsNewCollisionWithoutOverwrite() throws {
        var methods: [String] = []
        let fs = RemoteFileSystem(connection: try connection()) { command, _ in
            let configuration = self.config(command)
            let method = try self.configValue("request", in: configuration)
            methods.append(method)
            if method == "PROPFIND" { return self.listing([self.response(self.davRoot, directory: true)]) }
            XCTAssertEqual(method, "MOVE")
            XCTAssertEqual(try self.configValue("url", in: configuration), "https://cloud.example:443" + self.davRoot + "old.txt")
            XCTAssertTrue(configuration.contains("Destination: https://cloud.example:443" + self.davRoot + "Gr%C3%BC%C3%9Fe%20%25%23%3F.txt"))
            XCTAssertTrue(configuration.contains("Overwrite: F"))
            return Data("\n412".utf8)
        }
        XCTAssertThrowsError(try fs.move(RemoteEntry(name: "old.txt", isDirectory: false), from: "/", to: "Grüße %#?.txt")) { error in
            guard case RemoteError.collision = error else { return XCTFail("Expected collision, got \(error)") }
        }
        XCTAssertEqual(methods, ["PROPFIND", "MOVE"])
    }

    func testUploadRefusesExistingNamesBeforeSendingContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("existing.txt")
        try Data("keep local".utf8).write(to: source)
        var methods: [String] = []
        let fs = RemoteFileSystem(connection: try connection()) { command, _ in
            methods.append(try self.configValue("request", in: self.config(command)))
            return self.listing([self.response(self.davRoot, directory: true), self.response(self.davRoot + "existing.txt")])
        }
        XCTAssertThrowsError(try fs.upload(source, to: "/"))
        XCTAssertEqual(methods, ["PROPFIND"])
    }

    func testDirectoryAndFileOperationsUseWebDAVAndConditionalUpload() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("hello.txt")
        let destination = root.appendingPathComponent("download.txt")
        try Data("hello bytes".utf8).write(to: source)
        var methods: [String] = []
        let fs = RemoteFileSystem(connection: try connection()) { command, _ in
            let configuration = self.config(command)
            let method = try self.configValue("request", in: configuration)
            methods.append(method)
            switch method {
            case "PROPFIND": return self.listing([self.response(self.davRoot, directory: true)])
            case "MKCOL": return Data("\n201".utf8)
            case "PUT":
                XCTAssertTrue(configuration.contains("If-None-Match: *"))
                XCTAssertEqual(try self.configValue("upload-file", in: configuration), source.path)
                return Data("\n201".utf8)
            case "GET":
                XCTAssertNil(command.outputFile)
                let output = try self.configValue("output", in: configuration)
                try Data("hello bytes".utf8).write(to: URL(fileURLWithPath: output))
                return Data("\n200".utf8)
            case "DELETE": return Data("\n204".utf8)
            default: XCTFail("Unexpected DAV method \(method)"); return Data()
            }
        }
        try fs.createDirectory("/folder")
        try fs.upload(source, to: "/")
        let entry = RemoteEntry(name: "hello.txt", isDirectory: false)
        try fs.download(entry, from: "/", to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("hello bytes".utf8))
        try fs.remove(entry, from: "/")
        XCTAssertEqual(methods, ["PROPFIND", "MKCOL", "PROPFIND", "PUT", "GET", "DELETE"])
    }

    func testFailedDownloadDiscardsStagedResponse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = RemoteFileSystem(connection: try connection()) { command, _ in
            let output = try self.configValue("output", in: self.config(command))
            try Data("server error page".utf8).write(to: URL(fileURLWithPath: output))
            return Data("\n503".utf8)
        }
        XCTAssertThrowsError(try fs.download(RemoteEntry(name: "hello.txt", isDirectory: false), from: "/", to: root.appendingPathComponent("hello.txt")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCancellationPreventsNextcloudTransport() throws {
        let token = RemoteCancellation()
        token.cancel()
        var ran = false
        let fs = RemoteFileSystem(connection: try connection()) { _, _ in ran = true; return Data() }
        XCTAssertThrowsError(try fs.list("/", cancellation: token))
        XCTAssertFalse(ran)
    }

    func testNextcloudBookmarksPersistURLAndReconstructOnlyTransientPasswords() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("connections.json")
        let store = ConnectionBookmarkStore(fileURL: file)
        let bookmark = try ConnectionBookmark(name: "My Nextcloud", kind: .nextcloud, host: "https://cloud.example:8443/nextcloud/", port: 443, user: "me", path: "/Documents")
        try store.upsert(bookmark)
        let loaded = try XCTUnwrap(ConnectionBookmarkStore(fileURL: file).load().first)
        XCTAssertEqual(loaded, bookmark)
        XCTAssertEqual(loaded.host, "https://cloud.example/nextcloud")
        XCTAssertEqual(loaded.port, 8443)
        XCTAssertEqual(loaded.path, "/Documents")
        let reconstructed = try loaded.connection(password: "transient-app-password")
        XCTAssertEqual(reconstructed.password, "transient-app-password")
        XCTAssertEqual(reconstructed.kind, .nextcloud)
        let archive = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(archive.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(archive.contains("transient-app-password"))
    }
}
