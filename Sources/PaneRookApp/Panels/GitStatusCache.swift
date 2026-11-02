import Foundation
import PaneRookCore

/// The persisted header contains display data only; full file-status snapshots
/// are kept separately in memory for the current session.
struct GitHeaderStatus: Codable {
    let root: URL
    let branch: String
    let changedCount: Int
    let ahead: Int
    let behind: Int
    let stashCount: Int
    let operation: String?

    init(snapshot: GitSnapshot) {
        root = snapshot.root.standardizedFileURL
        branch = snapshot.branch
        changedCount = snapshot.files.filter(\.isChanged).count
        ahead = snapshot.ahead
        behind = snapshot.behind
        stashCount = snapshot.stashes.count
        operation = snapshot.operation
    }

    var title: String {
        let divergence = (ahead > 0 ? " ↑\(ahead)" : "") + (behind > 0 ? " ↓\(behind)" : "")
        return "\(branch) · \(changedCount == 0 ? "sauber" : "\(changedCount) geändert")\(divergence)"
    }

    var toolTip: String {
        "\(root.path)\n\(branch) · \(changedCount) geändert · \(stashCount) Stashes"
            + (operation.map { " · " + $0 } ?? "")
            + "\nGit öffnen: Branches, Status, Diffs und Versionen"
    }
}

/// Shared across panels and windows, on the main queue. Cache reads never visit
/// the filesystem or replace the caller's fresh Git request.
final class GitStatusCache {
    static let shared = GitStatusCache()

    private struct Entry: Codable {
        let directory: String
        var status: GitRepositoryStatus?
        var header: GitHeaderStatus?
    }

    private struct Archive: Codable {
        let version: Int
        let entries: [Entry]
    }

    private let defaults: UserDefaults
    private let limit: Int
    private let key = "PaneRook.gitStatusCache"
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var snapshots: [String: GitSnapshot] = [:]
    private var snapshotOrder: [String] = []
    private var snapshotAliases: [String: String] = [:]
    private var snapshotAliasOrder: [String] = []

    init(defaults: UserDefaults = .standard, limit: Int = 200) {
        self.defaults = defaults
        self.limit = max(0, limit)
        guard let data = defaults.data(forKey: key),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1,
              archive.entries.allSatisfy(Self.isValid) else { return }
        for entry in archive.entries {
            entries[entry.directory] = entry
            order.removeAll { $0 == entry.directory }
            order.append(entry.directory)
        }
        trim()
    }

    func status(for directory: URL) -> GitRepositoryStatus? {
        Self.directoryKey(directory).flatMap { entries[$0]?.status }
    }

    func header(for directory: URL) -> GitHeaderStatus? {
        Self.directoryKey(directory).flatMap { entries[$0]?.header }
    }

    func snapshot(for directory: URL) -> GitSnapshot? {
        guard let directory = Self.directoryKey(directory) else { return nil }
        return snapshots[snapshotAliases[directory] ?? directory]
    }

    /// One full snapshot per worktree, with only previously queried directories
    /// as aliases. A nested repository must never inherit an arbitrary ancestor.
    func storeSnapshot(_ snapshot: GitSnapshot?, for directory: URL) {
        guard let directory = Self.directoryKey(directory) else { return }
        guard let snapshot else {
            if snapshots[directory] != nil { removeSnapshot(root: directory) }
            else { removeSnapshotAlias(directory) }
            return
        }
        guard limit > 0, let root = Self.directoryKey(snapshot.root) else { return }
        if directory != root, snapshots[directory] != nil {
            // A former repository root can now belong to an enclosing worktree.
            removeSnapshot(root: directory)
        }
        snapshots[root] = snapshot
        snapshotOrder.removeAll { $0 == root }
        snapshotOrder.append(root)
        removeSnapshotAlias(root)
        if directory != root {
            removeSnapshotAlias(directory)
            snapshotAliases[directory] = root
            snapshotAliasOrder.append(directory)
        }
        while snapshotOrder.count > min(20, limit), let oldest = snapshotOrder.first {
            removeSnapshot(root: oldest)
        }
        while snapshotAliasOrder.count > limit {
            removeSnapshotAlias(snapshotAliasOrder[0])
        }
    }

    func store(_ status: GitRepositoryStatus?, for directory: URL) {
        guard let directory = Self.directoryKey(directory) else { return }
        guard status != nil || entries[directory]?.status != nil else { return }
        var entry = entries[directory] ?? Entry(directory: directory)
        entry.status = status
        update(entry)
        save()
    }

    func store(_ header: GitHeaderStatus?, for directory: URL) {
        guard let directory = Self.directoryKey(directory) else { return }
        if let header {
            guard let root = Self.directoryKey(header.root) else { return }
            // Update known aliases as well, without guessing that an unvisited
            // descendant belongs to this repository (it may be a nested repo).
            for alias in order where entries[alias]?.header.map({ Self.directoryKey($0.root) == root }) == true {
                entries[alias]?.header = header
            }
            var rootEntry = entries[root] ?? Entry(directory: root)
            rootEntry.header = header
            update(rootEntry)
            if directory != root {
                var entry = entries[directory] ?? Entry(directory: directory)
                entry.header = header
                update(entry)
            }
        } else {
            let affected = order.filter {
                ($0 == directory && entries[$0]?.header != nil)
                    || entries[$0]?.header.map { Self.directoryKey($0.root) == directory } == true
            }
            guard !affected.isEmpty else { return }
            for alias in affected {
                guard var entry = entries[alias] else { continue }
                entry.header = nil
                update(entry)
            }
        }
        save()
    }

    private func update(_ entry: Entry) {
        order.removeAll { $0 == entry.directory }
        if entry.status == nil && entry.header == nil {
            entries.removeValue(forKey: entry.directory)
        } else {
            entries[entry.directory] = entry
            order.append(entry.directory)
        }
        trim()
    }

    private func removeSnapshot(root: String) {
        snapshots.removeValue(forKey: root)
        snapshotOrder.removeAll { $0 == root }
        for alias in snapshotAliasOrder.filter({ snapshotAliases[$0] == root }) {
            removeSnapshotAlias(alias)
        }
    }

    private func removeSnapshotAlias(_ directory: String) {
        snapshotAliases.removeValue(forKey: directory)
        snapshotAliasOrder.removeAll { $0 == directory }
    }

    private func trim() {
        while order.count > limit { entries.removeValue(forKey: order.removeFirst()) }
    }

    private func save() {
        let archive = Archive(version: 1, entries: order.compactMap { entries[$0] })
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: key)
    }

    private static func directoryKey(_ directory: URL) -> String? {
        guard directory.isFileURL,
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.query == nil, directory.fragment == nil,
              directory.path.hasPrefix("/"), !directory.path.contains("\0") else { return nil }
        return directory.standardizedFileURL.path
    }

    private static func isValid(_ entry: Entry) -> Bool {
        guard entry.directory.hasPrefix("/"), !entry.directory.contains("\0"),
              directoryKey(URL(fileURLWithPath: entry.directory, isDirectory: true)) == entry.directory,
              entry.status != nil || entry.header != nil else { return false }
        if let status = entry.status {
            guard status.branch.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true,
                  [status.stagedCount, status.modifiedCount, status.untrackedCount, status.conflictCount,
                   status.aheadCount, status.behindCount].allSatisfy({ $0 >= 0 }) else { return false }
        }
        if let header = entry.header {
            guard directoryKey(header.root) != nil, !header.branch.isEmpty, !header.branch.contains("\0"),
                  [header.changedCount, header.ahead, header.behind, header.stashCount].allSatisfy({ $0 >= 0 }) else { return false }
        }
        return true
    }
}
