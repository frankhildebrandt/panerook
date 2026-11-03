import Foundation
import Darwin

public enum TransferConflictAction: String, CaseIterable, Sendable {
    case skip, keepBoth, replace, merge
}

public struct TransferEntryInfo: Sendable {
    public enum Kind: String, Sendable { case file, directory, symbolicLink, other }
    public let kind: Kind
    public let size: Int64
    public let modified: Date?

    public static func read(_ url: URL) throws -> TransferEntryInfo? {
        if ArchiveFileSystem.memberLocation(url) != nil {
            return try ArchiveFileSystem.entry(url).map {
                TransferEntryInfo(kind: $0.isSymbolicLink ? .symbolicLink : ($0.isDirectory ? .directory : .file),
                                  size: $0.size, modified: $0.modified)
            }
        }
        guard let stamp = try TransferStamp.read(url) else { return nil }
        return TransferEntryInfo(kind: stamp.kind, size: stamp.size,
                                 modified: Date(timeIntervalSince1970: Double(stamp.seconds) + Double(stamp.nanoseconds) / 1e9))
    }
}

public struct TransferConflict: Sendable {
    public let source: URL
    public let destination: URL
    public let sourceInfo: TransferEntryInfo
    public let destinationInfo: TransferEntryInfo
    public let allowedActions: [TransferConflictAction]

    public init(source: URL, destination: URL) throws {
        self.source = source; self.destination = destination
        guard let sourceInfo = try TransferEntryInfo.read(source),
              let destinationInfo = try TransferEntryInfo.read(destination) else { throw FileActionError.transferChanged }
        self.sourceInfo = sourceInfo; self.destinationInfo = destinationInfo
        var actions: [TransferConflictAction] = [.skip, .keepBoth]
        let archive = ArchiveFileSystem.memberLocation(source) != nil || ArchiveFileSystem.memberLocation(destination) != nil
        let sourceStamp = try TransferStamp.read(source)
        let destinationStamp = try TransferStamp.read(destination)
        let same = source.standardizedFileURL == destination.standardizedFileURL ||
            (sourceStamp != nil && sourceStamp?.identity == destinationStamp?.identity)
        // An ancestor cannot be replaced by one of its own descendants.
        let sourcePath = source.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(source.lastPathComponent).path
        let targetPath = destination.resolvingSymlinksInPath().path
        if !archive && !same && !sourcePath.hasPrefix(targetPath + "/") {
            actions.append(.replace)
            if sourceInfo.kind == .directory && destinationInfo.kind == .directory { actions.append(.merge) }
        }
        allowedActions = actions
    }
}

/// Rules are scoped to one job. An inapplicable rule always requires a new decision.
public struct TransferConflictRules: Sendable {
    public var action: TransferConflictAction?
    public init(action: TransferConflictAction? = nil) { self.action = action }
    public func decision(for allowed: [TransferConflictAction]) -> TransferConflictAction? {
        action.flatMap { allowed.contains($0) ? $0 : nil }
    }
}

public enum TransferNaming {
    /// Preserves the extension and never relies on a precomputed free name at commit time.
    public static func candidate(_ name: String, number: Int) -> String {
        let value = name as NSString
        let ext = value.pathExtension
        let stem = ext.isEmpty ? name : value.deletingPathExtension
        return stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
    }
    static func available(_ url: URL, reserving reserved: Set<URL> = []) throws -> URL {
        var number = 2
        var candidate = url
        while try TransferEntryInfo.read(candidate) != nil || reserved.contains(candidate.standardizedFileURL) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(Self.candidate(url.lastPathComponent, number: number))
            number += 1
        }
        return candidate
    }
}

/// lstat detects dangling links and includes nanosecond metadata and inode identity.
struct TransferStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let seconds: Int
    let nanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    var identity: String { "\(device):\(inode)" }
    var kind: TransferEntryInfo.Kind {
        switch mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }
    static func read(_ url: URL) throws -> Self? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return Self(device: value.st_dev, inode: value.st_ino, mode: value.st_mode, size: value.st_size,
                    seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec,
                    changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
    }
    static func sameDisplacedTree(_ actual: [String: Self], _ expected: [String: Self]) -> Bool {
        guard Set(actual.keys) == Set(expected.keys) else { return false }
        return actual.allSatisfy { path, stamp in
            guard let other = expected[path] else { return false }
            // rename changes ctime of the exchanged root itself.
            if path.isEmpty {
                return stamp.identity == other.identity && stamp.mode == other.mode && stamp.size == other.size
                    && stamp.seconds == other.seconds && stamp.nanoseconds == other.nanoseconds
            }
            return stamp == other
        }
    }
    static func cleanup(_ url: URL) {
        // Only called for our private staging tree. Do not follow copied links.
        if let stamp = try? read(url), stamp.kind == .directory {
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                cleanup(child)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
    static func tree(_ url: URL, cancellation: TransferCancellation) throws -> [String: Self] {
        var result: [String: Self] = [:]
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try cancellation.check()
            guard depth < 256, let stamp = try read(url) else { throw FileActionError.transferChanged }
            result[relative] = stamp
            if stamp.kind == .directory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
        }
        try visit(url, relative: "", depth: 0)
        return result
    }
}
