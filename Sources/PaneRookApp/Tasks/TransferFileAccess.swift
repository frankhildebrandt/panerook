import Foundation
import PaneRookCore
import PaneRookRemote
import PaneRookTasks

extension TransferEndpoint {
    init(_ connection: RemoteConnection) {
        self.init(scheme: connection.kind.rawValue, host: connection.host, port: connection.port,
                  user: connection.user, identityFile: connection.identityFile)
    }
}

/// Bridges existing Core and Remote primitives; transports still transfer whole files.
final class TransferFileAccess: RecoverableTransferAccess {
    let localToken = TransferCancellation()
    let remoteToken = RemoteCancellation()
    private let remotes: [TransferEndpoint: RemoteFileSystem]
    init(remotes: [TransferEndpoint: RemoteFileSystem] = [:]) { self.remotes = remotes }
    func cancel() { localToken.cancel(); remoteToken.cancel() }
    func checkCancellation() throws { try localToken.check(); try remoteToken.check() }
    private func remote(_ path: TransferPath) throws -> RemoteFileSystem {
        guard let fs = remotes[path.endpoint] else { throw RemoteError.invalidConnection }
        return fs
    }
    func fingerprint(_ path: TransferPath) throws -> TransferFingerprint? {
        try checkCancellation()
        if path.endpoint == .local { return try RecoverableLocalFiles.fingerprint(path.path, cancellation: localToken) }
        let fs = try remote(path)
        guard let entry = try fs.entry(at: path.path, cancellation: remoteToken) else { return nil }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        if entry.isDirectory { return .init(kind: .directory) }
        guard entry.isRegularFile else { throw RemoteError.specialFile }
        // Providers lack universal content IDs. Hash a private download instead of trusting size/mtime alone.
        return try withTemporaryDirectory { root in
            let file = root.appendingPathComponent(entry.name)
            try fs.download(entry, from: (path.path as NSString).deletingLastPathComponent, to: file, cancellation: remoteToken)
            let digest = try RecoverableLocalFiles.digest(file, cancellation: localToken)
            guard try fs.entry(at: path.path, cancellation: remoteToken) == entry else { throw RemoteError.sourceChanged }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size == entry.size else { throw RemoteError.sourceChanged }
            return .init(kind: .file, size: size, modified: entry.modified, digest: digest)
        }
    }
    func children(_ path: TransferPath) throws -> [String] {
        try checkCancellation()
        if path.endpoint == .local { return try RecoverableLocalFiles.children(path.path) }
        return try remote(path).list(path.path, cancellation: remoteToken).map(\.name)
    }
    func createDirectory(_ path: TransferPath) throws {
        try checkCancellation()
        if path.endpoint == .local { try RecoverableLocalFiles.createDirectory(path.path) }
        else { try remote(path).createDirectory(path.path, cancellation: remoteToken) }
    }
    func copyFile(from source: TransferPath, to destination: TransferPath, progress: @escaping (OperationProgress) -> Void) throws {
        try checkCancellation()
        if source.endpoint == .local && destination.endpoint == .local {
            try RecoverableLocalFiles.copy(source.path, to: destination.path, cancellation: localToken, progress: progress)
        } else if destination.endpoint == .local {
            let fs = try remote(source)
            guard let entry = try fs.entry(at: source.path, cancellation: remoteToken) else { throw RemoteError.sourceChanged }
            try fs.download(entry, from: (source.path as NSString).deletingLastPathComponent,
                            to: URL(fileURLWithPath: destination.path), cancellation: remoteToken)
        } else {
            try withTemporaryDirectory { root in
                // Staging also supports a renamed destination without adding provider-specific upload APIs.
                let local = root.appendingPathComponent((destination.path as NSString).lastPathComponent)
                if source.endpoint == .local {
                    try RecoverableLocalFiles.copy(source.path, to: local.path, cancellation: localToken, progress: progress)
                } else {
                    let fs = try remote(source)
                    guard let entry = try fs.entry(at: source.path, cancellation: remoteToken) else { throw RemoteError.sourceChanged }
                    try fs.download(entry, from: (source.path as NSString).deletingLastPathComponent, to: local, cancellation: remoteToken)
                }
                try remote(destination).upload(local, to: (destination.path as NSString).deletingLastPathComponent, cancellation: remoteToken)
            }
        }
    }
    func sanitized(_ record: RecoverableTransfer) -> RecoverableTransfer {
        var value = record
        func redact(_ text: String?) -> String? {
            guard var text else { return nil }
            for fs in remotes.values where !fs.connection.password.isEmpty {
                text = text.replacingOccurrences(of: fs.connection.password, with: "[Passwort entfernt]")
            }
            return String(text.prefix(4096))
        }
        value.error = redact(value.error)
        if value.entries != nil {
            for index in value.entries!.indices { value.entries![index].error = redact(value.entries![index].error) }
        }
        return value
    }
    func finishDirectory(from source: TransferPath, to destination: TransferPath) throws {
        try checkCancellation()
        if source.endpoint == .local && destination.endpoint == .local {
            try RecoverableLocalFiles.finishDirectory(from: source.path, to: destination.path)
        }
    }
    func remove(_ path: TransferPath, directory: Bool) throws {
        try checkCancellation()
        if path.endpoint == .local { try RecoverableLocalFiles.remove(path.path, directory: directory) }
        else {
            let fs = try remote(path)
            guard let entry = try fs.entry(at: path.path, cancellation: remoteToken), entry.isDirectory == directory else { throw RemoteError.sourceChanged }
            try fs.removeTransferredFile(at: path.path, expected: entry, cancellation: remoteToken)
        }
    }
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PaneRook-Checkpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }
}
