import Foundation
import Darwin

public enum FileMetadataError: LocalizedError {
    case localFilesOnly, notRegularFile(String), notSymbolicLink(String)
    case invalidIdentity(String), invalidLinkTarget, changedDuringUpdate(String)

    public var errorDescription: String? {
        switch self {
        case .localFilesOnly: return "Diese Aktion benötigt eine lokale Datei."
        case .notRegularFile(let name): return "Ein harter Link benötigt eine reguläre Datei: \(name)"
        case .notSymbolicLink(let name): return "Kein symbolischer Link: \(name)"
        case .invalidIdentity(let name): return "Unbekannter Benutzer oder unbekannte Gruppe: \(name)"
        case .invalidLinkTarget: return "Bitte ein Linkziel ohne Nullzeichen eingeben."
        case .changedDuringUpdate(let path): return "Der Eintrag wurde während der Änderung ausgetauscht. Der ursprüngliche Eintrag liegt unter \(path)."
        }
    }
}

/// Local POSIX metadata. None of these operations follows a selected symbolic link.
public enum FileMetadata {
    public struct Snapshot: Sendable {
        public let url: URL
        public let permissions: UInt16
        public let ownerID: UInt32
        public let groupID: UInt32
        public let isSymbolicLink: Bool
        public let isDirectory: Bool
        public let isRegularFile: Bool
        public var owner: String { FileMetadata.ownerName(ownerID) ?? String(ownerID) }
        public var group: String { FileMetadata.groupName(groupID) ?? String(groupID) }
    }

    public static func inspect(_ url: URL) throws -> Snapshot {
        let item = try metadata(url)
        let kind = item.st_mode & S_IFMT
        return Snapshot(url: url, permissions: UInt16(item.st_mode & 0o7777),
            ownerID: item.st_uid, groupID: item.st_gid, isSymbolicLink: kind == S_IFLNK,
            isDirectory: kind == S_IFDIR, isRegularFile: kind == S_IFREG)
    }

    /// `mask` lets mixed selections retain every checkbox left in its mixed state.
    public static func changePermissions(of urls: [URL], values: UInt16, mask: UInt16 = 0o7777) throws {
        let snapshots = try urls.map(inspect)
        for snapshot in snapshots {
            let effectiveMask = mask & 0o7777
            let mode = (snapshot.permissions & ~effectiveMask) | (values & effectiveMask)
            guard lchmod(snapshot.url.path, mode_t(mode)) == 0 else { throw posix(snapshot.url) }
        }
    }

    /// Empty fields mean unchanged. Names and numeric IDs are both accepted.
    public static func changeOwnership(of urls: [URL], owner: String?, group: String?,
                                       permissionValues: UInt16? = nil, permissionMask: UInt16 = 0o7777) throws {
        let uid = try owner.flatMap { try ownerID($0) }
        let gid = try group.flatMap { try groupID($0) }
        _ = try urls.map(inspect)
        for url in urls {
            if uid != nil || gid != nil {
                guard lchown(url.path, uid ?? uid_t.max, gid ?? gid_t.max) == 0 else { throw posix(url) }
            }
            if let permissionValues {
                try changePermissions(of: [url], values: permissionValues, mask: permissionMask)
            }
        }
    }

    public static func createHardLink(to source: URL, at destination: URL) throws {
        try validateLocal(destination)
        guard try inspect(source).isRegularFile else { throw FileMetadataError.notRegularFile(source.lastPathComponent) }
        guard link(source.path, destination.path) == 0 else { throw posix(destination) }
    }

    public static func createSymbolicLink(to source: URL, at destination: URL, relative: Bool) throws {
        try validateLocal(source)
        let target = relative ? relativePath(to: source, from: destination.deletingLastPathComponent()) : source.path
        try createSymbolicLink(target: target, at: destination)
    }

    /// The literal target can point to a missing file, just as in MC and ln -s.
    public static func createSymbolicLink(target: String, at destination: URL) throws {
        try validateLocal(destination)
        try validateTarget(target)
        guard symlink(target, destination.path) == 0 else { throw posix(destination) }
    }

    public static func symbolicLinkTarget(at url: URL) throws -> String {
        guard try inspect(url).isSymbolicLink else { throw FileMetadataError.notSymbolicLink(url.lastPathComponent) }
        return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    /// Exchange two directory entries atomically; never unlink the selected entry first.
    public static func editSymbolicLink(at url: URL, target: String) throws {
        try validateLocal(url)
        try validateTarget(target)
        let parent = url.deletingLastPathComponent()
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY)
        guard parentFD >= 0 else { throw posix(parent) }
        defer { close(parentFD) }
        var original = stat()
        guard fstatat(parentFD, url.lastPathComponent, &original, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(url) }
        guard original.st_mode & S_IFMT == S_IFLNK else { throw FileMetadataError.notSymbolicLink(url.lastPathComponent) }
        let temporaryName = ".panerook-link-\(UUID().uuidString)"
        let temporaryURL = parent.appendingPathComponent(temporaryName)
        guard symlinkat(target, parentFD, temporaryName) == 0 else { throw posix(temporaryURL) }
        var preserveTemporary = false
        defer { if !preserveTemporary { unlinkat(parentFD, temporaryName, 0) } }
        var current = stat()
        guard fstatat(parentFD, url.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(url) }
        guard current.st_dev == original.st_dev, current.st_ino == original.st_ino else {
            throw FileMetadataError.notSymbolicLink(url.lastPathComponent)
        }
        guard renameatx_np(parentFD, temporaryName, parentFD, url.lastPathComponent, UInt32(RENAME_SWAP)) == 0 else {
            throw posix(url)
        }
        var exchanged = stat()
        if fstatat(parentFD, temporaryName, &exchanged, AT_SYMLINK_NOFOLLOW) != 0
            || exchanged.st_dev != original.st_dev || exchanged.st_ino != original.st_ino {
            // A concurrent replacement is preserved, even if it was an ordinary file.
            preserveTemporary = true
            throw FileMetadataError.changedDuringUpdate(temporaryURL.path)
        }
    }

    public static func relativePath(to target: URL, from directory: URL) -> String {
        // Resolve the existing parents, but retain the target's final component:
        // selecting a symbolic link should link to that entry, not bypass it.
        let normalizedTarget = target.standardizedFileURL
        let targetParts = normalizedTarget.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(normalizedTarget.lastPathComponent).standardizedFileURL.pathComponents
        let baseParts = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < min(targetParts.count, baseParts.count), targetParts[common] == baseParts[common] { common += 1 }
        let parts = Array(repeating: "..", count: baseParts.count - common) + Array(targetParts.dropFirst(common))
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private static func metadata(_ url: URL) throws -> stat {
        try validateLocal(url)
        var item = stat()
        guard lstat(url.path, &item) == 0 else { throw posix(url) }
        return item
    }
    private static func validateLocal(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0") else { throw FileMetadataError.localFilesOnly }
    }
    private static func validateTarget(_ target: String) throws {
        guard !target.isEmpty, !target.contains("\0") else { throw FileMetadataError.invalidLinkTarget }
    }
    private static func posix(_ url: URL) -> Error {
        let code = errno
        if code == EEXIST { return FileActionError.collision(url.lastPathComponent) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func ownerID(_ name: String) throws -> uid_t? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if let numeric = UInt32(value), numeric != UInt32.max { return numeric }
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            getpwnam_r(value, &record, bytes.baseAddress!, bytes.count, &result)
        }
        guard status == 0, result != nil else { throw FileMetadataError.invalidIdentity(value) }
        return record.pw_uid
    }
    private static func groupID(_ name: String) throws -> gid_t? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if let numeric = UInt32(value), numeric != UInt32.max { return numeric }
        var record = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let status = buffer.withUnsafeMutableBufferPointer { bytes in
            getgrnam_r(value, &record, bytes.baseAddress!, bytes.count, &result)
        }
        guard status == 0, result != nil else { throw FileMetadataError.invalidIdentity(value) }
        return record.gr_gid
    }
    private static func ownerName(_ id: uid_t) -> String? {
        var record = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(id, &record, bytes.baseAddress!, bytes.count, &result) == 0,
                  result != nil, let name = record.pw_name else { return nil }
            return String(cString: name)
        }
    }
    private static func groupName(_ id: gid_t) -> String? {
        var record = group()
        var result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        return buffer.withUnsafeMutableBufferPointer { bytes in
            guard getgrgid_r(id, &record, bytes.baseAddress!, bytes.count, &result) == 0,
                  result != nil, let name = record.gr_name else { return nil }
            return String(cString: name)
        }
    }
}
