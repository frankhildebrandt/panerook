import Foundation
import PaneRookCore

public enum PanelMode { case listing, quickView, info, tree, network, gitHistory, terminal }

/// Value state for one panel. AppKit owns focus and rendering; this type owns listings
/// and navigation generations so a late worker cannot replace newer navigation/results.
public struct PanelState {
    public var mode: PanelMode = .listing
    public var filterPattern = ""
    public var gitFilter: GitFileFilter = .all
    public var gitSnapshot: GitSnapshot?
    public var watchedPaths: Set<String> = []
    public var textEncoding: String.Encoding = .utf8
    public private(set) var directory: URL
    public private(set) var history: [URL] = []
    public private(set) var generation = 0
    public private(set) var loading = false
    public private(set) var panelized = false
    public var pendingTaskRefresh = false
    public var allEntries: [FileEntry] = []
    public var entries: [FileEntry] = []
    public var directorySizes: [URL: Int64] = [:]
    public private(set) var gitStatuses: [URL: GitRepositoryStatus] = [:]
    public var showHidden = false
    public var sortKey = "name"
    public var sortAscending = true

    public init(directory: URL) { self.directory = directory }
    public var isArchiveDirectory: Bool { ArchiveFileSystem.location(for: directory) != nil }
    public var visitedDirectories: [URL] {
        Array(
            (history + [directory]).reversed().reduce(into: [URL]()) {
                if !$0.contains($1) { $0.append($1) }
            })
    }
    public var parentDirectory: URL {
        let archive = ArchiveFileSystem.location(for: directory)
        return archive?.memberPath.isEmpty == true
            ? archive!.archiveURL.deletingLastPathComponent() : directory.deletingLastPathComponent()
    }
    public mutating func popHistory() -> URL? { history.popLast() }
    public mutating func beginNavigation() -> Int {
        generation += 1
        loading = true
        return generation
    }
    /// Returns false for a superseded request, including a switch to search results.
    public mutating func completeNavigation(
        _ request: Int, to url: URL, files: [FileEntry],
        recordHistory: Bool, preserveDirectorySizes: Bool
    ) -> Bool {
        guard request == generation else { return false }
        loading = false
        if directory != url {
            gitSnapshot = nil
            watchedPaths = []
        }
        if recordHistory && directory != url { history.append(directory) }
        directory = url
        panelized = false
        gitStatuses = [:]
        if !preserveDirectorySizes { directorySizes = [:] }
        allEntries = files
        if url.path != "/" { allEntries.insert(.parent(of: url), at: 0) }
        filterAndSort()
        return true
    }
    public mutating func failNavigation(_ request: Int) -> Bool {
        guard request == generation else { return false }
        loading = false
        return true
    }
    /// Observation refreshes the current location without starting navigation or
    /// clearing its Git snapshot. It cannot replace search results or a new load.
    @discardableResult
    public mutating func applyObservedListing(_ files: [FileEntry], in url: URL, request: Int) -> Bool {
        guard generation == request, directory == url, !loading, !panelized,
              !isArchiveDirectory, mode == .listing || mode == .tree else { return false }
        allEntries = (url.path == "/" ? [] : [.parent(of: url)]) + files
        let directories = Set(files.filter(\.isDirectory).map(\.url))
        gitStatuses = gitStatuses.filter { directories.contains($0.key) }
        directorySizes = [:]
        filterAndSort()
        return true
    }
    public mutating func showResults(_ files: [FileEntry]) {
        generation += 1
        loading = false
        panelized = true
        gitStatuses = [:]
        allEntries = [.parent(of: directory)] + files
        filterAndSort()
    }
    /// Git inspection follows a listing generation, independently of filtering or sorting.
    @discardableResult
    public mutating func applyGitStatus(_ status: GitRepositoryStatus?, for url: URL, request: Int) -> Bool {
        guard request == generation, !loading, !panelized, !isArchiveDirectory,
              allEntries.contains(where: { $0.url == url && $0.isDirectory && !$0.isParent }) else { return false }
        gitStatuses[url] = status
        return true
    }
    public func canApplyTaskResult(in url: URL) -> Bool {
        directory == url && !loading && !panelized && mode == .listing
    }
    public mutating func filterAndSort() {
        entries = LocalInspection.filter(allEntries, pattern: filterPattern)
        if !panelized, !isArchiveDirectory, let snapshot = gitSnapshot {
            entries = gitFilter.filter(entries, snapshot: snapshot, watchedPaths: watchedPaths)
        }
        sort()
    }
    public mutating func sort() {
        let sizes = directorySizes
        let key = sortKey
        let ascending = sortAscending
        entries.sort { a, b in
            if a.isParent != b.isParent { return a.isParent }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch key {
            case "size" where (sizes[a.url] ?? a.size) != (sizes[b.url] ?? b.size):
                order = (sizes[a.url] ?? a.size) < (sizes[b.url] ?? b.size) ? .orderedAscending : .orderedDescending
            case "modified" where a.modified != b.modified:
                order =
                    (a.modified ?? .distantPast) < (b.modified ?? .distantPast) ? .orderedAscending : .orderedDescending
            default: order = a.name.localizedStandardCompare(b.name)
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }
}
