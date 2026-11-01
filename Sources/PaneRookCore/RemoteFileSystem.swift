import Foundation
import Darwin

public enum RemoteProtocol: String, Codable, Sendable { case ftp, sftp, shell }

public struct RemoteConnection: Sendable {
    public let kind: RemoteProtocol
    public let host: String
    public let port: Int
    public let user: String
    public let password: String
    public let identityFile: String
    public let timeout: Int
    public var displayName: String { "\(kind.rawValue)://\(user.isEmpty ? "" : user + "@")\(host):\(port)" }

    public init(kind: RemoteProtocol, host: String, port: Int, user: String, password: String = "", identityFile: String = "", timeout: Int = 20) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(allowed.contains),
              (1...65535).contains(port), !user.hasPrefix("-"),
              ![user, password, identityFile].contains(where: { $0.contains(where: { $0.isNewline || $0 == "\0" }) }) else { throw RemoteError.invalidConnection }
        self.kind = kind; self.host = host; self.port = port; self.user = user
        self.password = password; self.identityFile = identityFile; self.timeout = max(3, min(timeout, 300))
    }
}

public struct RemoteEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isRegularFile: Bool
    public let size: Int64
    public let modified: Date?
    public init(name: String, isDirectory: Bool, isSymbolicLink: Bool = false, isRegularFile: Bool = true, size: Int64 = 0, modified: Date? = nil) {
        self.name = name; self.isDirectory = isDirectory; self.isSymbolicLink = isSymbolicLink; self.isRegularFile = isRegularFile && !isDirectory && !isSymbolicLink; self.size = size; self.modified = modified
    }
}

public enum RemoteError: LocalizedError {
    case invalidConnection, invalidPath, cancelled, unsupportedListing, symbolicLink, specialFile, collision(String), process(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection: return "Verbindungsdaten sind ungültig."
        case .invalidPath: return "Der Remote-Pfad ist ungültig."
        case .cancelled: return "Vorgang abgebrochen."
        case .unsupportedListing: return "Die Verzeichnisliste des Servers konnte nicht gelesen werden."
        case .symbolicLink: return "Symbolische Links werden bei Remote-Aktionen nicht verarbeitet."
        case .specialFile: return "Geräte und andere Spezialdateien können nicht übertragen werden."
        case .collision(let name): return "\(name) existiert bereits."
        case .process(let message): return message
        }
    }
}

/// One operation owns one cancellation object; cancelling terminates its current transport.
public final class RemoteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() {
        lock.lock(); stopped = true; let running = process; lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }
    public func check() throws { if isCancelled { throw RemoteError.cancelled } }
    fileprivate func attach(_ process: Process?) throws {
        lock.lock(); self.process = process; let cancelled = stopped; lock.unlock()
        if cancelled { if process?.isRunning == true { process?.terminate() }; throw RemoteError.cancelled }
    }
}

public struct RemoteInvocation {
    public var executable: String
    public var arguments: [String]
    public var input: Data?
    public var inputFile: URL?
    public var outputFile: URL?
    public init(executable: String, arguments: [String], input: Data? = nil, inputFile: URL? = nil, outputFile: URL? = nil) {
        self.executable = executable; self.arguments = arguments; self.input = input; self.inputFile = inputFile; self.outputFile = outputFile
    }
}

/// A transport-neutral local/remote bridge. No connection passwords are persisted or passed in argv.
public final class RemoteFileSystem: @unchecked Sendable {
    public typealias Runner = (RemoteInvocation, RemoteCancellation) throws -> Data
    public let connection: RemoteConnection
    private let runner: Runner
    public init(connection: RemoteConnection, runner: @escaping Runner = RemoteFileSystem.run) { self.connection = connection; self.runner = runner }

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
    private static func curlQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private func sshArguments() -> [String] {
        var args = ["-oBatchMode=yes", "-oStrictHostKeyChecking=yes", "-oConnectTimeout=\(connection.timeout)", "-oServerAliveInterval=15", "-oServerAliveCountMax=2"]
        if !connection.identityFile.isEmpty { args += ["-i", (connection.identityFile as NSString).expandingTildeInPath] }
        return args
    }
    private func ssh(_ command: String, token: RemoteCancellation, input: URL? = nil, output: URL? = nil) throws -> Data {
        var args = sshArguments() + ["-p", String(connection.port)]
        if !connection.user.isEmpty { args += ["-l", connection.user] }
        args += ["--", connection.host, command]
        return try runner(RemoteInvocation(executable: "/usr/bin/ssh", arguments: args, inputFile: input, outputFile: output), token)
    }
    private func sftp(_ command: String, token: RemoteCancellation) throws -> Data {
        var args = sshArguments() + ["-q", "-b", "-", "-P", String(connection.port)]
        if !connection.user.isEmpty { args += ["-oUser=\(connection.user)"] }
        args += ["--", connection.host.contains(":") ? "[\(connection.host)]" : connection.host]
        return try runner(RemoteInvocation(executable: "/usr/bin/sftp", arguments: args, input: Data(("@" + command + "\nbye\n").utf8)), token)
    }
    private func ftp(path: String, options: [String] = [], token: RemoteCancellation, output: URL? = nil) throws -> Data {
        var components = URLComponents()
        components.scheme = "ftp"; components.host = connection.host; components.port = connection.port
        // The extra slash makes curl use an absolute server path rather than one relative to login home.
        components.path = "/" + path
        guard let url = components.url else { throw RemoteError.invalidPath }
        let config = ["url = \(Self.curlQuote(url.absoluteString))", "user = \(Self.curlQuote(connection.user + ":" + connection.password))",
                      "silent", "show-error", "fail", "globoff", "connect-timeout = \(connection.timeout)", "max-time = 3600"] + options
        return try runner(RemoteInvocation(executable: "/usr/bin/curl", arguments: ["--config", "-"], input: Data((config.joined(separator: "\n") + "\n").utf8), outputFile: output), token)
    }
    public func list(_ path: String, cancellation: RemoteCancellation = RemoteCancellation()) throws -> [RemoteEntry] {
        try cancellation.check()
        let path = try Self.normalizedPath(path)
        var data: Data
        switch connection.kind {
        case .shell: data = try ssh("LC_ALL=C ls -lan \(Self.shellQuote(path))", token: cancellation)
        case .sftp: data = try sftp("cd \(Self.sftpQuote(path))\n@ls -lan", token: cancellation)
        case .ftp:
            do {
                data = try ftp(path: path + "/", options: ["request = \"MLSD\""], token: cancellation)
                return try Self.parseMLSD(data)
            } catch {
                try cancellation.check()
                data = try ftp(path: path + "/", token: cancellation)
            }
        }
        return try Self.parseLongListing(data)
    }
    public static func parseMLSD(_ data: Data) throws -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteError.unsupportedListing }
        var entries: [RemoteEntry] = []
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let space = line.firstIndex(of: " ") else { throw RemoteError.unsupportedListing }
            let name = String(line[line.index(after: space)...])
            let facts = line[..<space].split(separator: ";").reduce(into: [String: String]()) { values, fact in
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { values[String(pair[0]).lowercased()] = String(pair[1]) }
            }
            guard let type = facts["type"]?.lowercased() else { throw RemoteError.unsupportedListing }
            if ["cdir", "pdir"].contains(type) { continue }
            guard validName(name) else { throw RemoteError.unsupportedListing }
            entries.append(RemoteEntry(name: name, isDirectory: type == "dir", isSymbolicLink: type.contains("slink"), isRegularFile: type == "file", size: Int64(facts["size"] ?? "") ?? 0, modified: facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) }))
        }
        return sorted(entries)
    }
    public static func parseLongListing(_ data: Data) throws -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteError.unsupportedListing }
        // The last separator is exactly one space. Splitting whitespace would silently rename
        // files with leading spaces and could target a different file during deletion.
        let expression = try NSRegularExpression(pattern: #"^([-dlbcps][^\s]+)\s+\S+\s+\S+\s+\S+\s+([0-9]+)\s+\S+\s+\S+\s+\S+ (.*)$"#)
        var entries: [RemoteEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("total ") || line.hasPrefix("sftp>") || line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let modeRange = Range(match.range(at: 1), in: line), let type = line[modeRange].first,
                  let sizeRange = Range(match.range(at: 2), in: line), let size = Int64(line[sizeRange]),
                  let nameRange = Range(match.range(at: 3), in: line) else { throw RemoteError.unsupportedListing }
            var name = String(line[nameRange])
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            guard validName(name) else { throw RemoteError.unsupportedListing }
            entries.append(RemoteEntry(name: name, isDirectory: type == "d", isSymbolicLink: type == "l", isRegularFile: type == "-", size: size))
        }
        return sorted(entries)
    }
    private static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(where: { $0.isNewline || $0 == "\0" }) }
    private static func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] { entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func available(_ path: String, token: RemoteCancellation) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        if try list(parent, cancellation: token).contains(where: { $0.name == name }) { throw RemoteError.collision(name) }
    }
    public func createDirectory(_ path: String, cancellation: RemoteCancellation = RemoteCancellation()) throws {
        let path = try Self.normalizedPath(path)
        guard path != "/" else { throw RemoteError.collision(path) }
        try available(path, token: cancellation)
        switch connection.kind {
        case .shell: _ = try ssh("mkdir \(Self.shellQuote(path))", token: cancellation)
        case .sftp: _ = try sftp("mkdir \(Self.sftpQuote(path))", token: cancellation)
        case .ftp: _ = try ftp(path: "/", options: ["quote = \(Self.curlQuote("MKD " + path))", "list-only"], token: cancellation)
        }
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
            switch connection.kind {
            case .shell: _ = try ssh("cat \(Self.shellQuote(path))", token: token, output: destination)
            case .sftp: _ = try sftp("get \(Self.sftpQuote(path)) \(Self.sftpQuote(destination.path))", token: token)
            case .ftp: _ = try ftp(path: path, token: token, output: destination)
            }
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
            switch connection.kind {
            case .shell: _ = try ssh("umask 077; set -C; cat > \(Self.shellQuote(path))", token: token, input: source)
            case .sftp: _ = try sftp("put \(Self.sftpQuote(source.path)) \(Self.sftpQuote(path))", token: token)
            case .ftp: _ = try ftp(path: path, options: ["upload-file = \(Self.curlQuote(source.path))"], token: token)
            }
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
        switch connection.kind {
        case .shell: _ = try ssh("\(directory ? "rmdir" : "rm") \(Self.shellQuote(path))", token: token)
        case .sftp: _ = try sftp("\(directory ? "rmdir" : "rm") \(Self.sftpQuote(path))", token: token)
        case .ftp: _ = try ftp(path: "/", options: ["quote = \(Self.curlQuote((directory ? "RMD " : "DELE ") + path))", "list-only"], token: token)
        }
    }

    public static func run(_ invocation: RemoteInvocation, _ token: RemoteCancellation) throws -> Data {
        try token.check()
        let process = Process(); process.executableURL = URL(fileURLWithPath: invocation.executable); process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["SSH_ASKPASS_REQUIRE"] = "never"
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardError = errors
        var fileOutput: FileHandle?
        var fileInput: FileHandle?
        if let destination = invocation.outputFile {
            let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            fileOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); process.standardOutput = fileOutput
        } else { process.standardOutput = output }
        if let source = invocation.inputFile { fileInput = try FileHandle(forReadingFrom: source); process.standardInput = fileInput }
        else if invocation.input != nil { process.standardInput = input }
        else { process.standardInput = FileHandle.nullDevice }
        defer { try? fileInput?.close(); try? fileOutput?.close(); try? token.attach(nil) }
        try token.attach(process)
        try process.run()
        if token.isCancelled { process.terminate() }
        let group = DispatchGroup()
        let collectedOutput = RemoteDataBox(), collectedErrors = RemoteDataBox()
        if fileOutput == nil {
            group.enter(); DispatchQueue.global().async {
                Self.collect(output.fileHandleForReading, into: collectedOutput, limit: 16 * 1024 * 1024, stopOnOverflow: process)
                group.leave()
            }
        }
        group.enter(); DispatchQueue.global().async { Self.collect(errors.fileHandleForReading, into: collectedErrors, limit: 8192); group.leave() }
        if let bytes = invocation.input { try input.fileHandleForWriting.write(contentsOf: bytes); try input.fileHandleForWriting.close() }
        process.waitUntilExit(); group.wait()
        try token.check()
        guard !collectedOutput.overflow else { throw RemoteError.process("Die Serverantwort überschreitet 16 MB. Bitte ein kleineres Unterverzeichnis öffnen.") }
        guard process.terminationStatus == 0 else {
            let message = String(data: collectedErrors.data.prefix(8192), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError.process(message?.isEmpty == false ? message! : "Der Server hat den Vorgang abgelehnt (\(process.terminationStatus)).")
        }
        return collectedOutput.data
    }

    private static func collect(_ handle: FileHandle, into box: RemoteDataBox, limit: Int, stopOnOverflow process: Process? = nil) {
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            let available = max(0, limit - box.data.count)
            box.data.append(chunk.prefix(available))
            if chunk.count > available {
                box.overflow = true
                if process?.isRunning == true { process?.terminate() }
            }
        }
    }
}

private final class RemoteDataBox: @unchecked Sendable { var data = Data(); var overflow = false }
