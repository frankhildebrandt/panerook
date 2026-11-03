import Foundation
import Darwin
import PaneRookTasks

struct RenameIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t

    static func read(_ url: URL) throws -> (RenameIdentity, stat) {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return (RenameIdentity(device: value.st_dev, inode: value.st_ino, kind: value.st_mode & S_IFMT), value)
    }
}

/// Captured once when opening the dialog; symlink entries themselves are renamed.
public struct BatchRenameSource: Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let modified: Date
    public let created: Date
    let identity: RenameIdentity
    let parentIdentity: RenameIdentity

    public init(url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              ArchiveFileSystem.memberLocation(url) == nil, url.path != "/", !url.path.contains("\0") else {
            throw BatchRenameError("Mehrfachumbenennen unterstützt nur lokale Einträge außerhalb von Archiven.")
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        self.url = parent.appendingPathComponent(url.lastPathComponent)
        let (identity, value) = try RenameIdentity.read(self.url)
        self.identity = identity
        self.parentIdentity = try RenameIdentity.read(parent).0
        isDirectory = identity.kind == S_IFDIR
        modified = Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9)
        created = Date(timeIntervalSince1970: Double(value.st_birthtimespec.tv_sec) + Double(value.st_birthtimespec.tv_nsec) / 1e9)
    }
    func validate() throws {
        guard try RenameIdentity.read(url).0 == identity,
              try RenameIdentity.read(url.deletingLastPathComponent()).0 == parentIdentity else {
            throw BatchRenameError("Die erfasste Quelle oder ihr Ordner wurde ersetzt: \(url.path)")
        }
    }
}

/// Immutable preview/confirmation contract. Construction never mutates the filesystem.
public struct BatchRenamePlan: Sendable {
    public struct Item: Sendable {
        public let source: BatchRenameSource
        public let destination: URL
        public var changesName: Bool {
            !source.url.lastPathComponent.utf8.elementsEqual(destination.lastPathComponent.utf8)
        }
    }
    public let items: [Item]
    public var changedItems: [Item] { items.filter(\.changesName) }

    public init(sources: [BatchRenameSource], names: [String]) throws {
        guard !sources.isEmpty, sources.count == names.count else { throw FileActionError.noMatchingSources }
        items = zip(sources, names).map { Item(source: $0, destination: $0.url.deletingLastPathComponent().appendingPathComponent($1)) }
        try validate(names: names)
    }
    private func validate(names: [String]) throws {
        var issues: [String] = []
        for (item, name) in zip(items, names) {
            do {
                try FileActions.validateName(name)
                let limit = pathconf(item.source.url.deletingLastPathComponent().path, _PC_NAME_MAX)
                guard limit < 0 || name.utf8.count <= limit else { throw BatchRenameError("Der Name ist zu lang.") }
                try item.source.validate()
            } catch { issues.append("\(item.source.url.path): \(error.localizedDescription)") }
        }
        guard issues.isEmpty else { throw BatchRenameError(issues.joined(separator: "\n")) }
        let groups = Dictionary(grouping: items, by: { $0.source.url.deletingLastPathComponent() })
        for (parent, group) in groups {
            // Unknown volume semantics are treated conservatively.
            let sensitive = (try? parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
            func key(_ name: String) -> String {
                let canonical = name.precomposedStringWithCanonicalMapping
                return sensitive ? canonical : canonical.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            }
            let sourceKeys = Set(group.map { key($0.source.url.lastPathComponent) })
            guard sourceKeys.count == group.count else { throw BatchRenameError("Die Auswahl enthält denselben Eintrag mehrfach.") }
            let existing = Set(try FileManager.default.contentsOfDirectory(atPath: parent.path).map(key))
            var targets = Set<String>()
            for item in group {
                let target = key(item.destination.lastPathComponent)
                if !targets.insert(target).inserted {
                    issues.append("Mehrere Einträge ergeben denselben Zielnamen: \(item.destination.path)")
                }
                if existing.contains(target), !sourceKeys.contains(target) {
                    issues.append("Das Ziel existiert bereits: \(item.destination.path)")
                }
            }
        }
        // Panelized results can contain both a directory and a descendant.
        let directories = Set(items.filter { $0.source.isDirectory }.map { $0.source.url.path })
        for item in items {
            var parent = item.source.url.deletingLastPathComponent()
            while parent.path != "/" {
                if directories.contains(parent.path) {
                    issues.append("Ordner und enthaltene Einträge können nicht gemeinsam umbenannt werden: \(parent.path)")
                    break
                }
                parent.deleteLastPathComponent()
            }
        }
        guard issues.isEmpty else { throw BatchRenameError(issues.joined(separator: "\n")) }
    }

    public func execute(cancellation: TransferCancellation = .init(),
                        progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        try cancellation.check()
        try validate(names: items.map { $0.destination.lastPathComponent })
        try BatchRenameWorker(items: changedItems, cancellation: cancellation, progress: progress).run()
    }
}
