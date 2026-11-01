import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// The archive stores an installation URL and a port, never URL credentials.
struct NextcloudEndpoint {
    let host: String
    let port: Int

    init(host: String, port: Int, user: String, password: String) throws {
        guard !host.isEmpty, !user.isEmpty, user != ".", user != "..", !user.contains(":"), (1...65535).contains(port),
              ![host, user, password].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              var url = URLComponents(string: host.contains("://") ? host : "https://" + host),
              url.scheme?.lowercased() == "https", let hostname = url.host, !hostname.isEmpty,
              !hostname.hasPrefix("-"), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let decodedPath = url.percentEncodedPath.removingPercentEncoding,
              !decodedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !decodedPath.contains("\\") else { throw RemoteError.invalidNextcloudConnection }
        let effectivePort = url.port ?? port
        guard (1...65535).contains(effectivePort) else { throw RemoteError.invalidNextcloudConnection }
        let path = try RemoteFileSystem.normalizedPath(decodedPath)
        url.scheme = "https"; url.port = nil; url.path = path == "/" ? "" : path
        guard let normalized = url.url else { throw RemoteError.invalidNextcloudConnection }
        self.host = normalized.absoluteString
        self.port = effectivePort
    }
}

/// Uses the same cancellable, streaming system-curl runner as the FTP provider.
struct NextcloudWebDAV {
    let connection: RemoteConnection
    let runner: RemoteFileSystem.Runner

    private func url(_ path: String, directory: Bool = false) throws -> URL {
        guard var url = URLComponents(string: connection.host) else { throw RemoteError.invalidConnection }
        url.port = connection.port
        // Encode components individually: '%' in an actual filename is literal,
        // and a slash in a user ID must never change the DAV hierarchy.
        let pieces = url.path.split(separator: "/").map(String.init)
            + ["remote.php", "dav", "files", connection.user]
            + path.split(separator: "/").map(String.init)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        url.percentEncodedPath = "/" + pieces.map { $0.addingPercentEncoding(withAllowedCharacters: unreserved)! }.joined(separator: "/") + (directory ? "/" : "")
        guard let result = url.url else { throw RemoteError.invalidPath }
        return result
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private func request(_ method: String, url: URL, options: [String] = [], expected: Set<Int>, token: RemoteCancellation) throws -> Data {
        try token.check()
        // -q ignores ~/.curlrc, including any redirect or insecure-TLS defaults.
        // HTTP status is appended to stdout; downloads stream into a private
        // staging file via curl's output option, leaving stdout for status only.
        let config = ["url = \(Self.quote(url.absoluteString))", "user = \(Self.quote(connection.user + ":" + connection.password))",
                      "request = \(Self.quote(method))", "silent", "show-error", "globoff",
                      "proto = \"=https\"", "connect-timeout = \(connection.timeout)", "max-time = 3600",
                      "write-out = \(Self.quote("\n%{http_code}"))"] + options
        let response = try runner(RemoteInvocation(executable: "/usr/bin/curl", arguments: ["-q", "--config", "-"],
            input: Data((config.joined(separator: "\n") + "\n").utf8)), token)
        try token.check()
        guard let separator = response.lastIndex(of: 10),
              let statusText = String(data: response[response.index(after: separator)...], encoding: .utf8),
              statusText.count == 3, let status = Int(statusText) else {
            throw RemoteError.process("Nextcloud hat keinen gültigen HTTP-Status geliefert.")
        }
        guard expected.contains(status) else {
            let message: String
            switch status {
            case 301...399: message = "Die Nextcloud-Adresse leitet weiter. Bitte die endgültige HTTPS-Serveradresse verwenden."
            case 401: message = "Nextcloud-Anmeldung fehlgeschlagen. Benutzername und App-Passwort prüfen."
            case 403: message = "Nextcloud hat den Zugriff verweigert. Bitte die Berechtigungen prüfen."
            case 404: message = "Nextcloud-Pfad nicht gefunden. Serveradresse, Benutzername und Startpfad prüfen."
            case 412: throw RemoteError.collision(url.lastPathComponent)
            case 423: message = "Die Datei ist in Nextcloud gesperrt."
            case 507: message = "Der Nextcloud-Speicherplatz reicht nicht aus."
            default: message = "Nextcloud hat den Vorgang abgelehnt (HTTP \(status))."
            }
            throw RemoteError.process(message)
        }
        return Data(response[..<separator])
    }

    func list(_ path: String, token: RemoteCancellation) throws -> [RemoteEntry] {
        let target = try url(path, directory: true)
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"
        let data = try request("PROPFIND", url: target, options: ["header = \"Depth: 1\"", "header = \"Content-Type: application/xml; charset=utf-8\"", "data = \(Self.quote(body))"], expected: [207], token: token)
        return try DAVListing.parse(data, relativeTo: target)
    }

    func createDirectory(_ path: String, token: RemoteCancellation) throws {
        _ = try request("MKCOL", url: url(path), expected: [201], token: token)
    }

    func download(_ path: String, to destination: URL, token: RemoteCancellation) throws {
        _ = try request("GET", url: url(path), options: ["output = \(Self.quote(destination.path))"], expected: [200], token: token)
    }

    func upload(_ source: URL, to path: String, token: RemoteCancellation) throws {
        _ = try request("PUT", url: url(path), options: ["header = \"If-None-Match: *\"", "upload-file = \(Self.quote(source.path))"], expected: [201], token: token)
    }

    func remove(_ path: String, token: RemoteCancellation) throws {
        _ = try request("DELETE", url: url(path), expected: [204], token: token)
    }
}

/// Parse DAV namespaces and successful propstats explicitly. Hrefs, rather than
/// display names, identify files; a malformed listing must never target a sibling
/// or a resource outside the directory the user actually opened.
private final class DAVListing: NSObject, XMLParserDelegate {
    private final class Node {
        let name: String
        let namespace: String?
        var text = ""
        var children: [Node] = []
        init(_ name: String, _ namespace: String?) { self.name = name; self.namespace = namespace }
        func elements(_ name: String) -> [Node] { children.filter { $0.name == name && $0.namespace == "DAV:" } }
        func one(_ name: String) throws -> Node {
            let matches = elements(name)
            guard matches.count == 1 else { throw RemoteError.unsupportedListing }
            return matches[0]
        }
    }
    private var stack: [Node] = []
    private var root: Node?
    private var count = 0
    private var invalid = false

    static func parse(_ data: Data, relativeTo target: URL) throws -> [RemoteEntry] {
        guard data.count <= 16 * 1024 * 1024 else { throw RemoteError.unsupportedListing }
        let delegate = DAVListing(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root,
              root.name == "multistatus", root.namespace == "DAV:" else { throw RemoteError.unsupportedListing }
        let base = try pathComponents(target)
        var entries: [RemoteEntry] = [], names = Set<String>(), foundSelf = false
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for response in root.elements("response") {
            let href = try response.one("href").text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: href, relativeTo: target)?.absoluteURL,
                  url.scheme?.lowercased() == "https", url.host?.lowercased() == target.host?.lowercased(),
                  (url.port ?? 443) == (target.port ?? 443), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw RemoteError.unsupportedListing }
            let path = try pathComponents(url)
            var properties: [String: Node] = [:]
            for propstat in response.elements("propstat") {
                let status = try propstat.one("status").text.split(whereSeparator: \.isWhitespace)
                guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else { throw RemoteError.unsupportedListing }
                if !(200...299).contains(code) { continue }
                for property in try propstat.one("prop").children where property.namespace == "DAV:" {
                    guard properties[property.name] == nil else { throw RemoteError.unsupportedListing }
                    properties[property.name] = property
                }
            }
            guard let type = properties["resourcetype"],
                  type.children.allSatisfy({ $0.namespace == "DAV:" && $0.name == "collection" }) else { throw RemoteError.unsupportedListing }
            let directory = !type.elements("collection").isEmpty
            if path == base {
                guard directory, !foundSelf else { throw RemoteError.unsupportedListing }
                foundSelf = true; continue
            }
            guard path.count == base.count + 1, path.starts(with: base), let name = path.last,
                  names.insert(name).inserted else { throw RemoteError.unsupportedListing }
            var size: Int64 = 0
            if let length = properties["getcontentlength"] {
                guard let value = Int64(length.text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { throw RemoteError.unsupportedListing }
                size = value
            }
            let modified = properties["getlastmodified"].flatMap { formatter.date(from: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            entries.append(RemoteEntry(name: name, isDirectory: directory, size: size, modified: modified))
        }
        guard foundSelf else { throw RemoteError.unsupportedListing }
        return entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func pathComponents(_ url: URL) throws -> [String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw RemoteError.unsupportedListing }
        var pieces = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.first == "" { pieces.removeFirst() }
        if pieces.last == "" { pieces.removeLast() }
        return try pieces.map { piece in
            guard let decoded = String(piece).removingPercentEncoding, !decoded.isEmpty,
                  decoded != ".", decoded != "..", !decoded.contains("/"),
                  !decoded.contains(where: { $0.isNewline || $0 == "\0" }) else { throw RemoteError.unsupportedListing }
            return decoded
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 32, count <= 200_000 else { invalid = true; parser.abortParsing(); return }
        let node = Node(elementName, namespaceURI)
        if let parent = stack.last { parent.children.append(node) }
        else if root == nil { root = node }
        else { invalid = true; parser.abortParsing(); return }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { invalid = true; parser.abortParsing() }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { invalid = true; parser.abortParsing() }
}
