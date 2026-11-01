import Foundation

/// Primitive operations only. Recursion, collision checks, staging and publication
/// belong to RemoteFileSystem and apply identically to every transport.
protocol RemoteTransport {
    func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry]
    func createDirectory(_ path: String, token: RemoteCancellation) throws
    func download(_ path: String, to destination: URL, token: RemoteCancellation) throws
    func upload(_ source: URL, to path: String, token: RemoteCancellation) throws
    func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws
}

extension NextcloudWebDAV: RemoteProvider {
    func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
        try remove(path, token: token)
    }
}

/// Provider policy belongs beside the transport, including connection validation.
protocol RemoteProvider: RemoteTransport {
    init(connection: RemoteConnection, runner: @escaping RemoteFileSystem.Runner)
    static var description: RemoteProviderDescription { get }
    static func validate(host: String, port: Int, user: String, password: String, identityFile: String) throws
        -> RemoteEndpoint
    static func displayName(_ connection: RemoteConnection) -> String
}
struct RemoteEndpoint {
    let host: String
    let port: Int
    let identityFile: String
}
extension RemoteProvider {
    static func validate(host: String, port: Int, user: String, password: String, identityFile: String) throws
        -> RemoteEndpoint
    {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
            (1...65535).contains(port), !user.hasPrefix("-"),
            ![user, password, identityFile].contains(where: { $0.contains(where: { $0.isNewline || $0 == "\0" }) })
        else { throw RemoteError.invalidConnection }
        return RemoteEndpoint(host: host, port: port, identityFile: identityFile)
    }
    static func displayName(_ connection: RemoteConnection) -> String {
        "\(connection.kind.rawValue)://\(connection.user.isEmpty ? "" : connection.user + "@")\(connection.host):\(connection.port)"
    }
}
