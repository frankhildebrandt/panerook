import PaneRookTasks
import Foundation
import Darwin

/// Shared by workers and their Escape/Cancel buttons. Cancellation never leaves partial writes.
public final class InspectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw InspectionError.cancelled } }
}

public enum InspectionError: LocalizedError, Equatable {
    case cancelled, entryLimit(Int), fileLimit(Int64), notRegularFile(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Abgebrochen."
        case .entryLimit(let limit): return "Die Grenze von \(limit) Einträgen wurde erreicht. Bitte einen kleineren Ordner wählen."
        case .fileLimit(let limit): return "Der Vergleich ist auf \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) pro Datei begrenzt."
        case .notRegularFile(let path): return "Keine reguläre Datei: \(path)"
        }
    }
}

public struct FileSearchQuery: Sendable {
    public var namePattern: String
    public var content: String
    public var recursive: Bool
    public var includeHidden: Bool
    public var caseSensitive: Bool
    public var encoding: String.Encoding
    public var maximumResults: Int
    public var maximumContentBytes: Int
    public var maximumEntries: Int
    public init(namePattern: String = "*", content: String = "", recursive: Bool = true,
                includeHidden: Bool = false, caseSensitive: Bool = false, encoding: String.Encoding = .utf8,
                maximumResults: Int = 10_000, maximumContentBytes: Int = 1_048_576, maximumEntries: Int = 250_000) {
        self.namePattern = namePattern; self.content = content; self.recursive = recursive
        self.includeHidden = includeHidden; self.caseSensitive = caseSensitive; self.encoding = encoding
        self.maximumResults = max(1, maximumResults); self.maximumContentBytes = max(1, maximumContentBytes)
        self.maximumEntries = max(1, maximumEntries)
    }
}

public struct FileSearchResult: Sendable {
    public let urls: [URL]
    public let resultLimitReached: Bool
    public let skippedFiles: Int
    public let truncatedFiles: Int
    public let visitedEntries: Int
}

public struct FileComparison: Sendable {
    public let equal: Bool
    public let firstDifferentOffset: Int64?
    public let leftSize: Int64
    public let rightSize: Int64
    public let symbolicLinks: Bool
}

public struct DirectoryDifference: Sendable {
    public enum Kind: String, Sendable { case onlyLeft, onlyRight, different, differentType, unreadable }
    public let relativePath: String
    public let kind: Kind
    public let left: URL?
    public let right: URL?
    public let detail: String?
}

public struct DirectoryComparison: Sendable {
    public let differences: [DirectoryDifference]
    public let comparedFiles: Int
}

public enum LocalInspection {
    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    public static func entry(at url: URL) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: keys)
        let directory = values.isSymbolicLink == true
            ? ((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            : (values.isDirectory ?? false)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: directory,
                         isSymbolicLink: values.isSymbolicLink ?? false, size: Int64(values.fileSize ?? 0),
                         modified: values.contentModificationDate, isParent: false)
    }

    /// A filtered listing remains navigable, including when no file matches the mask.
    public static func filter(_ entries: [FileEntry], pattern: String) -> [FileEntry] {
        guard !pattern.isEmpty, pattern != "*" else { return entries }
        return entries.filter { $0.isParent || $0.isDirectory || matches($0.name, pattern: pattern) }
    }

    public static func matches(_ name: String, pattern: String, caseSensitive: Bool = true) -> Bool {
        let name = caseSensitive ? name : name.lowercased()
        let pattern = caseSensitive ? pattern : pattern.lowercased()
        return fnmatch(pattern, name, 0) == 0
    }

    /// Walks without following symbolic links. All reads are bounded, including a changing file.
    public static func search(in directory: URL, query: FileSearchQuery,
                              cancellation: InspectionCancellation = .init(),
                              progress: (OperationProgress) -> Void = { _ in }) throws -> FileSearchResult {
        var found: [URL] = []; var skipped = 0; var truncated = 0; var visited = 0; var limited = false
        progress(OperationProgress(currentPath: directory.path))
        try walk(directory, recursive: query.recursive, hidden: query.includeHidden,
                 maximumEntries: query.maximumEntries, cancellation: cancellation, onError: { _ in skipped += 1 }) { url, values, _ in
            visited += 1
            progress(OperationProgress(completedItems: visited, currentPath: url.path))
            guard matches(url.lastPathComponent, pattern: query.namePattern.isEmpty ? "*" : query.namePattern, caseSensitive: query.caseSensitive) else { return true }
            if !query.content.isEmpty {
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return true }
                do {
                    try cancellation.check()
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: query.maximumContentBytes) ?? Data()
                    if (values.fileSize ?? 0) > data.count { truncated += 1 }
                    let unicodeWithNULs = query.encoding == .utf16 || query.encoding == .utf16LittleEndian || query.encoding == .utf16BigEndian || query.encoding == .utf32 || query.encoding == .utf32LittleEndian || query.encoding == .utf32BigEndian
                    guard let text = String(data: data, encoding: query.encoding), unicodeWithNULs || !text.contains("\0") else { skipped += 1; return true }
                    let options: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
                    guard text.range(of: query.content, options: options) != nil else { return true }
                } catch InspectionError.cancelled { throw InspectionError.cancelled }
                catch { skipped += 1; return true }
            }
            found.append(url)
            if found.count >= query.maximumResults { limited = true; return false }
            return true
        }
        try cancellation.check()
        progress(OperationProgress(completedItems: visited, totalItems: visited, currentPath: directory.path))
        return FileSearchResult(urls: found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
                                resultLimitReached: limited, skippedFiles: skipped, truncatedFiles: truncated, visitedEntries: visited)
    }

    public static func byteCount(of url: URL, cancellation: InspectionCancellation = .init(), maximumEntries: Int = 1_000_000,
                                 progress: (OperationProgress) -> Void = { _ in }) throws -> Int64 {
        try cancellation.check()
        progress(OperationProgress(currentPath: url.path))
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true || values.isDirectory != true {
            let bytes = values.isSymbolicLink != true && values.isRegularFile == true ? Int64(values.fileSize ?? 0) : 0
            progress(OperationProgress(completedItems: 1, totalItems: 1, completedBytes: bytes, currentPath: url.path))
            try cancellation.check()
            return bytes
        }
        var total: Int64 = 0; var visited = 0
        try walk(url, recursive: true, hidden: true, maximumEntries: maximumEntries, cancellation: cancellation) { child, values, _ in
            visited += 1
            if values.isRegularFile == true && values.isSymbolicLink != true {
                let size = Int64(values.fileSize ?? 0)
                let addition = total.addingReportingOverflow(size)
                if addition.overflow { throw InspectionError.entryLimit(maximumEntries) }
                total = addition.partialValue
            }
            progress(OperationProgress(completedItems: visited, completedBytes: total, currentPath: child.path))
            return true
        }
        progress(OperationProgress(completedItems: visited, totalItems: visited, completedBytes: total, currentPath: url.path))
        return total
    }

    public static func compareFiles(_ left: URL, _ right: URL, cancellation: InspectionCancellation = .init(),
                                    maximumBytes: Int64 = 1_073_741_824,
                                    progress: (OperationProgress) -> Void = { _ in }) throws -> FileComparison {
        try cancellation.check()
        let a = try left.resourceValues(forKeys: keys), b = try right.resourceValues(forKeys: keys)
        let leftSize = Int64(a.fileSize ?? 0), rightSize = Int64(b.fileSize ?? 0)
        let bound = max(leftSize, rightSize)
        func report(_ bytes: Int64, finished: Bool = false) {
            progress(OperationProgress(completedItems: finished ? 1 : 0, totalItems: 1,
                completedBytes: bytes, totalBytes: bound, currentPath: left.path,
                currentFileBytes: bytes, currentFileTotalBytes: bound))
        }
        report(0)
        if a.isSymbolicLink == true || b.isSymbolicLink == true {
            var same = false
            if a.isSymbolicLink == true && b.isSymbolicLink == true {
                same = try FileManager.default.destinationOfSymbolicLink(atPath: left.path) == FileManager.default.destinationOfSymbolicLink(atPath: right.path)
            }
            report(bound, finished: true)
            try cancellation.check()
            return FileComparison(equal: same, firstDifferentOffset: same ? nil : 0, leftSize: leftSize, rightSize: rightSize, symbolicLinks: true)
        }
        guard a.isRegularFile == true else { throw InspectionError.notRegularFile(left.path) }
        guard b.isRegularFile == true else { throw InspectionError.notRegularFile(right.path) }
        guard max(leftSize, rightSize) <= maximumBytes else { throw InspectionError.fileLimit(maximumBytes) }
        let ah = try FileHandle(forReadingFrom: left); defer { try? ah.close() }
        let bh = try FileHandle(forReadingFrom: right); defer { try? bh.close() }
        var offset: Int64 = 0
        // Include the initial lengths in the bound, so concurrently growing files cannot keep a comparison alive.
        while offset < bound {
            try cancellation.check()
            let count = Int(min(65_536, bound - offset))
            let ad = try ah.read(upToCount: count) ?? Data(), bd = try bh.read(upToCount: count) ?? Data()
            report(offset + Int64(max(ad.count, bd.count)))
            try cancellation.check()
            if ad != bd {
                let common = min(ad.count, bd.count)
                let mismatch = (0..<common).first { ad[$0] != bd[$0] } ?? common
                return FileComparison(equal: false, firstDifferentOffset: offset + Int64(mismatch), leftSize: leftSize, rightSize: rightSize, symbolicLinks: false)
            }
            if ad.isEmpty { break }
            offset += Int64(ad.count)
        }
        report(offset, finished: true)
        try cancellation.check()
        return FileComparison(equal: leftSize == rightSize, firstDifferentOffset: leftSize == rightSize ? nil : min(leftSize, rightSize), leftSize: leftSize, rightSize: rightSize, symbolicLinks: false)
    }

    public static func compareDirectories(_ left: URL, _ right: URL, recursive: Bool = true,
                                          cancellation: InspectionCancellation = .init(), maximumEntries: Int = 100_000,
                                          progress: (OperationProgress) -> Void = { _ in }) throws -> DirectoryComparison {
        struct Item { let url: URL; let directory: Bool; let link: Bool }
        var scanned = 0
        progress(OperationProgress(currentPath: left.path))
        func inventory(_ root: URL) throws -> [String: Item] {
            let root = root.resolvingSymlinksInPath().standardizedFileURL
            var items: [String: Item] = [:]
            try walk(root, recursive: recursive, hidden: true, maximumEntries: maximumEntries, cancellation: cancellation) { url, values, relativePath in
                items[relativePath] = Item(url: url, directory: values.isDirectory == true, link: values.isSymbolicLink == true)
                scanned += 1
                progress(OperationProgress(completedItems: scanned, currentPath: url.path))
                return true
            }
            return items
        }
        let a = try inventory(left), b = try inventory(right)
        var differences: [DirectoryDifference] = []; var compared = 0
        let paths = Set(a.keys).union(b.keys).sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        var completed = 0
        progress(OperationProgress(totalItems: paths.count, currentPath: left.path))
        for path in paths {
            try cancellation.check()
            let ai = a[path], bi = b[path]
            defer {
                completed += 1
                progress(OperationProgress(completedItems: completed, totalItems: paths.count, currentPath: (ai?.url ?? bi!.url).path))
            }
            let kind: DirectoryDifference.Kind
            var detail: String?
            if ai == nil { kind = .onlyRight }
            else if bi == nil { kind = .onlyLeft }
            else if ai!.directory != bi!.directory || ai!.link != bi!.link { kind = .differentType }
            else if ai!.directory && !ai!.link { continue }
            else {
                do {
                    let result = try compareFiles(ai!.url, bi!.url, cancellation: cancellation) { file in
                        progress(OperationProgress(completedItems: completed, totalItems: paths.count, currentPath: file.currentPath,
                            currentFileBytes: file.currentFileBytes, currentFileTotalBytes: file.currentFileTotalBytes))
                    }
                    compared += 1
                    if result.equal { continue }
                    kind = .different
                    if let offset = result.firstDifferentOffset { detail = "Ab Byte \(offset)" }
                } catch InspectionError.cancelled { throw InspectionError.cancelled }
                catch { kind = .unreadable; detail = error.localizedDescription }
            }
            differences.append(DirectoryDifference(relativePath: path, kind: kind, left: ai?.url, right: bi?.url, detail: detail))
        }
        try cancellation.check()
        return DirectoryComparison(differences: differences, comparedFiles: compared)
    }

    private static func walk(_ root: URL, recursive: Bool, hidden: Bool, maximumEntries: Int,
                             cancellation: InspectionCancellation, onError: ((Error) -> Void)? = nil,
                             visit: (URL, URLResourceValues, String) throws -> Bool) throws {
        try cancellation.check()
        // Resolve the explicitly selected root once. Keep relative paths while traversing:
        // Foundation may return /private/var children for a /var root on macOS.
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true else { throw FileActionError.invalidDirectory(root.path) }
        let options: FileManager.DirectoryEnumerationOptions = hidden ? [] : [.skipsHiddenFiles]
        var count = 0
        var pending: [(url: URL, relative: String)] = [(root, "")]
        while let directory = pending.popLast() {
            try cancellation.check()
            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: Array(keys), options: options)
            } catch { if let onError { onError(error); continue } else { throw error } }
            for url in children {
                try cancellation.check()
                count += 1
                guard count <= maximumEntries else { throw InspectionError.entryLimit(maximumEntries) }
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    let relative = directory.relative.isEmpty ? url.lastPathComponent : directory.relative + "/" + url.lastPathComponent
                    if try !visit(url, values, relative) { return }
                    if recursive, values.isDirectory == true, values.isSymbolicLink != true { pending.append((url, relative)) }
                } catch InspectionError.cancelled { throw InspectionError.cancelled }
                catch { if let onError { onError(error) } else { throw error } }
            }
        }
        try cancellation.check()
    }
}
