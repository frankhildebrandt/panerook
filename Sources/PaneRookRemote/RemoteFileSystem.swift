import Foundation

/// A transport-neutral local/remote bridge. No connection passwords are persisted or passed in argv.
public final class RemoteFileSystem: @unchecked Sendable {
    public typealias Runner = (RemoteInvocation, RemoteCancellation) throws -> Data
    public let connection: RemoteConnection
    let transport: any RemoteTransport
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
    func removeEmptyOrFile(_ path: String, directory: Bool, cancellation: RemoteCancellation) throws {
        try transport.remove(path, directory: directory, token: cancellation)
    }
    func available(_ path: String, token: RemoteCancellation) throws {
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
    public func download(_ entry: RemoteEntry, from directory: String, to destination: URL, resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).download(self, entry: entry, directory: directory, destination: destination, moving: false)
            return
        }
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
    func downloadContent(_ entry: RemoteEntry, path: String, to destination: URL, token: RemoteCancellation, depth: Int) throws {
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
    public func upload(_ source: URL, to directory: String, resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).upload(self, source: source, path: Self.normalizedPath(source.lastPathComponent, relativeTo: directory), moving: false)
            return
        }
        try uploadContent(source, path: Self.normalizedPath(source.lastPathComponent, relativeTo: directory), token: cancellation, depth: 0)
    }
    /// Moving a local source validates its captured tree before deleting any
    /// data. Cleanup unlinks captured files and removes only empty directories.
    public func upload(_ source: URL, to directory: String, movingSource: Bool,
                       resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).upload(self, source: source, path: Self.normalizedPath(source.lastPathComponent, relativeTo: directory), moving: movingSource)
            return
        }
        guard movingSource else { try upload(source, to: directory, cancellation: cancellation); return }
        let snapshot = try LocalTransferSnapshot.capture(source, cancellation: cancellation)
        try upload(source, to: directory, cancellation: cancellation)
        guard try LocalTransferSnapshot.capture(source, cancellation: cancellation) == snapshot else { throw RemoteError.sourceChanged }
        try snapshot.remove(source, cancellation: cancellation)
    }

    /// Download and remove only the unchanged entries captured for this move.
    public func move(_ entry: RemoteEntry, from directory: String, to destination: URL,
                     resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).download(self, entry: entry, directory: directory, destination: destination, moving: true)
            return
        }
        let snapshot = try captureTransferSnapshot(entry, from: directory, cancellation: cancellation)
        try download(snapshot.entry, from: directory, to: destination, cancellation: cancellation)
        try removeTransferredSnapshot(snapshot, from: directory, cancellation: cancellation)
    }
    /// Rename or move an entry within this connection without downloading it.
    /// Without a resolver, existing destinations are rejected. With a resolver,
    /// replacement and merging use the shared staged conflict workflow.
    public func move(_ entry: RemoteEntry, from directory: String, to destinationPath: String,
                     resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).remote(self, entry: entry, directory: directory, destination: self, target: Self.normalizedPath(destinationPath, relativeTo: directory), moving: true)
            return
        }
        try cancellation.check()
        guard Self.validName(entry.name) else { throw RemoteError.invalidPath }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        let source = try Self.normalizedPath(entry.name, relativeTo: directory)
        let destination = try Self.normalizedPath(destinationPath, relativeTo: directory)
        guard destination != "/", !entry.isDirectory || !destination.hasPrefix(source + "/") else {
            throw RemoteError.invalidPath
        }
        if destination == source { return }
        try available(destination, token: cancellation)
        try cancellation.check()
        try transport.move(source, to: destination, token: cancellation)
    }

    /// Copies through private local staging so every pair of providers can be
    /// used as ordinary source and destination panels. Staging is always removed.
    public func copy(_ entry: RemoteEntry, from directory: String, to destination: RemoteFileSystem,
                     directory destinationDirectory: String,
                     resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).remote(self, entry: entry, directory: directory, destination: destination, target: Self.normalizedPath(entry.name, relativeTo: destinationDirectory), moving: false)
            return
        }
        try cancellation.check()
        guard Self.validName(entry.name) else { throw RemoteError.invalidPath }
        let target = try Self.normalizedPath(entry.name, relativeTo: destinationDirectory)
        if sharesEndpoint(with: destination) {
            let source = try Self.normalizedPath(entry.name, relativeTo: directory)
            guard source != target else { throw RemoteError.collision(entry.name) }
            guard !entry.isDirectory || !target.hasPrefix(source + "/") else { throw RemoteError.invalidPath }
        }
        // Reject collisions before spending time downloading the source.
        try destination.available(target, token: cancellation)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookRemote-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let local = staging.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)
        try download(entry, from: directory, to: local, cancellation: cancellation)
        try destination.upload(local, to: destinationDirectory, cancellation: cancellation)
    }

    /// Same-endpoint moves use the server's rename operation. Across connections
    /// the source is removed only after its entire copy has completed.
    public func move(_ entry: RemoteEntry, from directory: String, to destination: RemoteFileSystem,
                     directory destinationDirectory: String,
                     resolveConflict: RemoteConflictResolver? = nil, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        if let resolveConflict {
            try ResolvedRemoteTransfer(resolve: resolveConflict, token: cancellation).remote(self, entry: entry, directory: directory, destination: destination, target: Self.normalizedPath(entry.name, relativeTo: destinationDirectory), moving: true)
            return
        }
        if sharesEndpoint(with: destination) {
            try move(entry, from: directory,
                     to: Self.normalizedPath(entry.name, relativeTo: destinationDirectory), cancellation: cancellation)
        } else {
            let snapshot = try captureTransferSnapshot(entry, from: directory, cancellation: cancellation)
            try copy(snapshot.entry, from: directory, to: destination, directory: destinationDirectory, cancellation: cancellation)
            try removeTransferredSnapshot(snapshot, from: directory, cancellation: cancellation)
        }
    }

    func sharesEndpoint(with other: RemoteFileSystem) -> Bool {
        connection.kind == other.connection.kind && connection.host == other.connection.host
            && connection.port == other.connection.port && connection.user == other.connection.user
            && connection.password == other.connection.password && connection.identityFile == other.connection.identityFile
    }

    func captureTransferSnapshot(_ entry: RemoteEntry, from directory: String,
                                         cancellation: RemoteCancellation) throws -> RemoteTransferSnapshot {
        guard Self.validName(entry.name) else { throw RemoteError.invalidPath }
        guard let current = try list(directory, cancellation: cancellation).first(where: { $0.name == entry.name }) else {
            throw RemoteError.sourceChanged
        }
        return try captureTransferTree(current, path: Self.normalizedPath(entry.name, relativeTo: directory), depth: 0, cancellation: cancellation)
    }

    private func captureTransferTree(_ entry: RemoteEntry, path: String, depth: Int,
                                     cancellation: RemoteCancellation) throws -> RemoteTransferSnapshot {
        try cancellation.check()
        guard depth < 256, Self.validName(entry.name) else { throw RemoteError.invalidPath }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        guard entry.isDirectory || entry.isRegularFile else { throw RemoteError.specialFile }
        let children = entry.isDirectory ? try list(path, cancellation: cancellation).sorted { $0.name < $1.name }.map {
            try captureTransferTree($0, path: Self.normalizedPath($0.name, relativeTo: path), depth: depth + 1, cancellation: cancellation)
        } : []
        return RemoteTransferSnapshot(entry: entry, children: children)
    }

    func removeTransferredSnapshot(_ snapshot: RemoteTransferSnapshot, from directory: String,
                                           cancellation: RemoteCancellation) throws {
        // Check the whole source before the first deletion. This also detects a
        // destination nested inside the source through another connection alias.
        guard try captureTransferSnapshot(snapshot.entry, from: directory, cancellation: cancellation) == snapshot else {
            throw RemoteError.sourceChanged
        }
        try removeTransferTree(snapshot, path: Self.normalizedPath(snapshot.entry.name, relativeTo: directory), cancellation: cancellation)
    }

    private func removeTransferTree(_ snapshot: RemoteTransferSnapshot, path: String,
                                    cancellation: RemoteCancellation) throws {
        try cancellation.check()
        let parent = (path as NSString).deletingLastPathComponent
        guard try list(parent, cancellation: cancellation).first(where: { $0.name == snapshot.entry.name }) == snapshot.entry else {
            throw RemoteError.sourceChanged
        }
        if snapshot.entry.isDirectory {
            for child in snapshot.children {
                try removeTransferTree(child, path: Self.normalizedPath(child.entry.name, relativeTo: path), cancellation: cancellation)
            }
            // Never recursively rescan here: files added after copying were not
            // transferred. rmdir on SSH/SFTP/FTP also enforces emptiness remotely.
            guard try list(path, cancellation: cancellation).isEmpty else { throw RemoteError.sourceChanged }
        }
        try cancellation.check()
        try transport.remove(path, directory: snapshot.entry.isDirectory, token: cancellation)
    }
    func uploadContent(_ source: URL, path: String, token: RemoteCancellation, depth: Int) throws {
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
