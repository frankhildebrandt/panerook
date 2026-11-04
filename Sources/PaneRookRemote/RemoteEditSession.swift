import Foundation
import CryptoKit

public enum RemoteEditError: LocalizedError {
    case busy, unstableFile, missingFile, invalidWorkspace, unsafePublication
    case recovery(String)
    public var errorDescription: String? {
        switch self {
        case .busy: return "Für diese Datei läuft bereits ein Vorgang."
        case .unstableFile: return "Die Datei wird noch gespeichert oder wurde während der Übertragung geändert. Bitte erneut versuchen."
        case .missingFile: return "Die Arbeitskopie fehlt oder ist keine reguläre Datei. Sie wird nicht automatisch ersetzt."
        case .invalidWorkspace: return "Die gespeicherte Remote-Arbeitskopie konnte nicht sicher gelesen werden. Bitte den Arbeitskopienordner prüfen."
        case .unsafePublication: return "Dieser FTP-Transport kann bestehende Dateien nicht sicher ersetzen. Die Arbeitskopie bleibt erhalten; zum Übertragen einen neuen Dateinamen oder SFTP verwenden."
        case .recovery(let paths): return "Die Veröffentlichung wurde unterbrochen. Arbeitskopie und Serversicherung bleiben erhalten. Vor einem erneuten Upload die Serverpfade prüfen:\n" + paths
        }
    }
}

public struct RemoteEditIdentity: Codable, Equatable, Sendable {
    public let kind: RemoteProtocol
    public let host: String
    public let port: Int
    public let user: String
    public let path: String
    public init(connection: RemoteConnection, path: String) throws {
        kind = connection.kind; host = connection.host; port = connection.port; user = connection.user
        self.path = try RemoteFileSystem.normalizedPath(path)
    }
}

/// A missing file is a revision too. Approval applies to exactly one observed revision.
public struct RemoteEditRevision: Codable, Equatable, Sendable {
    public let digest: String?
    public let size: Int64
    public let modified: Date?
    static let missing = RemoteEditRevision(digest: nil, size: 0, modified: nil)
}

public enum RemoteEditPhase: String, Sendable { case ready, checking, uploading, conflict, failed }
public struct RemoteEditSnapshot: Sendable {
    public let phase: RemoteEditPhase
    public let hasChanges: Bool
    public let message: String
    public let conflict: RemoteEditRevision?
    public let serverArtifacts: [String]
    public var isBusy: Bool { phase == .checking || phase == .uploading }
}
public enum RemoteEditUploadResult: Equatable { case unchanged, uploaded, conflict(RemoteEditRevision) }

/// UI-free session. Network jobs are serialized by the caller; state reads and
/// content polling may run concurrently. No working copy is ever deleted here.
public final class RemoteEditSession: @unchecked Sendable {
    private struct Manifest: Codable {
        var identity: RemoteEditIdentity
        var baseline: RemoteEditRevision
        var artifacts: [String] = []
    }
    public let identity: RemoteEditIdentity
    public let workingURL: URL
    public let workspace: URL
    private let fileSystem: RemoteFileSystem
    private let lock = NSLock()
    private var manifest: Manifest
    private var phase: RemoteEditPhase = .ready
    private var dirty = false
    private var message = "Arbeitskopie bereit"
    private var conflict: RemoteEditRevision?
    private var observed: String?
    private var observedSince: Date = .distantPast
    private var active = false
    private var observationFailed = false

    private init(fileSystem: RemoteFileSystem, workspace: URL, manifest: Manifest) {
        self.fileSystem = fileSystem; self.workspace = workspace; self.manifest = manifest
        identity = manifest.identity
        workingURL = workspace.appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent((manifest.identity.path as NSString).lastPathComponent)
    }
    public var snapshot: RemoteEditSnapshot {
        lock.withLock { RemoteEditSnapshot(phase: phase, hasChanges: dirty, message: message,
                                          conflict: conflict, serverArtifacts: manifest.artifacts) }
    }

    /// Reopens an existing copy after reconnecting, without storing credentials or
    /// replacing local content. Corrupt manifests are reported, never cleaned up.
    public static func prepare(fileSystem: RemoteFileSystem, path: String, root: URL,
                               cancellation: RemoteCancellation = RemoteCancellation()) throws -> RemoteEditSession {
        let identity = try RemoteEditIdentity(connection: fileSystem.connection, path: path)
        guard identity.path != "/" else { throw RemoteError.invalidPath }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let root = root.resolvingSymlinksInPath()
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try cancellation.check()
            guard folder.hasDirectoryPath || (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let record = folder.appendingPathComponent("session.json")
            guard FileManager.default.fileExists(atPath: record.path) else { continue }
            guard let saved = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: record)) else {
                throw RemoteEditError.invalidWorkspace
            }
            if saved.identity == identity {
                let session = RemoteEditSession(fileSystem: fileSystem, workspace: folder, manifest: saved)
                _ = try Self.digest(session.workingURL, token: cancellation)
                try session.pollChanges(settleInterval: 0)
                return session
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("work"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = RemoteEditSession(fileSystem: fileSystem, workspace: folder,
                                       manifest: Manifest(identity: identity, baseline: .missing))
        // This folder has not been exposed to an editor yet; only this initial
        // failed download is eligible for cleanup.
        do {
            let revision = try session.readRevision(at: identity.path, copyTo: session.workingURL, token: cancellation)
            guard revision.digest != nil else { throw RemoteEditError.missingFile }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: session.workingURL.path)
            session.manifest.baseline = revision
            try session.persist()
            return session
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    /// Poll the path, not its inode: editors may atomically replace the file.
    /// Two stable content observations coalesce event bursts; hashes also detect
    /// changes when an editor preserves timestamps and size.
    public func pollChanges(now: Date = Date(), settleInterval: TimeInterval = 0.8) throws {
        do {
            let digest = try Self.digest(workingURL)
            lock.withLock {
                if observationFailed && !active { phase = .ready; observationFailed = false }
                if digest != observed { observed = digest; observedSince = now }
                dirty = digest != manifest.baseline.digest
                guard !active, phase != .conflict else { return }
                if dirty && now.timeIntervalSince(observedSince) < settleInterval { message = "Speichern wird abgewartet …" }
                else if phase != .failed { message = dirty ? "Geändert · bereit zum Hochladen" : "Keine ungesendeten Änderungen" }
            }
        } catch {
            lock.withLock {
                dirty = true
                if !active { phase = .failed; observationFailed = true; message = error.localizedDescription }
            }
            throw error
        }
    }

    public func upload(approving revision: RemoteEditRevision? = nil,
                       cancellation token: RemoteCancellation = RemoteCancellation(),
                       progress: (String) -> Void = { _ in }) throws -> RemoteEditUploadResult {
        try lock.withLock {
            guard !active else { throw RemoteEditError.busy }
            active = true; phase = .checking; message = "Serverversion wird geprüft …"; conflict = nil
        }
        defer { lock.withLock { active = false } }
        let scratch = workspace.appendingPathComponent("transfer-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var backedUp = false
        do {
            try token.check()
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let payload = scratch.appendingPathComponent("payload")
            let before = try Self.digest(workingURL, token: token)
            try FileManager.default.copyItem(at: workingURL, to: payload)
            let uploadedDigest = try Self.digest(payload, token: token)
            guard before == uploadedDigest, try Self.digest(workingURL, token: token) == uploadedDigest else { throw RemoteEditError.unstableFile }
            let baseline = lock.withLock { manifest.baseline }
            if uploadedDigest == baseline.digest, revision == nil {
                lock.withLock { phase = .ready; dirty = false; message = "Keine ungesendeten Änderungen" }
                return .unchanged
            }
            guard fileSystem.transport.supportsExclusiveRename else { throw RemoteEditError.unsafePublication }
            progress("Serverversion prüfen")
            let current = try readRevision(at: identity.path, token: token)
            let expected = revision ?? baseline
            guard current == expected else { return markConflict(current) }
            let parent = (identity.path as NSString).deletingLastPathComponent
            let nonce = UUID().uuidString
            let staged = try RemoteFileSystem.normalizedPath(".PaneRookEdit-" + nonce + ".upload", relativeTo: parent)
            let backup = try RemoteFileSystem.normalizedPath(".PaneRookEdit-" + nonce + ".backup", relativeTo: parent)
            // Journal before changing server state, including paths needed after
            // a lost connection, cancellation or a process crash.
            try lock.withLock { manifest.artifacts += [staged]; try persist() }
            lock.withLock { phase = .uploading; message = "Änderungen werden hochgeladen …" }
            progress("Neue Version übertragen")
            try fileSystem.transport.upload(payload, to: staged, token: token)
            guard try readRevision(at: staged, token: token).digest == uploadedDigest else { throw RemoteEditError.unstableFile }
            let checked = try readRevision(at: identity.path, token: token)
            guard checked == expected else {
                // Unique staging may remain on the server; its path is journaled.
                return markConflict(checked)
            }
            try token.check()
            if current.digest != nil {
                try lock.withLock { manifest.artifacts += [backup]; try persist() }
                progress("Vorherige Serverversion sichern")
                try fileSystem.transport.moveExclusively(identity.path, to: backup, token: token)
                backedUp = true
                // Detect a writer racing the preflight query. Never publish over
                // that version, and keep it intact at the journaled backup path.
                let saved = try readRevision(at: backup, token: token)
                guard saved.digest == expected.digest, saved.size == expected.size else {
                    throw RemoteEditError.recovery(backup)
                }
            }
            guard try readRevision(at: identity.path, token: token) == .missing else {
                throw RemoteEditError.recovery(lock.withLock { manifest.artifacts.joined(separator: "\n") })
            }
            try token.check()
            // SSH mv -n, standard SFTP rename and DAV Overwrite:F must reject a
            // target created after the last query. FTP cannot promise this.
            try fileSystem.transport.moveExclusively(staged, to: identity.path, token: token)
            let published = try readRevision(at: identity.path, token: token)
            guard published.digest == uploadedDigest else {
                throw RemoteEditError.recovery(lock.withLock { manifest.artifacts.joined(separator: "\n") })
            }
            let localDigest = try Self.digest(workingURL, token: token)
            try lock.withLock {
                manifest.baseline = published; manifest.artifacts.removeAll { $0 == staged }
                try persist()
                dirty = localDigest != uploadedDigest; phase = .ready; conflict = nil
                message = dirty ? "Hochgeladen · weitere lokale Änderungen ausstehend" : "Hochgeladen · Serversicherung erhalten"
            }
            progress("Abgeschlossen")
            return .uploaded
        } catch {
            lock.withLock {
                phase = .failed; dirty = true
                message = error.localizedDescription + (backedUp ? "\nServersicherung: " + manifest.artifacts.joined(separator: "\n") : "")
            }
            throw error
        }
    }

    private func markConflict(_ current: RemoteEditRevision) -> RemoteEditUploadResult {
        lock.withLock {
            phase = .conflict; conflict = current; dirty = true
            message = current.digest == nil ? "Konflikt: Serverdatei fehlt" : "Konflikt: Serverdatei wurde geändert"
        }
        return .conflict(current)
    }
    private func persist() throws {
        try JSONEncoder().encode(manifest).write(to: workspace.appendingPathComponent("session.json"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.appendingPathComponent("session.json").path)
    }
    private func readRevision(at path: String, copyTo destination: URL? = nil, token: RemoteCancellation) throws -> RemoteEditRevision {
        try token.check()
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard let entry = try fileSystem.list(parent, cancellation: token).first(where: { $0.name == name }) else { return .missing }
        guard entry.isRegularFile && !entry.isSymbolicLink else { throw RemoteError.specialFile }
        let output = destination ?? workspace.appendingPathComponent("probe-" + UUID().uuidString)
        defer { if destination == nil { try? FileManager.default.removeItem(at: output) } }
        try fileSystem.download(entry, from: parent, to: output, cancellation: token)
        let digest = try Self.digest(output, token: token)
        guard try fileSystem.list(parent, cancellation: token).first(where: { $0.name == name }) == entry else {
            throw RemoteEditError.unstableFile
        }
        return RemoteEditRevision(digest: digest, size: entry.size, modified: entry.modified)
    }
    private static func digest(_ url: URL, token: RemoteCancellation = RemoteCancellation()) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteEditError.missingFile }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try token.check()
            let data = try file.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
