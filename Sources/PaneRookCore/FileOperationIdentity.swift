import Foundation
import CryptoKit
import Darwin

/// A path alone is never authority to restore or remove an item. Links are not followed.
struct FileOperationIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino
        birthSeconds = value.st_birthtimespec.tv_sec; birthNanoseconds = value.st_birthtimespec.tv_nsec
    }

    static func read(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw FileJournalError.conflict(url, "Nicht erreichbar (Volume getrennt, Eintrag entfernt oder Zugriff verweigert).")
        }
        return value
    }
}

struct FileOperationSnapshot: Equatable {
    struct Node: Equatable {
        let path: String
        let identity: FileOperationIdentity
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let flags: UInt32
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let digest: Data
    }
    let nodes: [Node]

    static func capture(_ url: URL, cancellation: TransferCancellation) throws -> Self {
        for attempt in 0..<3 {
            do { return try captureOnce(url, cancellation: cancellation) }
            catch FileJournalError.unstable where attempt < 2 {
                continue
            }
        }
        throw FileJournalError.conflict(url, "Zustand konnte nicht stabil erfasst werden.")
    }

    private static func captureOnce(_ url: URL, cancellation: TransferCancellation) throws -> Self {
        var nodes: [Node] = []
        func visit(_ item: URL, relative: String) throws {
            try cancellation.check()
            guard nodes.count < 100_000 else {
                throw FileJournalError.conflict(url, "Mehr als 100.000 Einträge; sichere Zustandsprüfung nicht möglich.")
            }
            let before = try FileOperationIdentity.read(item)
            let type = before.st_mode & S_IFMT
            var hasher = SHA256()
            if type == S_IFREG {
                let fd = open(item.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw FileJournalError.conflict(item, "Datei kann nicht sicher gelesen werden.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var opened = stat()
                guard fstat(fd, &opened) == 0, FileOperationIdentity(opened) == FileOperationIdentity(before) else {
                    throw FileJournalError.conflict(item, "Datei wurde während der Prüfung ersetzt.")
                }
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try cancellation.check(); hasher.update(data: data)
                }
            } else if type == S_IFLNK {
                hasher.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: item.path).utf8))
            } else if type != S_IFDIR {
                throw FileJournalError.conflict(item, "Für Spezialdateien ist kein sicheres Datei-Undo verfügbar.")
            }
            // Extended attributes include resource forks and Finder information.
            let length = listxattr(item.path, nil, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { throw FileJournalError.conflict(item, "Attribute nicht lesbar.") }
            var names = [CChar](repeating: 0, count: length)
            if length > 0 {
                guard listxattr(item.path, &names, length, XATTR_NOFOLLOW) == length else {
                    throw FileJournalError.conflict(item, "Attribute wurden während der Prüfung verändert.")
                }
                let attributes = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
                for name in attributes {
                    try cancellation.check()
                    let count = getxattr(item.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    guard count >= 0, count <= 16 * 1024 * 1024 else { throw FileJournalError.conflict(item, "Attribut nicht lesbar: \(name)") }
                    var data = Data(count: count)
                    let read = data.withUnsafeMutableBytes { getxattr(item.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
                    guard read == count else { throw FileJournalError.conflict(item, "Attribut verändert: \(name)") }
                    hasher.update(data: Data(name.utf8)); hasher.update(data: Data([0]))
                    var byteCount = UInt64(count).bigEndian
                    hasher.update(data: withUnsafeBytes(of: &byteCount) { Data($0) }); hasher.update(data: data)
                }
            }
            if let acl = acl_get_link_np(item.path, ACL_TYPE_EXTENDED) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var count = 0
                guard let text = acl_to_text(acl, &count) else {
                    throw FileJournalError.conflict(item, "Zugriffsrechte nicht lesbar.")
                }
                defer { acl_free(text) }
                hasher.update(data: Data(bytes: text, count: count))
            } else if errno != ENOENT && errno != ENOTSUP {
                throw FileJournalError.conflict(item, "Zugriffsrechte nicht lesbar.")
            }
            if type == S_IFDIR {
                let children = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                for child in children { try visit(child, relative: relative + "/" + child.lastPathComponent) }
            }
            let after = try FileOperationIdentity.read(item)
            guard FileOperationIdentity(before) == FileOperationIdentity(after),
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw FileJournalError.unstable(item)
            }
            // Directory timestamps change when later journalled children are undone.
            // Identity, attributes and the complete child tree still have to match.
            nodes.append(Node(path: relative, identity: FileOperationIdentity(after), mode: after.st_mode,
                owner: after.st_uid, group: after.st_gid, flags: after.st_flags,
                size: type == S_IFDIR ? 0 : after.st_size,
                modifiedSeconds: type == S_IFDIR ? 0 : after.st_mtimespec.tv_sec,
                modifiedNanoseconds: type == S_IFDIR ? 0 : after.st_mtimespec.tv_nsec,
                digest: Data(hasher.finalize())))
        }
        try visit(url, relative: "")
        return Self(nodes: nodes)
    }
}

/// Pins the resolved parent and its volume identity. A replacement mount/parent is a conflict.
struct FileOperationPath {
    let url: URL
    let parentIdentity: FileOperationIdentity

    init(_ url: URL) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        self.url = parent.appendingPathComponent(url.lastPathComponent)
        let value = try FileOperationIdentity.read(parent)
        guard value.st_mode & S_IFMT == S_IFDIR else { throw FileActionError.invalidDirectory(parent.path) }
        parentIdentity = FileOperationIdentity(value)
    }

    private init(url: URL, parentIdentity: FileOperationIdentity) {
        self.url = url; self.parentIdentity = parentIdentity
    }
    func rebindingParent(_ directory: URL, from old: FileOperationIdentity, to new: FileOperationIdentity) -> Self {
        guard url.deletingLastPathComponent().path == directory.path, parentIdentity == old else { return self }
        return Self(url: url, parentIdentity: new)
    }
    func validateParent() throws {
        let parent = url.deletingLastPathComponent()
        guard try FileOperationIdentity(FileOperationIdentity.read(parent)) == parentIdentity else {
            throw FileJournalError.conflict(parent, "Der Zielordner oder sein Volume wurde ersetzt.")
        }
    }

    func requireAbsent() throws {
        try validateParent()
        var value = stat()
        if lstat(url.path, &value) == 0 { throw FileActionError.collision(url.path) }
        guard errno == ENOENT else { throw FileJournalError.conflict(url, "Ziel kann nicht sicher geprüft werden.") }
    }
}
