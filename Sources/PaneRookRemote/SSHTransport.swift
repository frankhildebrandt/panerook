import Foundation

struct SSHTransport: RemoteProvider {
    let connection: RemoteConnection
    let runner: RemoteFileSystem.Runner
    private func ssh(_ command: String, token: RemoteCancellation, input: URL? = nil, output: URL? = nil) throws -> Data
    {
        var args = SSHOptions(connection: connection).sshArguments() + ["-p", String(connection.port)]
        if !connection.user.isEmpty { args += ["-l", connection.user] }
        args += ["--", connection.host, command]
        return try runner(
            RemoteInvocation(executable: "/usr/bin/ssh", arguments: args, inputFile: input, outputFile: output), token)
    }

    func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
        try RemoteFileSystem.parseLongListing(
            ssh("LC_ALL=C ls -lan \(RemoteFileSystem.shellQuote(path))", token: token))
    }
    func createDirectory(_ path: String, token: RemoteCancellation) throws {
        _ = try ssh("mkdir \(RemoteFileSystem.shellQuote(path))", token: token)
    }
    func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
        _ = try ssh("cat \(RemoteFileSystem.shellQuote(path))", token: token, output: destination)
    }
    func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
        _ = try ssh("umask 077; set -C; cat > \(RemoteFileSystem.shellQuote(path))", token: token, input: source)
    }
    func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
        _ = try ssh("\(directory ? "rmdir" : "rm") \(RemoteFileSystem.shellQuote(path))", token: token)
    }
}

extension SSHTransport {
    static var description: RemoteProviderDescription {
        let value = RemoteProviderDescription(
            title: "Shell (SSH)", menuTitle: "Shell-Verbindung …", menuOrder: 1, defaultPort: 22, usesPassword: false)
        return value
    }
}
