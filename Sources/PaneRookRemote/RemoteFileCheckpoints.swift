import Foundation

extension RemoteFileSystem {
    /// Exact-path metadata lookup for durable file manifests; a failed listing is never treated as absence.
    public func entry(at path: String, cancellation: RemoteCancellation) throws -> RemoteEntry? {
        let path = try Self.normalizedPath(path)
        if path == "/" { _ = try list(path, cancellation: cancellation); return RemoteEntry(name: "/", isDirectory: true) }
        let parent = (path as NSString).deletingLastPathComponent
        do {
            return try list(parent, cancellation: cancellation).first { $0.name == (path as NSString).lastPathComponent }
        } catch {
            // A completed directory move may have removed this parent. Only a successful
            // ancestor listing proving its absence permits treating the child as absent.
            if parent != "/", try entry(at: parent, cancellation: cancellation) == nil { return nil }
            throw error
        }
    }

    /// Never recurse when finishing a manifest move. Server rmdir enforces emptiness as well.
    public func removeTransferredFile(at path: String, expected: RemoteEntry, cancellation: RemoteCancellation) throws {
        try cancellation.check()
        guard try entry(at: path, cancellation: cancellation) == expected else { throw RemoteError.sourceChanged }
        if expected.isDirectory {
            guard try list(path, cancellation: cancellation).isEmpty else { throw RemoteError.sourceChanged }
        }
        try removeEmptyOrFile(path, directory: expected.isDirectory, cancellation: cancellation)
    }
}
