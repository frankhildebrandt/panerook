import XCTest
import Darwin
@testable import PaneRookCore

final class ConnectionBookmarkTests: XCTestCase {
    private var root: URL!
    private var file: URL!
    private var store: ConnectionBookmarkStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookConnectionTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        file = root.appendingPathComponent("archive/connections.json")
        store = ConnectionBookmarkStore(fileURL: file)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func bookmark(_ kind: RemoteProtocol = .sftp, name: String = "Development") throws -> ConnectionBookmark {
        try ConnectionBookmark(name: name, kind: kind, host: "host.example", port: kind == .ftp ? 21 : 22,
                               user: "developer", path: "/srv/./files/../home", identityFile: kind == .ftp ? "" : "~/.ssh/test key")
    }

    func testCreateEditRemoveAndReloadPreserveIdentifiers() throws {
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let first = try bookmark()
        let second = try bookmark(.ftp, name: "Files")
        XCTAssertEqual(try store.upsert(first), [first])
        XCTAssertEqual(try store.upsert(second), [first, second])
        var edited = first
        edited.name = "Renamed server"
        edited.port = 2222
        edited.path = "/new/../target"
        let normalized = try ConnectionBookmark(id: first.id, name: edited.name, kind: edited.kind, host: edited.host,
                                                 port: edited.port, user: edited.user, path: "/target", identityFile: edited.identityFile)
        XCTAssertEqual(try store.upsert(edited), [normalized, second])
        let relaunched = ConnectionBookmarkStore(fileURL: file)
        XCTAssertEqual(try relaunched.load(), [normalized, second])
        XCTAssertEqual(try relaunched.remove(id: first.id), [second])
        XCTAssertEqual(try store.load(), [second])
        XCTAssertEqual(try store.remove(id: UUID()), [second])
        XCTAssertEqual(try store.remove(id: second.id), [])
        XCTAssertEqual(try ConnectionBookmarkStore(fileURL: file).load(), [])
    }

    func testAllProtocolsPersistOnlyMetadataAndReconstructTransientPasswords() throws {
        let values = try [RemoteProtocol.sftp, .shell, .ftp].map { try bookmark($0, name: $0.rawValue) }
        for value in values { try store.upsert(value) }
        XCTAssertEqual(try ConnectionBookmarkStore(fileURL: file).load(), values)
        let data = try Data(contentsOf: file)
        let text = String(decoding: data, as: UTF8.self)
        let connection = try values[2].connection(password: "transient-only-secret", timeout: 25)
        XCTAssertEqual(connection.password, "transient-only-secret")
        XCTAssertEqual(connection.host, values[2].host)
        XCTAssertEqual(connection.kind, .ftp)
        XCTAssertEqual(connection.timeout, 25)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("password"))
        XCTAssertFalse(text.contains("transient-only-secret"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        let rows = try XCTUnwrap(document["bookmarks"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["id", "name", "kind", "host", "port", "user", "path", "identityFile"])
    }

    func testValidationNormalizesNamesHostsAndPaths() throws {
        let value = try ConnectionBookmark(name: "  Test server  ", kind: .shell, host: " host.example ",
                                           port: 2200, user: "dev", path: "a/../folder//name")
        XCTAssertEqual(value.name, "Test server")
        XCTAssertEqual(value.host, "host.example")
        XCTAssertEqual(value.path, "/folder/name")
        let emptyPath = try ConnectionBookmark(name: "Root", kind: .ftp, host: "host.example", port: 21, user: "", path: "")
        XCTAssertEqual(emptyPath.path, "/")
        XCTAssertEqual(try value.connection().identityFile, "")
        for name in ["", " \t ", "line\nbreak", "nul\0name", "tab\tname"] {
            XCTAssertThrowsError(try ConnectionBookmark(name: name, kind: .sftp, host: "host.example", port: 22, user: "dev"))
        }
        for host in ["", "-oProxyCommand=bad", "host\nother", "host/path", "user@host"] {
            XCTAssertThrowsError(try ConnectionBookmark(name: "Test", kind: .shell, host: host, port: 22, user: "dev"))
        }
        for port in [-1, 0, 65536] {
            XCTAssertThrowsError(try ConnectionBookmark(name: "Test", kind: .ftp, host: "host.example", port: port, user: "dev"))
        }
        for path in ["/a\nrm /", "/nul\0path"] {
            XCTAssertThrowsError(try ConnectionBookmark(name: "Test", kind: .sftp, host: "host.example", port: 22, user: "dev", path: path))
        }
        XCTAssertThrowsError(try ConnectionBookmark(name: "Test", kind: .shell, host: "host.example", port: 22, user: "-bad"))
        XCTAssertThrowsError(try ConnectionBookmark(name: "Test", kind: .shell, host: "host.example", port: 22, user: "dev", identityFile: "key\nother"))
    }

    func testDecodedAndMutatedValuesCannotBypassValidation() throws {
        let value = try bookmark()
        let encoded = try JSONEncoder().encode(value)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (key, bad): (String, Any) in [("host", "-bad"), ("port", 0), ("name", " "), ("path", "/a\ncommand"), ("kind", "unknown")] {
            var row = original
            row[key] = bad
            let bytes = try JSONSerialization.data(withJSONObject: row)
            XCTAssertThrowsError(try JSONDecoder().decode(ConnectionBookmark.self, from: bytes), key)
        }
        try store.upsert(value)
        let before = try Data(contentsOf: file)
        var invalid = value
        invalid.port = 0
        XCTAssertThrowsError(try store.upsert(invalid))
        XCTAssertThrowsError(try JSONEncoder().encode(invalid))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testCorruptUnsupportedAndInvalidArchivesAreNeverOverwritten() throws {
        let valid = try bookmark()
        try store.upsert(valid)
        let originalData = try Data(contentsOf: file)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
        var unsupported = original
        unsupported["version"] = 2
        var invalid = original
        var rows = try XCTUnwrap(original["bookmarks"] as? [[String: Any]])
        rows[0]["port"] = 0
        invalid["bookmarks"] = rows
        var duplicate = original
        let row = try XCTUnwrap((original["bookmarks"] as? [[String: Any]])?.first)
        duplicate["bookmarks"] = [row, row]
        let cases = [Data("{broken".utf8), try JSONSerialization.data(withJSONObject: unsupported),
                     try JSONSerialization.data(withJSONObject: invalid), try JSONSerialization.data(withJSONObject: duplicate)]
        for bytes in cases {
            try bytes.write(to: file)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.upsert(try bookmark(name: "Another")))
            XCTAssertThrowsError(try store.remove(id: valid.id))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testArchiveAndNewDirectoryHaveOwnerOnlyPermissionsAndNoTempFilesRemain() throws {
        try store.upsert(try bookmark())
        var directoryInfo = stat(), fileInfo = stat()
        XCTAssertEqual(lstat(file.deletingLastPathComponent().path, &directoryInfo), 0)
        XCTAssertEqual(lstat(file.path, &fileInfo), 0)
        XCTAssertEqual(directoryInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        try store.upsert(try bookmark(.shell, name: "Second"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["connections.json"])
    }

    func testArchiveSymlinksDirectoriesAndNonLocalURLsAreRejected() throws {
        let target = root.appendingPathComponent("target.json")
        let bytes = Data("keep this file".utf8)
        try bytes.write(to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let linkStore = ConnectionBookmarkStore(fileURL: link)
        XCTAssertThrowsError(try linkStore.load())
        XCTAssertThrowsError(try linkStore.upsert(try bookmark()))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let directoryStore = ConnectionBookmarkStore(fileURL: root)
        XCTAssertThrowsError(try directoryStore.load())
        XCTAssertThrowsError(try directoryStore.upsert(try bookmark()))
        let remoteStore = ConnectionBookmarkStore(fileURL: URL(string: "sftp://host.example/archive.json")!)
        XCTAssertThrowsError(try remoteStore.load())
    }
}
