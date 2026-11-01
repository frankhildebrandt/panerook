import Foundation

/// The sole composition point for built-in transports and their provider policy.
enum RemoteProviderRegistry {
    static func provider(for kind: RemoteProtocol) -> any RemoteProvider.Type {
        switch kind {
        case .ftp: return FTPTransport.self
        case .sftp: return SFTPTransport.self
        case .shell: return SSHTransport.self
        case .nextcloud: return NextcloudWebDAV.self
        }
    }
    static func makeTransport(connection: RemoteConnection, runner: @escaping RemoteFileSystem.Runner)
        -> any RemoteTransport
    {
        provider(for: connection.kind).init(connection: connection, runner: runner)
    }
}
