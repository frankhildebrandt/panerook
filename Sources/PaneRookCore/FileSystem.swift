import Foundation
import Darwin

public struct FileEntry: Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64
    public let modified: Date?
    public let isParent: Bool

    public static func parent(of directory: URL) -> FileEntry {
        FileEntry(url: directory.deletingLastPathComponent(), name: "..", isDirectory: true,
                  isSymbolicLink: false, size: 0, modified: nil, isParent: true)
    }
}

public enum FileSystem {
    public static func list(_ directory: URL, showHidden: Bool) throws -> [FileEntry] {
        if ArchiveFileSystem.location(for: directory) != nil {
            return try ArchiveFileSystem.list(directory, showHidden: showHidden)
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: showHidden ? [] : [.skipsHiddenFiles])
        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            let isDirectory = values.isSymbolicLink == true
                ? ((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                : (values.isDirectory ?? false)
            return FileEntry(url: url, name: url.lastPathComponent,
                isDirectory: isDirectory, isSymbolicLink: values.isSymbolicLink ?? false,
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate, isParent: false)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public static func directory(from path: String, relativeTo base: URL) throws -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)).standardizedFileURL
        if ArchiveFileSystem.location(for: url) != nil {
            guard try ArchiveFileSystem.isDirectory(url) else { throw FileActionError.invalidDirectory(url.path) }
            return url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FileActionError.invalidDirectory(url.path)
        }
        return url
    }
}

public enum FileActionError: LocalizedError {
    case invalidDirectory(String), invalidName, collision(String), recursiveDestination, sameLocation, duplicateName, noMatchingSources
    public var errorDescription: String? {
        switch self {
        case .invalidDirectory(let path): return "Kein erreichbarer Ordner: \(path)"
        case .invalidName: return "Bitte einen einzelnen Namen ohne /, : oder .. eingeben."
        case .collision(let name): return "\(name) existiert bereits im Ziel. Es wurde nichts überschrieben."
        case .recursiveDestination: return "Ein Ordner kann nicht in sich selbst kopiert oder verschoben werden."
        case .sameLocation: return "Quelle und Ziel sind identisch."
        case .duplicateName: return "Mehrere Quelldateien haben denselben Namen."
        case .noMatchingSources: return "Keine ausgewählten Einträge passen zur Quellmaske."
        }
    }
}

public enum TransferKind: Sendable { case copy, move }

public struct TransferPlan: Sendable {
    public struct Item: Sendable {
        public let source: URL
        public let destination: URL
    }
    public let items: [Item]
    public let kind: TransferKind

    public init(sources: [URL], destination: URL, kind: TransferKind) throws {
        let target = try FileSystem.directory(from: destination.path, relativeTo: destination)
        try self.init(sources: sources, outputs: sources.map { target.appendingPathComponent($0.lastPathComponent) }, kind: kind)
    }

    /// The MC-style dialog accepts an existing target directory or a new name for one item.
    /// Relative targets are interpreted from the source panel's directory.
    public init(sources: [URL], sourcePattern: String, destinationPath: String,
                relativeTo base: URL, kind: TransferKind) throws {
        let matched = sources.filter { fnmatch(sourcePattern, $0.lastPathComponent, 0) == 0 }
        guard !sourcePattern.isEmpty, !matched.isEmpty else { throw FileActionError.noMatchingSources }
        guard !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileActionError.invalidDirectory(destinationPath)
        }
        let expanded = (destinationPath as NSString).expandingTildeInPath
        let target = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)).standardizedFileURL
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &directory)
        let archiveDirectory = try ArchiveFileSystem.isDirectory(target)
        if (exists && directory.boolValue) || archiveDirectory {
            try self.init(sources: matched, outputs: matched.map { target.appendingPathComponent($0.lastPathComponent) }, kind: kind)
        } else {
            guard matched.count == 1, !destinationPath.hasSuffix("/") else {
                throw FileActionError.invalidDirectory(target.path)
            }
            _ = try FileSystem.directory(from: target.deletingLastPathComponent().path, relativeTo: base)
            try FileActions.validateName(target.lastPathComponent)
            try self.init(sources: matched, outputs: [target], kind: kind)
        }
    }

    private init(sources: [URL], outputs: [URL], kind: TransferKind) throws {
        let fm = FileManager.default
        var destinations = Set<String>()
        var items: [Item] = []
        for (source, output) in zip(sources, outputs) {
            try ArchiveFileSystem.validateBackingSource(source, destination: output)
            let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL.path
            // Resolve the existing parent first: Foundation may leave symlinks unresolved
            // when the final component does not exist yet.
            let canonicalOutput = output.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(output.lastPathComponent).standardizedFileURL.path
            guard destinations.insert(canonicalOutput).inserted else { throw FileActionError.duplicateName }
            guard canonicalSource != canonicalOutput else { throw FileActionError.sameLocation }
            let isSourceDirectory: Bool
            let isSourceLink: Bool
            if ArchiveFileSystem.memberLocation(source) != nil {
                guard let entry = try ArchiveFileSystem.entry(source) else { throw CocoaError(.fileNoSuchFile) }
                isSourceDirectory = entry.isDirectory; isSourceLink = entry.isSymbolicLink
            } else {
                let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                isSourceDirectory = values.isDirectory == true; isSourceLink = values.isSymbolicLink == true
            }
            if isSourceDirectory && !isSourceLink {
                if canonicalOutput.hasPrefix(canonicalSource == "/" ? "/" : canonicalSource + "/") {
                    throw FileActionError.recursiveDestination
                }
            }
            // attributesOfItem also detects dangling symlinks, which fileExists follows.
            let archiveOutput = try ArchiveFileSystem.entry(output)
            if (try? fm.attributesOfItem(atPath: output.path)) != nil || archiveOutput != nil { throw FileActionError.collision(output.lastPathComponent) }
            items.append(Item(source: source, destination: output))
        }
        self.items = items
        self.kind = kind
    }

    /// FileManager refuses existing destinations. A failed batch can have completed earlier items.
    public func execute() throws {
        if items.contains(where: { ArchiveFileSystem.memberLocation($0.source) != nil || ArchiveFileSystem.memberLocation($0.destination) != nil }) {
            try ArchiveFileSystem.transfer(items, kind: kind)
            return
        }
        for item in items {
            switch kind {
            case .copy: try FileManager.default.copyItem(at: item.source, to: item.destination)
            case .move: try FileManager.default.moveItem(at: item.source, to: item.destination)
            }
        }
    }
}

public enum FileActions {
    public static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw FileActionError.invalidName
        }
    }

    @discardableResult public static func createDirectory(named name: String, in directory: URL) throws -> URL {
        try validateName(name)
        if ArchiveFileSystem.location(for: directory) != nil {
            return try ArchiveFileSystem.createDirectory(named: name, in: directory)
        }
        let url = directory.appendingPathComponent(name, isDirectory: true)
        if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil { throw FileActionError.collision(name) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
