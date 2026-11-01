import PaneRookTasks
import Foundation
import Darwin
import CArchive

public struct ArchiveLocation: Sendable {
    public let archiveURL: URL
    public let memberPath: String
}

public enum ArchiveError: LocalizedError {
    case invalid(String), unsafePath(String), unsupportedEntry(String), changed, limit
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return "Archiv konnte nicht gelesen oder geschrieben werden: \(detail)"
        case .unsafePath(let path): return "Unsicherer oder mehrdeutiger Archivpfad: \(path)"
        case .unsupportedEntry(let path): return "Links, Spezialdateien und verschlüsselte Einträge werden bei dieser Archivaktion nicht unterstützt: \(path)"
        case .changed: return "Das Archiv wurde inzwischen geändert. Bitte neu einlesen und erneut versuchen."
        case .limit: return "Archivgrenze erreicht (100.000 Einträge, 16 GiB je Datei oder 64 GiB je Aktion)."
        }
    }
}

/// Archive URLs use the archive's ordinary path followed by member components.
/// Listing only reads headers. Export reads selected members; changes stream into
/// a sibling archive and replace the original only after a successful close.
public enum ArchiveFileSystem {
    private static let operationLock = NSRecursiveLock()
    private static let maxEntries = 100_000
    private static let maxFileSize: Int64 = 16 * 1024 * 1024 * 1024
    private static let maxBytes: Int64 = 64 * 1024 * 1024 * 1024

    public static func location(for url: URL) -> ArchiveLocation? {
        guard url.isFileURL else { return nil }
        let normalized = url.standardizedFileURL
        var candidate = normalized
        while candidate.path != "/" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path) {
                // The first real filesystem item is the boundary: never treat a
                // real directory named *.zip, or a symlink, as an archive.
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      format(candidate) != nil else { return nil }
                let suffix = String(normalized.path.dropFirst(candidate.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return ArchiveLocation(archiveURL: candidate, memberPath: suffix)
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    public static func list(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        try synchronized {
            guard let location = location(for: directory) else { throw FileActionError.invalidDirectory(directory.path) }
            let members = try catalog(location.archiveURL)
            guard location.memberPath.isEmpty || members[location.memberPath]?.kind == .directory else {
                throw FileActionError.invalidDirectory(directory.path)
            }
            let prefix = location.memberPath.isEmpty ? "" : location.memberPath + "/"
            return members.values.filter {
                $0.path.hasPrefix(prefix) && !$0.path.dropFirst(prefix.count).contains("/")
                    && $0.path != location.memberPath && (showHidden || !$0.name.hasPrefix("."))
            }.map { $0.entry(in: location.archiveURL) }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public static func extract(_ sources: [URL], to directory: URL,
        cancellation: TransferCancellation = .init(), progress: @escaping (OperationProgress) -> Void = { _ in }) throws -> [URL] {
        let operation = Operation(cancellation: cancellation, progress: progress)
        return try synchronized {
            try cancellation.check()
            let base = try FileSystem.directory(from: directory.path, relativeTo: directory)
            guard location(for: base) == nil else { throw FileActionError.invalidDirectory(base.path) }
            let outputs = sources.map { base.appendingPathComponent($0.lastPathComponent) }
            guard Set(outputs.map(\.path)).count == outputs.count else { throw FileActionError.duplicateName }
            for output in outputs { try requireAbsent(output) }
            for (source, output) in zip(sources, outputs) { try extractMember(source, to: output, operation: operation) }
            operation.finish(items: sources.count)
            return outputs
        }
    }

    public static func remove(_ urls: [URL], cancellation: TransferCancellation = .init(),
                              progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        let operation = Operation(cancellation: cancellation, progress: progress)
        try synchronized {
            try cancellation.check()
            guard let first = urls.first, let location = memberLocation(first) else { throw FileActionError.invalidName }
            let paths = try urls.map { url -> String in
                guard let item = memberLocation(url), sameArchive(item.archiveURL, location.archiveURL) else {
                    throw ArchiveError.invalid("Eine Aktion muss innerhalb eines Archivs bleiben.")
                }
                return item.memberPath
            }
            let expected = try Stamp(location.archiveURL)
            let members = try catalog(location.archiveURL, operation: operation)
            for path in paths { guard members[path] != nil else { throw CocoaError(.fileNoSuchFile) } }
            try rewrite(location.archiveURL, additions: [], removing: paths, expected: expected, operation: operation)
            operation.finish(items: urls.count)
        }
    }

    @discardableResult static func createDirectory(named name: String, in directory: URL,
        cancellation: TransferCancellation = .init(), progress: @escaping (OperationProgress) -> Void = { _ in }) throws -> URL {
        let operation = Operation(cancellation: cancellation, progress: progress)
        return try synchronized {
            try cancellation.check()
            guard let location = location(for: directory) else { throw FileActionError.invalidDirectory(directory.path) }
            let members = try catalog(location.archiveURL, operation: operation)
            guard location.memberPath.isEmpty || members[location.memberPath]?.kind == .directory else {
                throw FileActionError.invalidDirectory(directory.path)
            }
            let path = location.memberPath.isEmpty ? name : location.memberPath + "/" + name
            guard members[path] == nil else { throw FileActionError.collision(name) }
            try rewrite(location.archiveURL, additions: [Addition(source: nil, path: path)], removing: [], operation: operation)
            operation.finish(items: 1)
            return directory.appendingPathComponent(name, isDirectory: true)
        }
    }

    static func isDirectory(_ url: URL) throws -> Bool {
        guard let location = location(for: url) else { return false }
        let members = try catalog(location.archiveURL)
        return location.memberPath.isEmpty || members[location.memberPath]?.kind == .directory
    }

    static func entry(_ url: URL) throws -> FileEntry? {
        guard let location = memberLocation(url) else { return nil }
        return try catalog(location.archiveURL)[location.memberPath]?.entry(in: location.archiveURL)
    }

    static func memberLocation(_ url: URL) -> ArchiveLocation? {
        guard let location = location(for: url), !location.memberPath.isEmpty else { return nil }
        return location
    }

    /// Revalidates a plan immediately before execution, stages only its selected
    /// sources, commits the destination, and then removes move sources.
    static func transfer(_ items: [TransferPlan.Item], kind: TransferKind, cancellation: TransferCancellation,
                         progress: @escaping (OperationProgress) -> Void) throws {
        let operation = Operation(cancellation: cancellation, progress: progress)
        try synchronized {
            try cancellation.check()
            for item in items {
                try cancellation.check()
                try validateBackingSource(item.source, destination: item.destination)
                try requireAbsent(item.destination)
            }
            let targetArchive = items.first.flatMap { memberLocation($0.destination)?.archiveURL }
            var archiveStamps: [URL: Stamp] = [:]
            var localStamps: [URL: [String: Stamp]] = [:]
            for item in items {
                try cancellation.check()
                if let source = memberLocation(item.source) {
                    archiveStamps[source.archiveURL] = try Stamp(source.archiveURL)
                } else {
                    if kind == .move, let targetArchive {
                        let sourcePath = item.source.resolvingSymlinksInPath().standardizedFileURL.path
                        let targetPath = targetArchive.resolvingSymlinksInPath().standardizedFileURL.path
                        let sourceStamp = try Stamp(item.source, regularOnly: false)
                        let targetStamp = try Stamp(targetArchive)
                        guard sourcePath != targetPath, !targetPath.hasPrefix(sourcePath + "/"),
                              sourceStamp.device != targetStamp.device || sourceStamp.inode != targetStamp.inode else {
                            throw FileActionError.recursiveDestination
                        }
                    }
                    localStamps[item.source] = try localTreeStamp(item.source, operation: operation)
                }
            }
            func verifySources(ignoring archive: URL? = nil, cancellable: Bool = true) throws {
                for (url, stamp) in archiveStamps {
                    if let archive, sameArchive(url, archive) { continue }
                    guard try Stamp(url) == stamp else { throw ArchiveError.changed }
                }
                for (url, stamp) in localStamps {
                    guard try localTreeStamp(url, operation: cancellable ? operation : nil) == stamp else { throw ArchiveError.changed }
                }
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-archive-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer {
                makeTemporaryTreeRemovable(temporary)
                try? FileManager.default.removeItem(at: temporary)
            }
            var staged: [URL] = []
            for (index, item) in items.enumerated() {
                try operation.report(path: item.source.path)
                let output = temporary.appendingPathComponent(String(index))
                if memberLocation(item.source) != nil { try extractMember(item.source, to: output, operation: operation) }
                else {
                    try validateLocalTree(item.source, operation: operation)
                    try TransferPlan(sources: [item.source], sourcePattern: "*", destinationPath: output.path,
                                     relativeTo: temporary, kind: .copy).execute(cancellation: cancellation) { value in
                        progress(OperationProgress(currentPath: value.currentPath, currentFileBytes: value.currentFileBytes,
                                                   currentFileTotalBytes: value.currentFileTotalBytes))
                    }
                }
                staged.append(output)
            }
            try verifySources()
            if let targetArchive {
                let additions = try zip(items, staged).map { item, source -> Addition in
                    guard let target = memberLocation(item.destination), sameArchive(target.archiveURL, targetArchive) else {
                        throw ArchiveError.invalid("Mehrere Zielarchive in einer Aktion werden nicht unterstützt.")
                    }
                    return Addition(source: source, path: target.memberPath)
                }
                let removing = kind == .move ? items.compactMap { item -> String? in
                    guard let source = memberLocation(item.source), sameArchive(source.archiveURL, targetArchive) else { return nil }
                    return source.memberPath
                } : []
                try rewrite(targetArchive, additions: additions, removing: removing, validateBeforeCommit: { try verifySources() }, operation: operation)
            } else {
                for (item, source) in zip(items, staged) {
                    try cancellation.check()
                    try requireAbsent(item.destination)
                    // The staging directory may live on a different volume.
                    // Reuse the native worker's cancellable, exclusive commit.
                    try TransferPlan(sources: [source], sourcePattern: "*", destinationPath: item.destination.path,
                                     relativeTo: temporary, kind: .move).execute(cancellation: cancellation) { value in
                        let path = value.currentPath.map { path in
                            path.hasPrefix(source.path) ? item.source.path + String(path.dropFirst(source.path.count)) : path
                        }
                        progress(OperationProgress(currentPath: path, currentFileBytes: value.currentFileBytes,
                                                   currentFileTotalBytes: value.currentFileTotalBytes))
                    }
                }
            }
            if kind == .move {
                // Destination commit + source cleanup is one move step. Do not
                // turn cancellation into a duplicate move after commit.
                try verifySources(ignoring: targetArchive, cancellable: false)
                var archiveSources: [String: [URL]] = [:]
                for item in items {
                    if let source = memberLocation(item.source) {
                        if let targetArchive, sameArchive(source.archiveURL, targetArchive) { continue }
                        archiveSources[source.archiveURL.path, default: []].append(item.source)
                    } else {
                        guard let expected = localStamps[item.source], try localTreeStamp(item.source) == expected else { throw ArchiveError.changed }
                        try FileManager.default.removeItem(at: item.source)
                    }
                }
                for urls in archiveSources.values {
                    guard let first = urls.first, let source = memberLocation(first), let expected = archiveStamps[source.archiveURL] else { throw ArchiveError.changed }
                    let paths = try urls.map { url -> String in
                        guard let member = memberLocation(url) else { throw ArchiveError.changed }
                        return member.memberPath
                    }
                    try rewrite(source.archiveURL, additions: [], removing: paths, expected: expected)
                }
            }
            operation.finish(items: items.count)
        }
    }

    private enum Format { case zip, tar, gzip }
    private enum Kind { case regular, directory, link, special }
    private struct Member {
        let path: String
        let kind: Kind
        let size: Int64
        let modified: Date?
        let explicit: Bool
        let permissions: mode_t
        var name: String { (path as NSString).lastPathComponent }
        func entry(in archive: URL) -> FileEntry {
            FileEntry(url: archive.appendingPathComponent(path, isDirectory: kind == .directory), name: name,
                      isDirectory: kind == .directory, isSymbolicLink: kind == .link,
                      size: size, modified: modified, isParent: false)
        }
    }
    private struct Addition { let source: URL?; let path: String }
    private struct Stamp: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int
        let nanos: Int
        let mode: mode_t
        init(_ url: URL, regularOnly: Bool = true) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw posixError() }
            guard !regularOnly || info.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.changed }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec; mode = info.st_mode
        }
    }

    /// Archive work has several streaming passes, so its overall size is not
    /// known in advance. Report measured per-file bytes without a fake percent.
    private final class Operation {
        let cancellation: TransferCancellation
        let progress: (OperationProgress) -> Void
        init(cancellation: TransferCancellation, progress: @escaping (OperationProgress) -> Void) {
            self.cancellation = cancellation; self.progress = progress
        }
        func report(path: String, bytes: Int64 = 0, total: Int64? = nil) throws {
            try cancellation.check()
            progress(OperationProgress(currentPath: path, currentFileBytes: bytes, currentFileTotalBytes: total))
            try cancellation.check()
        }
        func finish(items: Int) {
            progress(OperationProgress(completedItems: items, totalItems: items))
        }
    }

    private final class Reader {
        let handle: OpaquePointer
        let operation: Operation?
        private let url: URL
        private(set) var currentPath: String
        init(_ url: URL, operation: Operation? = nil) throws {
            self.url = url; self.currentPath = url.path; self.operation = operation
            try operation?.cancellation.check()
            guard let handle = archive_read_new() else { throw ArchiveError.invalid("Nicht genug Speicher.") }
            self.handle = handle
            archive_read_support_filter_none(handle); archive_read_support_filter_gzip(handle)
            archive_read_support_format_tar(handle); archive_read_support_format_zip(handle)
            guard archive_read_open_filename(handle, url.path, 64 * 1024) == 0 else {
                throw failure(handle)
            }
        }
        deinit { archive_read_free(handle) }
        func next() throws -> OpaquePointer? {
            try operation?.cancellation.check()
            var entry: OpaquePointer?
            let status = archive_read_next_header(handle, &entry)
            if status == 1 { return nil }
            guard status == 0, let entry else { throw failure(handle) }
            if let path = archive_entry_pathname(entry) { currentPath = url.path + "/" + String(cString: path) }
            return entry
        }
        func skip() throws {
            guard let operation, archive_filter_code(handle, 0) == 1 else {
                try operation?.cancellation.check()
                guard archive_read_data_skip(handle) == 0 else { throw failure(handle) }
                return
            }
            // libarchive's single skip call may decompress a very large TAR
            // member. Read in bounded chunks to keep cancellation responsive.
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try operation.cancellation.check()
                let count = archive_read_data(handle, &buffer, buffer.count)
                guard count >= 0 else { throw failure(handle) }
                if count == 0 { return }
            }
        }
    }
    private final class Writer {
        let handle: OpaquePointer
        private var closed = false
        init(fd: Int32, format: Format) throws {
            guard let handle = archive_write_new() else { throw ArchiveError.invalid("Nicht genug Speicher.") }
            self.handle = handle
            let status = format == .zip ? archive_write_set_format_zip(handle) : archive_write_set_format_pax_restricted(handle)
            guard status == 0, (format != .gzip || archive_write_add_filter_gzip(handle) == 0), archive_write_open_fd(handle, fd) == 0 else {
                throw failure(handle)
            }
        }
        deinit { archive_write_free(handle) }
        func finish() throws {
            guard !closed else { return }; closed = true
            guard archive_write_close(handle) == 0 else { throw failure(handle) }
        }
    }

    private static func format(_ url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .gzip }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }
    private static func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        operationLock.lock(); defer { operationLock.unlock() }; return try work()
    }
    private static func failure(_ handle: OpaquePointer) -> ArchiveError {
        ArchiveError.invalid(archive_error_string(handle).map { String(cString: $0) } ?? "Unbekannter Formatfehler.")
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private static func sameArchive(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }
    private static func normalized(_ value: String) throws -> String {
        guard !value.hasPrefix("/"), !value.contains("\\"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ArchiveError.unsafePath(value)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains("..") else { throw ArchiveError.unsafePath(value) }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }
    private static func member(_ entry: OpaquePointer) throws -> Member? {
        guard let name = archive_entry_pathname(entry), let decoded = String(validatingUTF8: name) else {
            throw ArchiveError.unsafePath("Ungültige Zeichenkodierung")
        }
        let path = try normalized(decoded)
        let type = archive_entry_filetype(entry)
        let kind: Kind
        if archive_entry_symlink(entry) != nil || archive_entry_hardlink(entry) != nil { kind = .link }
        else if type == UInt32(S_IFDIR) { kind = .directory }
        else if type == UInt32(S_IFREG) { kind = .regular }
        else { kind = .special }
        if path.isEmpty {
            guard kind == .directory else { throw ArchiveError.unsafePath(decoded) }
            return nil
        }
        return Member(path: path, kind: kind, size: max(0, archive_entry_size(entry)),
                      modified: Date(timeIntervalSince1970: Double(archive_entry_mtime(entry)) + Double(archive_entry_mtime_nsec(entry)) / 1_000_000_000), explicit: true, permissions: archive_entry_perm(entry))
    }
    private static func catalog(_ url: URL, operation: Operation? = nil) throws -> [String: Member] {
        let reader = try Reader(url, operation: operation)
        var result: [String: Member] = [:]
        var count = 0
        while let entry = try reader.next() {
            count += 1; guard count <= maxEntries else { throw ArchiveError.limit }
            if let item = try member(entry) {
                if let old = result[item.path], old.explicit || old.kind != item.kind { throw ArchiveError.unsafePath(item.path) }
                result[item.path] = item
                var parent = (item.path as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    if let existing = result[parent] {
                        guard existing.kind == .directory else { throw ArchiveError.unsafePath(parent) }
                    } else {
                        result[parent] = Member(path: parent, kind: .directory, size: 0, modified: nil, explicit: false, permissions: 0o755)
                    }
                    parent = (parent as NSString).deletingLastPathComponent
                }
                guard result.count <= maxEntries else { throw ArchiveError.limit }
            }
            try reader.skip()
        }
        guard archive_read_has_encrypted_entries(reader.handle) <= 0 else { throw ArchiveError.unsupportedEntry(url.lastPathComponent) }
        let detected = archive_format(reader.handle) & 0xff0000
        let expected = format(url)
        guard (expected == .zip && detected == 0x50000) ||
                ((expected == .tar || expected == .gzip) && detected == 0x30000) else {
            throw ArchiveError.invalid("Dateiendung und Archivformat stimmen nicht überein.")
        }
        let filter = archive_filter_code(reader.handle, 0)
        guard (expected == .gzip && filter == 1) || (expected != .gzip && filter == 0) else {
            throw ArchiveError.invalid("Nicht unterstützte Komprimierung.")
        }
        return result
    }
    private static func contains(_ path: String, roots: [String]) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    private static func requireAbsent(_ url: URL) throws {
        if memberLocation(url) != nil {
            if try entry(url) != nil { throw FileActionError.collision(url.lastPathComponent) }
        } else if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
            throw FileActionError.collision(url.lastPathComponent)
        }
    }
    static func validateBackingSource(_ source: URL, destination: URL) throws {
        guard memberLocation(source) == nil, let target = memberLocation(destination) else { return }
        let sourceStamp = try Stamp(source, regularOnly: false)
        let targetStamp = try Stamp(target.archiveURL)
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = target.archiveURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourceStamp.device != targetStamp.device || sourceStamp.inode != targetStamp.inode,
              !targetPath.hasPrefix(sourcePath + "/") else { throw FileActionError.recursiveDestination }
    }
    private static func makeTemporaryTreeRemovable(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeDirectory else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
            makeTemporaryTreeRemovable(child)
        }
    }
    private static func localTreeStamp(_ url: URL, operation: Operation? = nil) throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        func visit(_ item: URL) throws {
            try operation?.cancellation.check()
            let stamp = try Stamp(item, regularOnly: false)
            guard stamp.mode & S_IFMT == S_IFREG || stamp.mode & S_IFMT == S_IFDIR else {
                throw ArchiveError.unsupportedEntry(item.lastPathComponent)
            }
            result[item.path] = stamp
            guard result.count <= maxEntries else { throw ArchiveError.limit }
            if stamp.mode & S_IFMT == S_IFDIR {
                for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) { try visit(child) }
            }
        }
        try visit(url)
        return result
    }
    private static func validateLocalTree(_ url: URL, operation: Operation? = nil) throws {
        try operation?.cancellation.check()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let type = attrs[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw ArchiveError.unsupportedEntry(url.lastPathComponent) }
        if type == .typeDirectory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try validateLocalTree(child, operation: operation) }
        }
    }
    private static func extractMember(_ source: URL, to output: URL, operation: Operation? = nil) throws {
        try operation?.report(path: source.path)
        guard let location = memberLocation(source) else { throw FileActionError.invalidName }
        let stamp = try Stamp(location.archiveURL)
        let members = try catalog(location.archiveURL, operation: operation)
        guard let root = members[location.memberPath] else { throw CocoaError(.fileNoSuchFile) }
        let selected = members.values.filter { contains($0.path, roots: [root.path]) }
        var bytes: Int64 = 0
        for item in selected {
            guard item.kind == .directory || item.kind == .regular else { throw ArchiveError.unsupportedEntry(item.path) }
            guard item.size <= maxFileSize, bytes <= maxBytes - item.size else { throw ArchiveError.limit }
            bytes += item.size
        }
        try requireAbsent(output)
        let fm = FileManager.default
        func target(_ path: String) -> URL {
            path == root.path ? output : output.appendingPathComponent(String(path.dropFirst(root.path.count + 1)))
        }
        for item in selected.filter({ $0.kind == .directory }).sorted(by: { $0.path.count < $1.path.count }) {
            let destination = target(item.path)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let reader = try Reader(location.archiveURL, operation: operation)
        var actualBytes: Int64 = 0
        while let entry = try reader.next() {
            guard let item = try member(entry), item.kind == .regular, contains(item.path, roots: [root.path]) else { try reader.skip(); continue }
            let destination = target(item.path)
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw posixError() }
            do {
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try stream(reader, expectedSize: item.size, total: &actualBytes) { data in try handle.write(contentsOf: data) }
                try handle.close()
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: item.permissions & 0o777]
                if let modified = item.modified { attributes[.modificationDate] = modified }
                try fm.setAttributes(attributes, ofItemAtPath: destination.path)
            } catch { throw error }
        }
        for item in selected.filter({ $0.kind == .directory }).sorted(by: { $0.path.count > $1.path.count }) {
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: item.permissions & 0o777]
            if let modified = item.modified { attributes[.modificationDate] = modified }
            try fm.setAttributes(attributes, ofItemAtPath: target(item.path).path)
        }
        guard try Stamp(location.archiveURL) == stamp else { throw ArchiveError.changed }
    }
    private static func stream(_ reader: Reader, expectedSize: Int64, total: inout Int64,
                               consume: (Data) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var bytes: Int64 = 0
        while true {
            try reader.operation?.cancellation.check()
            let count = archive_read_data(reader.handle, &buffer, buffer.count)
            guard count >= 0 else { throw failure(reader.handle) }
            if count == 0 { break }
            bytes += Int64(count); total += Int64(count)
            guard bytes <= maxFileSize, total <= maxBytes else { throw ArchiveError.limit }
            try reader.operation?.report(path: reader.currentPath, bytes: bytes, total: expectedSize)
            try consume(Data(buffer.prefix(count)))
        }
        guard bytes == expectedSize else { throw ArchiveError.invalid("Unvollständiger Dateieintrag.") }
    }

    private static func rewrite(_ url: URL, additions: [Addition], removing: [String], expected: Stamp? = nil,
                                validateBeforeCommit: (() throws -> Void)? = nil, operation: Operation? = nil) throws {
        try operation?.report(path: url.path)
        let original = try Stamp(url)
        if let expected, original != expected { throw ArchiveError.changed }
        let existing = try catalog(url, operation: operation)
        // Re-encoding link/special semantics and encrypted archives would require
        // separate format-specific guarantees. Refuse rather than lose data.
        for item in existing.values where item.kind == .link || item.kind == .special { throw ArchiveError.unsupportedEntry(item.path) }
        for addition in additions {
            _ = try normalized(addition.path)
            guard existing[addition.path] == nil else { throw FileActionError.collision((addition.path as NSString).lastPathComponent) }
            if let source = addition.source { try validateLocalTree(source, operation: operation) }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".PaneRook-archive-" + UUID().uuidString + "-" + url.lastPathComponent)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        let writer = try Writer(fd: fd, format: format(url)!)
        let reader = try Reader(url, operation: operation)
        var bytes: Int64 = 0
        while let entry = try reader.next() {
            guard let item = try member(entry), !contains(item.path, roots: removing) else { try reader.skip(); continue }
            guard let cloned = archive_entry_clone(entry) else { throw ArchiveError.invalid("Nicht genug Speicher.") }
            defer { archive_entry_free(cloned) }
            guard archive_write_header(writer.handle, cloned) == 0 else { throw failure(writer.handle) }
            if item.kind == .regular {
                try stream(reader, expectedSize: item.size, total: &bytes) { data in
                    let wrote = data.withUnsafeBytes { archive_write_data(writer.handle, $0.baseAddress, data.count) }
                    guard wrote == data.count else { throw failure(writer.handle) }
                }
            } else { try reader.skip() }
            guard archive_write_finish_entry(writer.handle) == 0 else { throw failure(writer.handle) }
        }
        for addition in additions { try append(addition.source, path: addition.path, writer: writer, total: &bytes, operation: operation) }
        try writer.finish()
        _ = try catalog(temporary, operation: operation)
        guard fsync(fd) == 0, fchmod(fd, original.mode & 0o7777) == 0 else { throw posixError() }
        try operation?.cancellation.check()
        try validateBeforeCommit?()
        guard try Stamp(url) == original else { throw ArchiveError.changed }
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
    }
    private static func append(_ source: URL?, path: String, writer: Writer, total: inout Int64, operation: Operation? = nil) throws {
        try operation?.report(path: path)
        let attrs = try source.map { try FileManager.default.attributesOfItem(atPath: $0.path) }
        let directory = source == nil || attrs?[.type] as? FileAttributeType == .typeDirectory
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard directory || size <= maxFileSize else { throw ArchiveError.limit }
        guard let entry = archive_entry_new() else { throw ArchiveError.invalid("Nicht genug Speicher.") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname(entry, path)
        archive_entry_set_filetype(entry, directory ? UInt32(S_IFDIR) : UInt32(S_IFREG))
        archive_entry_set_perm(entry, ((attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? (directory ? 0o755 : 0o644)) & 0o777)
        archive_entry_set_size(entry, directory ? 0 : size)
        let modified = (attrs?[.modificationDate] as? Date) ?? Date()
        archive_entry_set_mtime(entry, Int(modified.timeIntervalSince1970), 0)
        guard archive_write_header(writer.handle, entry) == 0 else { throw failure(writer.handle) }
        if directory, let source {
            guard archive_write_finish_entry(writer.handle) == 0 else { throw failure(writer.handle) }
            for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                _ = try normalized(child.lastPathComponent)
                try append(child, path: path + "/" + child.lastPathComponent, writer: writer, total: &total, operation: operation)
            }
        } else if let source {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var actual: Int64 = 0
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                actual += Int64(data.count); total += Int64(data.count)
                guard actual <= maxFileSize, total <= maxBytes else { throw ArchiveError.limit }
                try operation?.report(path: path, bytes: actual, total: size)
                let wrote = data.withUnsafeBytes { archive_write_data(writer.handle, $0.baseAddress, data.count) }
                guard wrote == data.count else { throw failure(writer.handle) }
            }
            guard actual == size else { throw ArchiveError.changed }
        }
        guard archive_write_finish_entry(writer.handle) == 0 else { throw failure(writer.handle) }
    }
}
