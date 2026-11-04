import Foundation

/// Only public endpoint identity is serializable. Credentials and processes belong to the host.
public struct TransferEndpoint: Codable, Hashable, Sendable {
    public var scheme: String
    public var host: String
    public var port: Int
    public var user: String
    public var identityFile: String
    public init(scheme: String = "file", host: String = "", port: Int = 0, user: String = "", identityFile: String = "") {
        self.scheme = scheme; self.host = host; self.port = port; self.user = user; self.identityFile = identityFile
    }
    public static let local = TransferEndpoint()
}

public struct TransferPath: Codable, Hashable, Sendable {
    public var endpoint: TransferEndpoint
    public var path: String
    public init(_ path: String, endpoint: TransferEndpoint = .local) { self.path = path; self.endpoint = endpoint }
    public func appending(_ name: String) -> TransferPath {
        TransferPath((path as NSString).appendingPathComponent(name), endpoint: endpoint)
    }
}

public struct TransferFingerprint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, directory, symbolicLink }
    public var kind: Kind
    public var size: Int64
    public var modified: Date?
    public var identity: String?
    public var digest: String?
    public init(kind: Kind, size: Int64 = 0, modified: Date? = nil, identity: String? = nil, digest: String? = nil) {
        self.kind = kind; self.size = size; self.modified = modified; self.identity = identity; self.digest = digest
    }
    public func hasSameContent(as other: Self) -> Bool { kind == other.kind && size == other.size && digest == other.digest }
}

public struct TransferRoot: Codable, Sendable {
    public var source: TransferPath
    public var destination: TransferPath
    public init(source: TransferPath, destination: TransferPath) { self.source = source; self.destination = destination }
}

public struct RecoverableTransfer: Codable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled }
    public struct Entry: Codable, Sendable {
        public var root: TransferRoot
        public var source: TransferFingerprint
        public var destination: TransferFingerprint?
        public var sourceRemoved = false
        public var error: String?
        public var originalDestination: TransferPath?
        public var renamed: Bool?
        public var skipped: Bool?
        public var preserveSource: Bool?
        public var merged: Bool?
        public var replaced: Bool?
    }
    public var allowsConflicts: Bool?
    public let version: Int
    public let id: UUID
    public var title: String
    public var moving: Bool
    public var roots: [TransferRoot]
    /// nil means discovery has not committed yet; no filesystem writes have taken place.
    public struct Anchor: Codable, Sendable {
        public var path: TransferPath
        public var fingerprint: TransferFingerprint
    }
    public var anchors: [Anchor]?
    public var entries: [Entry]?
    public var state: State = .queued
    public var error: String?
    public init(title: String, moving: Bool, roots: [TransferRoot]) {
        version = 1; id = UUID(); self.title = title; self.moving = moving; self.roots = roots
    }
    public var detail: String {
        let explanation = "Fortsetzung auf Dateiebene · Quellen und Ziele werden geprüft · " + (allowsConflicts == true ? "Konflikte nur nach Rückfrage" : "kein Überschreiben")
        guard let entries else { return explanation + "\n" + roots.map { "\($0.source.path) → \($0.destination.path)" }.joined(separator: "\n") }
        let failed = entries.filter { $0.error != nil }.count
        let done = entries.filter { $0.skipped == true || ($0.destination != nil && $0.error == nil && (!moving || $0.sourceRemoved || $0.preserveSource == true || $0.source.kind == .directory)) }.count
        return explanation + "\n\(done) abgeschlossen · \(failed) fehlgeschlagen · \(entries.count - done - failed) offen\n"
            + entries.prefix(500).map { entry in
                let status = entry.skipped == true ? "Übersprungen · Quelle bleibt erhalten" : entry.error.map { "Fehler: " + $0 } ?? (entry.destination == nil ? "Offen" : moving && !entry.sourceRemoved ? "Übertragen · Quelllöschung offen" : "Abgeschlossen")
                return "\(entry.root.source.path) → \(entry.root.destination.path): \(status)"
            }.joined(separator: "\n") + (entries.count > 500 ? "\nWeitere Einträge stehen im gespeicherten Transfermanifest." : "")
    }
}

public enum RecoverableTransferError: LocalizedError {
    case conflict(String), changed(String), incomplete(Int), invalidPlan
    public var errorDescription: String? {
        switch self {
        case .conflict(let path): return "Ziel existiert oder ist nicht sicher zuzuordnen: \(path). Bitte prüfen; es wird nicht überschrieben."
        case .changed(let path): return "Quelle oder abgeschlossenes Ziel wurde geändert: \(path). Bitte prüfen und gegebenenfalls einen neuen Auftrag anlegen."
        case .incomplete(let count): return "\(count) Einträge fehlgeschlagen. Details öffnen und nach Beheben der Ursache erneut fortsetzen."
        case .invalidPlan: return "Ungültiger oder zu großer Transferauftrag."
        }
    }
}

/// Implementations must never follow links during discovery or recursively remove a directory.
public protocol RecoverableTransferAccess {
    func checkCancellation() throws
    func fingerprint(_ path: TransferPath) throws -> TransferFingerprint?
    func children(_ path: TransferPath) throws -> [String]
    func createDirectory(_ path: TransferPath) throws
    func copyFile(from: TransferPath, to: TransferPath, progress: @escaping (OperationProgress) -> Void) throws
    func remove(_ path: TransferPath, directory: Bool) throws
    func finishDirectory(from: TransferPath, to: TransferPath) throws
    func resolveConflict(_ root: TransferRoot, source: TransferFingerprint, target: TransferFingerprint) throws -> RecoverableConflictAction?
    func replaceItem(from: TransferPath, to: TransferPath, expected: TransferFingerprint, progress: @escaping (OperationProgress) -> Void) throws
}

public extension RecoverableTransferAccess {
    func finishDirectory(from: TransferPath, to: TransferPath) throws {}
    func resolveConflict(_ root: TransferRoot, source: TransferFingerprint, target: TransferFingerprint) throws -> RecoverableConflictAction? { nil }
    func replaceItem(from: TransferPath, to: TransferPath, expected: TransferFingerprint, progress: @escaping (OperationProgress) -> Void) throws { throw RecoverableTransferError.conflict(to.path) }
}

public enum RecoverableConflictAction: Sendable { case skip, keepBoth, replace, merge }

/// A checkpoint is durable before removing any source. Unknown/partial destinations are never adopted.
public enum RecoverableTransferWorker {
    private struct CheckpointFailure: Error { let underlying: Error }
    public static func run(_ transfer: inout RecoverableTransfer, access: any RecoverableTransferAccess,
                           checkpoint: (RecoverableTransfer) throws -> Void,
                           progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        func save(_ value: RecoverableTransfer) throws {
            do { try checkpoint(value) } catch { throw CheckpointFailure(underlying: error) }
        }
        try transfer.validate()
        try access.checkCancellation()
        if transfer.entries == nil {
            var discovered: [RecoverableTransfer.Entry] = []
            var anchors: [RecoverableTransfer.Anchor] = []
            for root in transfer.roots {
                for path in [root.source, root.destination] {
                    let parent = TransferPath((path.path as NSString).deletingLastPathComponent, endpoint: path.endpoint)
                    guard let fingerprint = try access.fingerprint(parent), fingerprint.kind == .directory else { throw RecoverableTransferError.changed(parent.path) }
                    anchors.append(.init(path: parent, fingerprint: fingerprint))
                }
            }
            func scan(_ root: TransferRoot, depth: Int) throws {
                try access.checkCancellation()
                guard depth < 256, discovered.count < 100_000,
                      let source = try access.fingerprint(root.source) else { throw RecoverableTransferError.invalidPlan }
                discovered.append(.init(root: root, source: source))
                progress(OperationProgress(currentPath: root.source.path))
                if source.kind == .directory {
                    for name in try access.children(root.source).sorted() {
                        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
                            throw RecoverableTransferError.invalidPlan
                        }
                        try scan(.init(source: root.source.appending(name), destination: root.destination.appending(name)), depth: depth + 1)
                    }
                }
            }
            guard !transfer.roots.isEmpty else { throw RecoverableTransferError.invalidPlan }
            // Reject same/nested paths before discovery; resolving local aliases belongs to the adapter.
            for root in transfer.roots where root.source.endpoint == root.destination.endpoint {
                guard (transfer.allowsConflicts == true || root.source.path != root.destination.path),
                      !root.destination.path.hasPrefix(root.source.path + "/") else { throw RecoverableTransferError.invalidPlan }
            }
            for root in transfer.roots {
                if transfer.allowsConflicts != true, try access.fingerprint(root.destination) != nil { throw RecoverableTransferError.conflict(root.destination.path) }
                try scan(root, depth: 0)
            }
            transfer.anchors = anchors
            transfer.entries = discovered
            try transfer.validate()
            try save(transfer)
        }
        for anchor in transfer.anchors ?? [] {
            guard try access.fingerprint(anchor.path) == anchor.fingerprint else { throw RecoverableTransferError.changed(anchor.path.path) }
        }
        // Validate completed destinations before making further changes, including empty directories.
        for index in transfer.entries!.indices {
            let entry = transfer.entries![index]
            if let expected = entry.destination {
                guard try access.fingerprint(entry.root.destination) == expected else {
                    transfer.entries![index].error = RecoverableTransferError.changed(entry.root.destination.path).localizedDescription
                    try save(transfer)
                    throw RecoverableTransferError.changed(entry.root.destination.path)
                }
            }
        }
        for index in transfer.entries!.indices {
            try access.checkCancellation()
            if transfer.entries![index].skipped == true { continue }
            var entry = transfer.entries![index]
            if let parent = transfer.entries!.first(where: {
                $0.source.kind == .directory && $0.root.source != entry.root.source && entry.belongs(to: $0)
                    && ($0.destination == nil || $0.error != nil)
            }) {
                transfer.entries![index].error = "Übergeordneter Eintrag noch nicht abgeschlossen: " + parent.root.source.path
                try save(transfer)
                continue
            }
            do {
                let source = try access.fingerprint(entry.root.source)
                if transfer.moving, entry.destination != nil, source == nil {
                    // A crash after unlink but before saving this flag is safe to reconcile.
                    entry.sourceRemoved = true
                } else {
                    guard !entry.sourceRemoved else { throw RecoverableTransferError.changed(entry.root.source.path) }
                    guard source == entry.source else { throw RecoverableTransferError.changed(entry.root.source.path) }
                    if entry.source.kind == .directory {
                        let expected = Set(transfer.entries!.filter {
                            $0.root.source.endpoint == entry.root.source.endpoint && ($0.root.source.path as NSString).deletingLastPathComponent == entry.root.source.path
                        }.map { ($0.root.source.path as NSString).lastPathComponent })
                        let actual = Set(try access.children(entry.root.source))
                        guard transfer.moving ? actual.isSubset(of: expected) : actual == expected else { throw RecoverableTransferError.changed(entry.root.source.path) }
                    }
                    if entry.destination == nil {
                        // Check destination ancestors as well: a renamed/replaced merge
                        // directory must never redirect the remaining manifest entries.
                        for parent in transfer.entries! where parent.source.kind == .directory
                            && parent.root.destination.endpoint == entry.root.destination.endpoint
                            && entry.root.destination.path.hasPrefix(parent.root.destination.path + "/") {
                            if let expected = parent.destination {
                                guard try access.fingerprint(parent.root.destination) == expected else { throw RecoverableTransferError.changed(parent.root.destination.path) }
                            }
                        }
                        if let existing = try access.fingerprint(entry.root.destination) {
                            guard transfer.allowsConflicts == true,
                                  let action = try access.resolveConflict(entry.root, source: entry.source, target: existing) else {
                                throw RecoverableTransferError.conflict(entry.root.destination.path)
                            }
                            try access.checkCancellation()
                            guard try access.fingerprint(entry.root.source) == entry.source else { throw RecoverableTransferError.changed(entry.root.source.path) }
                            switch action {
                            case .skip:
                                for child in transfer.entries!.indices where transfer.entries![child].belongs(to: entry) {
                                    transfer.entries![child].skipped = true; transfer.entries![child].error = nil
                                }
                                try save(transfer)
                                continue
                            case .keepBoth:
                                let original = entry.root.destination
                                var candidate = original, number = 2
                                let name = (original.path as NSString).lastPathComponent as NSString
                                while try access.fingerprint(candidate) != nil || transfer.entries!.contains(where: { $0.root.destination == candidate && $0.root.source != entry.root.source }) {
                                    let suffix = name.pathExtension
                                    let stem = suffix.isEmpty ? name as String : name.deletingPathExtension
                                    candidate = TransferPath((original.path as NSString).deletingLastPathComponent, endpoint: original.endpoint)
                                        .appending(stem + " (\(number))" + (suffix.isEmpty ? "" : "." + suffix))
                                    number += 1
                                }
                                let selfTransfer = entry.root.source == original
                                for child in transfer.entries!.indices where transfer.entries![child].belongs(to: entry) {
                                    if transfer.entries![child].originalDestination == nil { transfer.entries![child].originalDestination = transfer.entries![child].root.destination }
                                    let suffix = transfer.entries![child].root.destination.path.dropFirst(original.path.count)
                                    transfer.entries![child].root.destination = TransferPath(candidate.path + suffix, endpoint: candidate.endpoint)
                                    if selfTransfer { transfer.entries![child].preserveSource = true }
                                }
                                transfer.entries![index].renamed = true
                                entry = transfer.entries![index]
                                try save(transfer)
                            case .merge:
                                guard entry.source.kind == .directory, existing.kind == .directory,
                                      entry.root.source != entry.root.destination,
                                      try access.fingerprint(entry.root.destination) == existing else { throw RecoverableTransferError.conflict(entry.root.destination.path) }
                                entry.merged = true; entry.destination = existing
                            case .replace:
                                guard entry.root.source != entry.root.destination else { throw RecoverableTransferError.conflict(entry.root.destination.path) }
                                entry.replaced = true
                                transfer.entries![index] = entry
                                try save(transfer) // Intent is durable before replacing; retry asks again.
                                for child in transfer.entries! where child.belongs(to: entry) {
                                    guard try access.fingerprint(child.root.source) == child.source else { throw RecoverableTransferError.changed(child.root.source.path) }
                                    if child.source.kind == .directory {
                                        let names = Set(transfer.entries!.filter { $0.root.source.endpoint == child.root.source.endpoint && ($0.root.source.path as NSString).deletingLastPathComponent == child.root.source.path }.map { ($0.root.source.path as NSString).lastPathComponent })
                                        guard try Set(access.children(child.root.source)) == names else { throw RecoverableTransferError.changed(child.root.source.path) }
                                    }
                                }
                                try access.replaceItem(from: entry.root.source, to: entry.root.destination, expected: existing, progress: progress)
                                var copied = transfer.entries!
                                for child in copied.indices where copied[child].belongs(to: entry) {
                                    guard try access.fingerprint(copied[child].root.source) == copied[child].source,
                                          let destination = try access.fingerprint(copied[child].root.destination),
                                          copied[child].source.kind == .directory || destination.hasSameContent(as: copied[child].source) else {
                                        throw RecoverableTransferError.changed(copied[child].root.source.path)
                                    }
                                    copied[child].destination = destination; copied[child].error = nil
                                }
                                transfer.entries = copied
                                entry = copied[index]
                                try save(transfer)
                            }
                        }
                        if entry.destination == nil {
                            if entry.source.kind == .directory { try access.createDirectory(entry.root.destination) }
                            else { try access.copyFile(from: entry.root.source, to: entry.root.destination, progress: progress) }
                        }
                        guard try access.fingerprint(entry.root.source) == entry.source,
                              let target = try access.fingerprint(entry.root.destination),
                              entry.source.kind == .directory || target.hasSameContent(as: entry.source) else {
                            throw RecoverableTransferError.changed(entry.root.source.path)
                        }
                        entry.destination = target
                        transfer.entries![index] = entry
                        try save(transfer)
                    }
                    if transfer.moving, !entry.sourceRemoved, entry.preserveSource != true, entry.source.kind != .directory {
                        try access.checkCancellation()
                        // Recheck immediately before deletion, after the durable copy checkpoint.
                        guard try access.fingerprint(entry.root.source) == entry.source,
                              try access.fingerprint(entry.root.destination) == entry.destination else {
                            throw RecoverableTransferError.changed(entry.root.source.path)
                        }
                        for parent in transfer.entries! where parent.source.kind == .directory && parent.root.source.endpoint == entry.root.source.endpoint && entry.root.source.path.hasPrefix(parent.root.source.path + "/") {
                            let expected = Set(transfer.entries!.filter {
                                $0.root.source.endpoint == parent.root.source.endpoint && ($0.root.source.path as NSString).deletingLastPathComponent == parent.root.source.path
                            }.map { ($0.root.source.path as NSString).lastPathComponent })
                            guard try access.fingerprint(parent.root.source) == parent.source,
                                  Set(try access.children(parent.root.source)).isSubset(of: expected) else { throw RecoverableTransferError.changed(parent.root.source.path) }
                        }
                        try access.remove(entry.root.source, directory: false)
                        entry.sourceRemoved = true
                    }
                }
                entry.error = nil
            } catch let error as CheckpointFailure { throw error.underlying
            } catch {
                try access.checkCancellation()
                entry.error = error.localizedDescription
            }
            transfer.entries![index] = entry
            try save(transfer) // Persistence failures stop the whole worker, never masquerade as a file error.
            let done = transfer.entries!.filter { $0.skipped == true || ($0.destination != nil && $0.error == nil) }.count
            progress(OperationProgress(completedItems: done, totalItems: transfer.entries!.count, currentPath: entry.root.source.path))
        }
        // Apply directory metadata only after its children are present; never make a partial destination read-only.
        for index in transfer.entries!.indices.reversed() where transfer.entries![index].source.kind == .directory {
            let entry = transfer.entries![index]
            guard entry.destination != nil, entry.error == nil, !entry.sourceRemoved, entry.skipped != true, entry.merged != true,
                  !transfer.entries!.contains(where: { $0.root.source.path.hasPrefix(entry.root.source.path + "/") && $0.error != nil }) else { continue }
            do {
                try access.checkCancellation()
                guard try access.fingerprint(entry.root.source) == entry.source else { throw RecoverableTransferError.changed(entry.root.source.path) }
                try access.finishDirectory(from: entry.root.source, to: entry.root.destination)
            } catch { try access.checkCancellation(); transfer.entries![index].error = error.localizedDescription }
            try save(transfer)
        }
        if transfer.moving {
            for index in transfer.entries!.indices.reversed() where transfer.entries![index].source.kind == .directory {
                try access.checkCancellation()
                var entry = transfer.entries![index]
                guard entry.destination != nil, entry.error == nil, !entry.sourceRemoved, entry.skipped != true, entry.preserveSource != true,
                      !transfer.entries!.contains(where: { $0.belongs(to: entry) && ($0.skipped == true || $0.preserveSource == true) }) else { continue }
                do {
                    guard try access.fingerprint(entry.root.source) == entry.source,
                          try access.children(entry.root.source).isEmpty else { throw RecoverableTransferError.changed(entry.root.source.path) }
                    try access.remove(entry.root.source, directory: true)
                    entry.sourceRemoved = true
                } catch { try access.checkCancellation(); entry.error = error.localizedDescription }
                transfer.entries![index] = entry
                try save(transfer)
            }
        }
        let failures = transfer.entries!.filter { $0.error != nil }.count
        if failures > 0 { throw RecoverableTransferError.incomplete(failures) }
    }
}

public extension RecoverableTransfer {
    func validate() throws {
        guard version == 1, !roots.isEmpty, roots.count <= 100_000, (entries?.count ?? 0) <= 100_000 else { throw RecoverableTransferError.invalidPlan }
        func valid(_ path: TransferPath) -> Bool {
            guard ["file", "ftp", "sftp", "shell", "nextcloud"].contains(path.endpoint.scheme), path.path.hasPrefix("/"), !path.path.contains("\0") else { return false }
            let normalized = (path.path as NSString).standardizingPath
            return normalized == path.path && (path.endpoint.scheme == "file" || !path.path.contains(where: \.isNewline))
        }
        var destinations = Set<TransferPath>()
        for root in roots {
            guard valid(root.source), valid(root.destination), root.source.path != "/", root.destination.path != "/" else { throw RecoverableTransferError.invalidPlan }
            if root.source.endpoint == root.destination.endpoint {
                guard (allowsConflicts == true || root.source.path != root.destination.path), !root.destination.path.hasPrefix(root.source.path + "/") else { throw RecoverableTransferError.invalidPlan }
            }
            if moving {
                guard !roots.contains(where: { $0.source.endpoint == root.source.endpoint && root.source.path.hasPrefix($0.source.path + "/") }) else { throw RecoverableTransferError.invalidPlan }
            }
        }
        if let entries {
            guard !entries.isEmpty, anchors != nil, roots.allSatisfy({ root in entries.contains { $0.root.source == root.source && ($0.originalDestination ?? $0.root.destination) == root.destination } }) else { throw RecoverableTransferError.invalidPlan }
        }
        let renamedEntries = (entries ?? []).filter { $0.renamed == true }
        for entry in entries ?? [] {
            let original = entry.originalDestination ?? entry.root.destination
            guard valid(entry.root.source), valid(entry.root.destination), valid(original), original.endpoint == entry.root.destination.endpoint,
                  entry.source.kind == .directory || entry.source.digest != nil,
                  destinations.insert(entry.root.destination).inserted,
                  roots.contains(where: { root in
                      guard root.source.endpoint == entry.root.source.endpoint, root.destination.endpoint == entry.root.destination.endpoint else { return false }
                      if root.source.path == entry.root.source.path { return root.destination == original }
                      guard entry.root.source.path.hasPrefix(root.source.path + "/") else { return false }
                      return original.path == root.destination.path + entry.root.source.path.dropFirst(root.source.path.count)
                  }) else { throw RecoverableTransferError.invalidPlan }
            let ancestor = renamedEntries.filter {
                $0.root.source.endpoint == entry.root.source.endpoint
                    && entry.root.source.path.hasPrefix($0.root.source.path + "/")
                    && ($0.originalDestination ?? $0.root.destination).endpoint == original.endpoint
                    && original.path.hasPrefix(($0.originalDestination ?? $0.root.destination).path + "/")
            }.max { $0.root.source.path.count < $1.root.source.path.count }
            let mapped = ancestor.map { TransferPath($0.root.destination.path + entry.root.source.path.dropFirst($0.root.source.path.count), endpoint: original.endpoint) } ?? original
            if entry.renamed == true {
                guard allowsConflicts == true, (mapped.path as NSString).deletingLastPathComponent == (entry.root.destination.path as NSString).deletingLastPathComponent else { throw RecoverableTransferError.invalidPlan }
            } else {
                guard entry.root.destination == mapped else { throw RecoverableTransferError.invalidPlan }
            }
        }
    }
}

private extension RecoverableTransfer.Entry {
    func belongs(to parent: Self) -> Bool {
        root.source.endpoint == parent.root.source.endpoint && root.destination.endpoint == parent.root.destination.endpoint
            && (root.source == parent.root.source || root.source.path.hasPrefix(parent.root.source.path + "/"))
            && ((originalDestination ?? root.destination).path == (parent.originalDestination ?? parent.root.destination).path
                || (originalDestination ?? root.destination).path.hasPrefix((parent.originalDestination ?? parent.root.destination).path + "/"))
    }
}
