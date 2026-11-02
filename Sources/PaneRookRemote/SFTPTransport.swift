import Foundation

struct SFTPTransport: RemoteProvider {
    let connection: RemoteConnection
    let runner: RemoteFileSystem.Runner
    private func sftp(_ command: String, token: RemoteCancellation) throws -> Data {
        var args = SSHOptions(connection: connection).sshArguments() + ["-q", "-b", "-", "-P", String(connection.port)]
        if !connection.user.isEmpty { args += ["-oUser=\(connection.user)"] }
        args += ["--", connection.host.contains(":") ? "[\(connection.host)]" : connection.host]
        return try runner(
            RemoteInvocation(
                executable: "/usr/bin/sftp", arguments: args, input: Data(("@" + command + "\nbye\n").utf8)), token)
    }

    func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
        try RemoteFileSystem.parseLongListing(sftp("cd \(RemoteFileSystem.sftpQuote(path))\n@ls -lan", token: token))
    }
    func createDirectory(_ path: String, token: RemoteCancellation) throws {
        _ = try sftp("mkdir \(RemoteFileSystem.sftpQuote(path))", token: token)
    }
    func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
        _ = try sftp(
            "get \(RemoteFileSystem.sftpQuote(path)) \(RemoteFileSystem.sftpQuote(destination.path))", token: token)
    }
    func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
        _ = try sftp("put \(RemoteFileSystem.sftpQuote(source.path)) \(RemoteFileSystem.sftpQuote(path))", token: token)
    }
    func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
        _ = try sftp("\(directory ? "rmdir" : "rm") \(RemoteFileSystem.sftpQuote(path))", token: token)
    }
    func move(_ path: String, to destination: String, token: RemoteCancellation) throws {
        _ = try sftp("rename \(RemoteFileSystem.sftpQuote(path)) \(RemoteFileSystem.sftpQuote(destination))", token: token)
    }
}

extension SFTPTransport {
    static var description: RemoteProviderDescription {
        let value = RemoteProviderDescription(
            title: "SFTP", menuTitle: "SFTP-Verbindung …", menuOrder: 2, defaultPort: 22, usesPassword: false)
        return value
    }
}
