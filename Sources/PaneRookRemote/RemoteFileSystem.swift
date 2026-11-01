import Foundation

/// A transport-neutral local/remote bridge. No connection passwords are persisted or passed in argv.
public final class RemoteFileSystem: @unchecked Sendable {
    public typealias Runner = (RemoteInvocation, RemoteCancellation) throws -> Data
    public let connection: RemoteConnection
    private let transport: any RemoteTransport
    public init(connection: RemoteConnection, runner: @escaping Runner = RemoteFileSystem.run) {
        self.connection = connection
        self.transport = RemoteProviderRegistry.makeTransport(connection: connection, runner: runner)
    }
    init(connection: RemoteConnection, transport: any RemoteTransport) {
        self.connection = connection; self.transport = transport
    }

    public static func normalizedPath(_ path: String, relativeTo base: String = "/") throws -> String {
        guard !path.contains(where: { $0.isNewline || $0 == "\0" }) else { throw RemoteError.invalidPath }
        let absolute = path.hasPrefix("/") ? path : base + "/" + path
        var pieces: [Substring] = []
        for piece in absolute.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { if !pieces.isEmpty { pieces.removeLast() } }
            else { pieces.append(piece) }
        }
        return "/" + pieces.joined(separator: "/")
    }
    public static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func sftpQuote(_ value: String) -> String {
        var result = "\""
        for char in value {
            // OpenSSH's argument parser already makes glob characters literal inside quotes.
            if "\\\"".contains(char) { result.append("\\") }
            result.append(char)
        }
        return result + "\""
    }
    public func list(_ path: String, cancellation: RemoteCancellation = RemoteCancellation()) throws -> [RemoteEntry] {
        try cancellation.check()
        let path = try Self.normalizedPath(path)
        return try transport.list(path, token: cancellation)
    }
    private func available(_ path: String, token: RemoteCancellation) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if try list(parent, cancellation: token).contains(where: { $0.name == name }) { throw RemoteError.collision(name) }
    }
    public func createDirectory(_ path: String, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        let path = try Self.normalizedPath(path)
        guard path != "/" else { throw RemoteError.collision(path) }
        try available(path, token: cancellation)
        try transport.createDirectory(path, token: cancellation)
    }
    public func download(_ entry: RemoteEntry, from directory: String, to destination: URL, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        try cancellation.check()
        guard Self.validName(entry.name) else { throw RemoteError.invalidPath }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        guard !FileManager.default.fileExists(atPath: destination.path), (try? FileManager.default.attributesOfItem(atPath: destination.path)) == nil else { throw RemoteError.collision(destination.lastPathComponent) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".PaneRookTransfer-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let output = staging.appendingPathComponent("content")
        try downloadContent(entry, path: Self.normalizedPath(entry.name, relativeTo: directory), to: output, token: cancellation, depth: 0)
        try cancellation.check()
        try FileManager.default.moveItem(at: output, to: destination)
    }
    private func downloadContent(_ entry: RemoteEntry, path: String, to destination: URL, token: RemoteCancellation, depth: Int) throws {
        try token.check()
        guard depth < 256, !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        guard entry.isDirectory || entry.isRegularFile else { throw RemoteError.specialFile }
        if entry.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for child in try list(path, cancellation: token) {
                try downloadContent(child, path: Self.normalizedPath(child.name, relativeTo: path), to: destination.appendingPathComponent(child.name), token: token, depth: depth + 1)
            }
        } else {
            try transport.download(path, to: destination, token: token)
        }
    }
    public func upload(_ source: URL, to directory: String, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        try uploadContent(source, path: Self.normalizedPath(source.lastPathComponent, relativeTo: directory), token: cancellation, depth: 0)
    }
    private func uploadContent(_ source: URL, path: String, token: RemoteCancellation, depth: Int) throws {
        try token.check()
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard depth < 256, values.isSymbolicLink != true else { throw RemoteError.symbolicLink }
        if values.isDirectory == true {
            try createDirectory(path, cancellation: token)
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try uploadContent(child, path: Self.normalizedPath(child.lastPathComponent, relativeTo: path), token: token, depth: depth + 1)
            }
        } else {
            guard values.isRegularFile == true else { throw RemoteError.symbolicLink }
            try available(path, token: token)
            try transport.upload(source, to: path, token: token)
        }
    }
    public func remove(_ entry: RemoteEntry, from directory: String, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        guard Self.validName(entry.name) else { throw RemoteError.invalidPath }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        try removeContent(entry, path: Self.normalizedPath(entry.name, relativeTo: directory), token: cancellation, depth: 0)
    }
    private func removeContent(_ entry: RemoteEntry, path: String, token: RemoteCancellation, depth: Int) throws {
        try token.check()
        guard path != "/", depth < 256 else { throw RemoteError.invalidPath }
        if entry.isDirectory && !entry.isSymbolicLink {
            for child in try list(path, cancellation: token) { try removeContent(child, path: Self.normalizedPath(child.name, relativeTo: path), token: token, depth: depth + 1) }
        }
        let directory = entry.isDirectory && !entry.isSymbolicLink
        try transport.remove(path, directory: directory, token: token)
    }

}
