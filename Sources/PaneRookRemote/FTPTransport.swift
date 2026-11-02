import Foundation

struct FTPTransport: RemoteProvider {
    let connection: RemoteConnection
    let runner: RemoteFileSystem.Runner
    private static func curlQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func ftp(path: String, options: [String] = [], token: RemoteCancellation, output: URL? = nil) throws -> Data
    {
        var components = URLComponents()
        components.scheme = "ftp"
        components.host = connection.host
        components.port = connection.port
        // The extra slash makes curl use an absolute server path rather than one relative to login home.
        components.path = "/" + path
        guard let url = components.url else { throw RemoteError.invalidPath }
        let config =
            [
                "url = \(Self.curlQuote(url.absoluteString))",
                "user = \(Self.curlQuote(connection.user + ":" + connection.password))",
                "silent", "show-error", "fail", "globoff", "connect-timeout = \(connection.timeout)", "max-time = 3600",
            ] + options
        return try runner(
            RemoteInvocation(
                executable: "/usr/bin/curl", arguments: ["--config", "-"],
                input: Data((config.joined(separator: "\n") + "\n").utf8), outputFile: output), token)
    }

    func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
        do {
            return try RemoteFileSystem.parseMLSD(ftp(path: path + "/", options: ["request = \"MLSD\""], token: token))
        } catch {
            try token.check()
            return try RemoteFileSystem.parseLongListing(ftp(path: path + "/", token: token))
        }
    }
    func createDirectory(_ path: String, token: RemoteCancellation) throws {
        _ = try ftp(path: "/", options: ["quote = \(Self.curlQuote("MKD " + path))", "list-only"], token: token)
    }
    func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
        _ = try ftp(path: path, token: token, output: destination)
    }
    func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
        _ = try ftp(path: path, options: ["upload-file = \(Self.curlQuote(source.path))"], token: token)
    }
    func remove(_ path: String, directory: Bool, token: RemoteCancellation) throws {
        _ = try ftp(
            path: "/", options: ["quote = \(Self.curlQuote((directory ? "RMD " : "DELE ") + path))", "list-only"],
            token: token)
    }
    func move(_ path: String, to destination: String, token: RemoteCancellation) throws {
        _ = try ftp(path: "/", options: ["quote = \(Self.curlQuote("RNFR " + path))",
            "quote = \(Self.curlQuote("RNTO " + destination))", "list-only"], token: token)
    }
}

extension FTPTransport {
    static var description: RemoteProviderDescription {
        var value = RemoteProviderDescription(
            title: "FTP", menuTitle: "FTP-Verbindung …", menuOrder: 0, defaultPort: 21, usesPassword: true)
        value.notice = "FTP überträgt Dateien und Passwort unverschlüsselt."
        return value
    }
}
