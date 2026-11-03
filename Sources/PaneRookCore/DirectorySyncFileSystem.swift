import Foundation
import Darwin
import CryptoKit
import PaneRookTasks

struct SyncSnapshot: Equatable, Sendable {
    enum Kind: Sendable { case file, directory, symlink }
    let type: Kind
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    var digest: Data = Data()
    init(_ value: stat, type: Kind) {
        self.type = type; device = value.st_dev; inode = value.st_ino
        size = type == .file ? value.st_size : 0
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
    func sameIdentity(as other: SyncSnapshot) -> Bool { type == other.type && device == other.device && inode == other.inode }
}

struct SyncInventory: Equatable, Sendable {
    let root: SyncSnapshot
    var items: [String: SyncSnapshot] = [:]
    var problems: [String: String] = [:]
    var excluded = Set<String>()
    let maximumEntries: Int
    let maximumFileBytes: Int64
}

/// All traversal and mutations are relative to open directories, with O_NOFOLLOW
/// on every component. A swapped ancestor can never redirect an operation through a link.
final class SyncRoot {
    let url: URL
    let fd: Int32
    init(_ url: URL) throws {
        self.url = url
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw syncPOSIX(url.path) }
        for part in url.pathComponents.dropFirst() {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current); current = next
            guard current >= 0 else { throw DirectorySyncError.changed(url.path) }
        }
        fd = current
    }
    deinit { close(fd) }
    static func pair(_ left: URL, _ right: URL) throws -> (SyncRoot, SyncRoot) {
        guard left.isFileURL, right.isFileURL, !left.path.contains("\0"), !right.path.contains("\0") else { throw DirectorySyncError.invalidRoots }
        func canonical(_ url: URL) throws -> URL {
            guard let path = realpath(url.path, nil) else { throw syncPOSIX(url.path) }
            defer { free(path) }
            // URL.standardizedFileURL can reintroduce /var's symlink on macOS.
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        let a = try canonical(left), b = try canonical(right)
        guard a.path != b.path, !a.path.hasPrefix(b.path == "/" ? "/" : b.path + "/"),
              !b.path.hasPrefix(a.path == "/" ? "/" : a.path + "/") else { throw DirectorySyncError.invalidRoots }
        let ar = try SyncRoot(a), br = try SyncRoot(b)
        let arIdentity = try ar.rootSnapshot(), brIdentity = try br.rootSnapshot()
        // Identity-based ancestry also covers case/Unicode aliases on insensitive volumes.
        guard !arIdentity.sameIdentity(as: brIdentity),
              try !ar.hasAncestor(brIdentity), try !br.hasAncestor(arIdentity) else { throw DirectorySyncError.invalidRoots }
        return (ar, br)
    }
    private func hasAncestor(_ ancestor: SyncSnapshot) throws -> Bool {
        var current = dup(fd)
        guard current >= 0 else { throw syncPOSIX(url.path) }
        defer { close(current) }
        while true {
            var info = stat()
            guard fstat(current, &info) == 0 else { throw syncPOSIX(url.path) }
            let identity = SyncSnapshot(info, type: .directory)
            if identity.sameIdentity(as: ancestor) { return true }
            let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw syncPOSIX(url.path) }
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0 else { close(parent); throw syncPOSIX(url.path) }
            if identity.sameIdentity(as: SyncSnapshot(parentInfo, type: .directory)) { close(parent); return false }
            close(current); current = parent
        }
    }
    func rootSnapshot() throws -> SyncSnapshot {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw syncPOSIX(url.path) }
        return SyncSnapshot(info, type: .directory)
    }
    func parent(_ path: String, expected: [String: SyncSnapshot]? = nil) throws -> Int32 {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw DirectorySyncError.changed(path)
        }
        var current = dup(fd)
        guard current >= 0 else { throw syncPOSIX(path) }
        var relative = ""
        do {
            for part in parts.dropLast() {
                relative = relative.isEmpty ? part : relative + "/" + part
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DirectorySyncError.changed(relative) }
                close(current); current = next
                if let expected {
                    var info = stat()
                    guard fstat(current, &info) == 0, let known = expected[relative],
                          known.sameIdentity(as: SyncSnapshot(info, type: .directory)) else { throw DirectorySyncError.changed(relative) }
                }
            }
            return current
        } catch { close(current); throw error }
    }
    func snapshot(_ path: String, cancellation: TransferCancellation, maximumFileBytes: Int64) throws -> SyncSnapshot? {
        let parentFD = try parent(path); defer { close(parentFD) }
        return try Self.snapshot(at: parentFD, name: (path as NSString).lastPathComponent,
                                 cancellation: cancellation, maximumFileBytes: maximumFileBytes)
    }
    static func snapshot(at parent: Int32, name: String, cancellation: TransferCancellation,
                         maximumFileBytes: Int64) throws -> SyncSnapshot? {
        try cancellation.check()
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw syncPOSIX(name)
        }
        let mode = info.st_mode & S_IFMT
        let kind: SyncSnapshot.Kind
        switch mode {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: throw InspectionError.notRegularFile(name)
        }
        var result = SyncSnapshot(info, type: kind)
        guard kind == .file else { return result }
        guard result.size <= maximumFileBytes else { throw InspectionError.fileLimit(maximumFileBytes) }
        let input = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw syncPOSIX(name) }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, SyncSnapshot(opened, type: .file) == result else { throw DirectorySyncError.changed(name) }
        var hash = SHA256(); var remaining = result.size
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            try cancellation.check()
            let count = read(input, &buffer, Int(min(Int64(buffer.count), remaining)))
            guard count > 0 else { throw DirectorySyncError.changed(name) }
            hash.update(data: Data(buffer.prefix(count))); remaining -= Int64(count)
        }
        var end = stat()
        guard fstat(input, &end) == 0, SyncSnapshot(end, type: .file) == result else { throw DirectorySyncError.changed(name) }
        result.digest = Data(hash.finalize())
        return result
    }
    func inventory(options: DirectorySyncOptions, cancellation: TransferCancellation, maximumEntries: Int,
                   maximumFileBytes: Int64, progress: (OperationProgress) -> Void) throws -> SyncInventory {
        var result = SyncInventory(root: try rootSnapshot(), maximumEntries: maximumEntries, maximumFileBytes: maximumFileBytes)
        var count = 0
        // Iterative traversal avoids recursion depth failures on deeply nested trees.
        var pending = [""]
        while let path = pending.popLast() {
            try cancellation.check()
            var directoryFD: Int32 = -1
            do {
                directoryFD = path.isEmpty ? dup(fd) : try parent(path + "/placeholder")
                guard directoryFD >= 0 else { throw syncPOSIX(path) }
                var before = stat()
                guard fstat(directoryFD, &before) == 0 else { throw syncPOSIX(path) }
                for name in try Self.names(directoryFD, maximumEntries: max(0, maximumEntries - count)) {
                    try cancellation.check(); count += 1
                    guard count <= maximumEntries else { throw InspectionError.entryLimit(maximumEntries) }
                    let child = path.isEmpty ? name : path + "/" + name
                    progress(OperationProgress(completedItems: count, currentPath: url.appendingPathComponent(child).path))
                    if options.excludes(child) { result.excluded.insert(child); continue }
                    do {
                        guard let snapshot = try Self.snapshot(at: directoryFD, name: name, cancellation: cancellation, maximumFileBytes: maximumFileBytes) else {
                            throw DirectorySyncError.changed(child)
                        }
                        result.items[child] = snapshot
                        if snapshot.type == .directory { pending.append(child) }
                    } catch TransferError.cancelled { throw TransferError.cancelled }
                    catch { result.problems[child] = error.localizedDescription }
                }
                var after = stat()
                guard fstat(directoryFD, &after) == 0,
                      SyncSnapshot(before, type: .directory) == SyncSnapshot(after, type: .directory) else { throw DirectorySyncError.changed(path) }
            } catch TransferError.cancelled { close(directoryFD); throw TransferError.cancelled }
            catch InspectionError.entryLimit { close(directoryFD); throw InspectionError.entryLimit(maximumEntries) }
            catch { result.problems[path] = error.localizedDescription }
            close(directoryFD)
        }
        try cancellation.check()
        return result
    }
    static func names(_ fd: Int32, maximumEntries: Int = 100_000) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw syncPOSIX("") }
        guard let directory = fdopendir(copy) else { close(copy); throw syncPOSIX("") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw InspectionError.notRegularFile("Dateiname ist kein gültiges UTF-8") }
            if name != ".", name != ".." {
                result.append(name)
                guard result.count <= maximumEntries else { throw InspectionError.entryLimit(maximumEntries) }
            }
            errno = 0
        }
        guard errno == 0 else { throw syncPOSIX("") }
        return result.sorted()
    }
}

func syncPOSIX(_ path: String) -> Error {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path])
}
