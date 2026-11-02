import Foundation
import PaneRookCore

public enum GitFileFilter: String, CaseIterable, Sendable {
    case all, changed, staged, untracked, conflicted, stashed, watched, tracked, ignored

    public var title: String {
        switch self {
        case .all: return "Alle Dateien"
        case .changed: return "Changed · Geändert"
        case .staged: return "Staged · Vorgemerkt"
        case .untracked: return "Untracked · Neu"
        case .conflicted: return "Konflikte"
        case .stashed: return "Stashed · Gesichert"
        case .watched: return "Watched · Beobachtet"
        case .tracked: return "Tracked · Versioniert"
        case .ignored: return "Ignoriert"
        }
    }

    public func matches(_ entry: FileEntry, snapshot: GitSnapshot, watchedPaths: Set<String>) -> Bool {
        !filter([entry], snapshot: snapshot, watchedPaths: watchedPaths).isEmpty
    }

    public func filter(_ entries: [FileEntry], snapshot: GitSnapshot, watchedPaths: Set<String>) -> [FileEntry] {
        guard self != .all else { return entries }
        let paths: Set<String>
        switch self {
        case .all: return entries
        case .changed: paths = Set(snapshot.files.filter(\.isChanged).map(\.path))
        case .staged: paths = Set(snapshot.files.filter(\.isStaged).map(\.path))
        case .untracked: paths = Set(snapshot.files.filter(\.isUntracked).map(\.path))
        case .conflicted: paths = Set(snapshot.files.filter(\.isConflicted).map(\.path))
        case .stashed: paths = snapshot.stashedPaths
        case .watched: paths = watchedPaths
        case .tracked: paths = snapshot.trackedPaths
        case .ignored: paths = Set(snapshot.files.filter(\.isIgnored).map(\.path))
        }
        let exact = Set(paths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter(GitPanelPaths.isRepositoryPath))
        var ancestors = Set<String>()
        for path in exact {
            var components = path.split(separator: "/")
            while components.count > 1 {
                components.removeLast()
                ancestors.insert(components.joined(separator: "/"))
            }
        }
        return entries.filter { entry in
            guard !entry.isParent else { return true }
            guard let path = GitPanelPaths.relativePath(for: entry.url, in: snapshot.root),
                  GitPanelPaths.isRepositoryPath(path) else { return false }
            if exact.contains(path) { return true }
            if entry.isDirectory && !entry.isSymbolicLink && ancestors.contains(path) { return true }
            if self == .watched || self == .ignored {
                var components = path.split(separator: "/")
                while components.count > 1 {
                    components.removeLast()
                    if exact.contains(components.joined(separator: "/")) { return true }
                }
            }
            return false
        }
    }
}

public enum GitPanelPaths {
    /// Resolve the parent to normalize aliases such as /tmp and /private/tmp,
    /// retaining the entry itself when it is a symbolic link.
    public static func relativePath(for url: URL, in root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let entryPath = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard entryPath.hasPrefix(prefix), entryPath != rootPath else { return nil }
        return String(entryPath.dropFirst(prefix.count))
    }

    public static func isRepositoryPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && !path.hasPrefix("/")
            && !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" })
            && !path.contains("\0")
    }

    public static func statusLabel(for entry: FileEntry, snapshot: GitSnapshot, watchedPaths: Set<String>) -> String? {
        guard !entry.isParent, let path = relativePath(for: entry.url, in: snapshot.root),
              isRepositoryPath(path) else { return nil }
        let statuses = snapshot.files.filter {
            $0.path == path || (entry.isDirectory && !entry.isSymbolicLink && $0.path.hasPrefix(path + "/"))
        }
        let label: String?
        if statuses.contains(where: \.isConflicted) { label = "!" }
        else if let exact = statuses.first(where: { $0.path == path }) {
            let value = exact.indexStatus + exact.workTreeStatus
            label = value.trimmingCharacters(in: .whitespaces)
        } else if statuses.contains(where: \.isStaged) { label = "S" }
        else if statuses.contains(where: { $0.isChanged && !$0.isUntracked }) { label = "M" }
        else if statuses.contains(where: \.isUntracked) { label = "?" }
        else if statuses.contains(where: \.isIgnored) { label = "!·" }
        else { label = nil }
        let watched = GitFileFilter.watched.matches(entry, snapshot: snapshot, watchedPaths: watchedPaths)
        if watched { return label.map { "★ " + $0 } ?? "★" }
        return label
    }
}

/// Watches are local PaneRook bookmarks, independent of Git's tracked state.
public final class GitWatchStore {
    private let defaults: UserDefaults
    private static let lock = NSLock()
    private let key = "gitWatchedPaths"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func paths(in root: URL) -> Set<String> {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let repositories = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set((repositories[repositoryKey(root)] ?? []).filter(GitPanelPaths.isRepositoryPath))
    }

    public func toggle(paths: [String], in root: URL) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var repositories = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        let repository = repositoryKey(root)
        var watched = Set(repositories[repository] ?? [])
        for path in Set(paths) where GitPanelPaths.isRepositoryPath(path) {
            if !watched.insert(path).inserted { watched.remove(path) }
        }
        repositories[repository] = watched.sorted()
        defaults.set(repositories, forKey: key)
    }

    private func repositoryKey(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
