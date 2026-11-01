import Foundation
import Darwin

/// Connection metadata only. Passwords exist exclusively in a RemoteConnection
/// constructed for an individual connection attempt, never in this archive.
public struct ConnectionBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: RemoteProtocol
    public var host: String
    public var port: Int
    public var user: String
    public var path: String
    public var identityFile: String

    public init(id: UUID = UUID(), name: String, kind: RemoteProtocol, host: String,
                port: Int, user: String, path: String = "/", identityFile: String = "") throws {
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConnectionBookmarkError.invalidName
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ConnectionBookmarkError.invalidName }
        let connection = try RemoteConnection(kind: kind, host: host.trimmingCharacters(in: .whitespaces),
                                              port: port, user: user, identityFile: identityFile)
        self.id = id
        self.name = trimmedName
        self.kind = connection.kind
        self.host = connection.host
        self.port = connection.port
        self.user = connection.user
        self.path = try RemoteFileSystem.normalizedPath(path)
        self.identityFile = connection.identityFile
    }

    public func connection(password: String = "", timeout: Int = 20) throws -> RemoteConnection {
        try RemoteConnection(kind: kind, host: host, port: port, user: user,
                             password: password, identityFile: identityFile, timeout: timeout)
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, host, port, user, path, identityFile }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: container.decode(UUID.self, forKey: .id), name: container.decode(String.self, forKey: .name),
                      kind: container.decode(RemoteProtocol.self, forKey: .kind), host: container.decode(String.self, forKey: .host),
                      port: container.decode(Int.self, forKey: .port), user: container.decode(String.self, forKey: .user),
                      path: container.decode(String.self, forKey: .path),
                      identityFile: container.decodeIfPresent(String.self, forKey: .identityFile) ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        // Public editable fields may have changed since initialization. Revalidate
        // before persisting them, and keep the serialized format credential-free.
        let value = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.id, forKey: .id)
        try container.encode(value.name, forKey: .name)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.host, forKey: .host)
        try container.encode(value.port, forKey: .port)
        try container.encode(value.user, forKey: .user)
        try container.encode(value.path, forKey: .path)
        try container.encode(value.identityFile, forKey: .identityFile)
    }

    fileprivate func validated() throws -> ConnectionBookmark {
        try ConnectionBookmark(id: id, name: name, kind: kind, host: host, port: port,
                               user: user, path: path, identityFile: identityFile)
    }
}

public enum ConnectionBookmarkError: LocalizedError, Equatable {
    case invalidName, invalidArchive, invalidLocation, duplicateIdentifier, unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Bitte einen Namen ohne Steuerzeichen für die Verbindung eingeben."
        case .invalidArchive: return "Das Verbindungsarchiv ist beschädigt oder enthält ungültige Einträge. Es wurde nicht verändert."
        case .invalidLocation: return "Das Verbindungsarchiv benötigt eine lokale Datei."
        case .duplicateIdentifier: return "Das Verbindungsarchiv enthält doppelte Kennungen. Es wurde nicht verändert."
        case .unsupportedVersion(let version): return "Die Version \(version) des Verbindungsarchivs wird nicht unterstützt. Es wurde nicht verändert."
        }
    }
}

/// Each mutation reloads its source so an invalid archive is never replaced with
/// an empty fallback. Writes become visible atomically with owner-only permissions.
public final class ConnectionBookmarkStore {
    private struct Header: Decodable { let version: Int }
    private struct Archive: Codable { let version: Int; let bookmarks: [ConnectionBookmark] }
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> [ConnectionBookmark] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    @discardableResult public func upsert(_ bookmark: ConnectionBookmark) throws -> [ConnectionBookmark] {
        lock.lock(); defer { lock.unlock() }
        var entries = try loadUnlocked()
        let value = try bookmark.validated()
        if let index = entries.firstIndex(where: { $0.id == value.id }) { entries[index] = value }
        else { entries.append(value) }
        try saveUnlocked(entries)
        return entries
    }

    @discardableResult public func remove(id: UUID) throws -> [ConnectionBookmark] {
        lock.lock(); defer { lock.unlock() }
        var entries = try loadUnlocked()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
        entries.remove(at: index)
        try saveUnlocked(entries)
        return entries
    }

    private func validateLocation() throws {
        guard fileURL.isFileURL, !fileURL.path.contains("\0") else { throw ConnectionBookmarkError.invalidLocation }
    }

    private func loadUnlocked() throws -> [ConnectionBookmark] {
        try validateLocation()
        var info = stat()
        if lstat(fileURL.path, &info) != 0 {
            if errno == ENOENT { return [] }
            throw posix(fileURL)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ConnectionBookmarkError.invalidArchive }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard header.version == 1 else { throw ConnectionBookmarkError.unsupportedVersion(header.version) }
            let archive = try decoder.decode(Archive.self, from: data)
            var identifiers = Set<UUID>()
            for bookmark in archive.bookmarks {
                guard identifiers.insert(bookmark.id).inserted else { throw ConnectionBookmarkError.duplicateIdentifier }
            }
            return archive.bookmarks
        } catch let error as ConnectionBookmarkError { throw error }
        catch { throw ConnectionBookmarkError.invalidArchive }
    }

    private func saveUnlocked(_ bookmarks: [ConnectionBookmark]) throws {
        try validateLocation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Archive(version: 1, bookmarks: bookmarks))
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".connections-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posix(temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporary.path) }
        guard fchmod(descriptor, 0o600) == 0 else { throw posix(temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporary.path, fileURL.path) == 0 else { throw posix(fileURL) }
    }

    private func posix(_ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
