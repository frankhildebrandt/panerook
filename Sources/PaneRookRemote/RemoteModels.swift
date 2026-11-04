import Foundation
import Darwin

public enum RemoteProtocol: String, Codable, Sendable { case ftp, sftp, shell, nextcloud }

public struct RemoteConnection: Sendable {
    public let kind: RemoteProtocol
    public let host: String
    public let port: Int
    public let user: String
    public let password: String
    public let identityFile: String
    public let timeout: Int
    public var displayName: String { RemoteProviderRegistry.provider(for: kind).displayName(self) }

    public init(kind: RemoteProtocol, host: String, port: Int, user: String, password: String = "", identityFile: String = "", timeout: Int = 20) throws {
        let endpoint = try RemoteProviderRegistry.provider(for: kind).validate(host: host, port: port, user: user, password: password, identityFile: identityFile)
        self.kind = kind; self.host = endpoint.host; self.port = endpoint.port
        self.user = user; self.password = password; self.identityFile = endpoint.identityFile
        self.timeout = max(3, min(timeout, 300))
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
    case invalidConnection, invalidNextcloudConnection, invalidPath, cancelled, unsupportedListing, symbolicLink, specialFile, sourceChanged, targetChanged, collision(String), process(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConnection: return "Verbindungsdaten sind ungültig."
        case .invalidNextcloudConnection: return "Bitte eine gültige HTTPS-Serveradresse ohne Zugangsdaten, Suchparameter oder Fragment, einen Port von 1–65535 und den Nextcloud-Benutzernamen eingeben."
        case .invalidPath: return "Der Remote-Pfad ist ungültig."
        case .cancelled: return "Vorgang abgebrochen."
        case .unsupportedListing: return "Die Verzeichnisliste des Servers konnte nicht gelesen werden."
        case .symbolicLink: return "Symbolische Links werden bei Remote-Aktionen nicht verarbeitet."
        case .specialFile: return "Geräte und andere Spezialdateien können nicht übertragen werden."
        case .targetChanged: return "Das Ziel wurde während der Konfliktentscheidung oder Übertragung geändert. Bitte erneut prüfen."
        case .sourceChanged: return "Die Quelle wurde während der Übertragung geändert. Die Kopie bleibt am Ziel; geänderte Quelldaten wurden nicht gelöscht."
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
    func attach(_ process: Process?) throws {
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

