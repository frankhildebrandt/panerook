import Foundation

public struct VisitedGitRepository: Codable, Equatable, Sendable {
    public let commonDirectory: URL
    public let lastVisitedWorktree: URL
    public let worktrees: [GitWorktree]
    public let lastVisitedAt: Date

    public init(commonDirectory: URL, lastVisitedWorktree: URL, worktrees: [GitWorktree], lastVisitedAt: Date) {
        self.commonDirectory = commonDirectory
        self.lastVisitedWorktree = lastVisitedWorktree
        self.worktrees = worktrees
        self.lastVisitedAt = lastVisitedAt
    }
}

public enum GitRepositoryStoreError: LocalizedError {
    case invalidPreferences, invalidRepository

    public var errorDescription: String? {
        switch self {
        case .invalidPreferences:
            return "Die gespeicherten Git-Repositories sind ungültig oder stammen aus einer neueren Version. Sie wurden nicht verändert."
        case .invalidRepository:
            return "Das Git-Repository enthält ungültige lokale Pfade."
        }
    }
}

/// Shared by both panels. Call from one serial context, normally the main queue.
/// Missing repositories are retained; reading this list never opens Git or drops
/// paths just because a volume is currently unavailable.
public final class GitRepositoryStore {
    private struct Archive: Codable {
        let version: Int
        let repositories: [VisitedGitRepository]
    }

    private let defaults: UserDefaults
    private let key = "PaneRook.visitedGitRepositories"
    private let limit = 100

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func repositories() throws -> [VisitedGitRepository] {
        guard let object = defaults.object(forKey: key) else { return [] }
        guard let data = object as? Data,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { throw GitRepositoryStoreError.invalidPreferences }
        do {
            // Prefer the most recent snapshot if older data contains aliases or duplicates.
            var unique: [String: VisitedGitRepository] = [:]
            for item in archive.repositories {
                // Persisted visits were canonicalized when recorded. Keep reads
                // purely lexical so an offline mount cannot block a menu.
                let value = try normalized(item, resolveSymlinks: false)
                if let previous = unique[value.commonDirectory.path], previous.lastVisitedAt >= value.lastVisitedAt { continue }
                unique[value.commonDirectory.path] = value
            }
            return Array(sorted(Array(unique.values)).prefix(limit))
        } catch {
            throw GitRepositoryStoreError.invalidPreferences
        }
    }

    /// Reader snapshots already contain canonical paths; their callers can skip
    /// filesystem resolution when persisting on the UI thread.
    public func record(_ info: GitRepositoryInfo, at date: Date = Date(), canonicalizePaths: Bool = true) throws {
        var values = try repositories()
        let value = try normalized(VisitedGitRepository(commonDirectory: info.commonDirectory,
            lastVisitedWorktree: info.worktreeRoot, worktrees: info.worktrees, lastVisitedAt: date),
            resolveSymlinks: canonicalizePaths)
        values.removeAll { $0.commonDirectory.path == value.commonDirectory.path }
        values.append(value)
        try save(values)
    }

    /// Refreshes known worktrees without making a background refresh count as a visit.
    public func update(_ info: GitRepositoryInfo, canonicalizePaths: Bool = true) throws {
        var values = try repositories()
        let commonDirectory = try canonical(info.commonDirectory, resolveSymlinks: canonicalizePaths)
        guard let index = values.firstIndex(where: { $0.commonDirectory.path == commonDirectory.path }) else { return }
        let previous = values[index]
        values[index] = try normalized(VisitedGitRepository(commonDirectory: commonDirectory,
            lastVisitedWorktree: previous.lastVisitedWorktree, worktrees: info.worktrees,
            lastVisitedAt: previous.lastVisitedAt), resolveSymlinks: canonicalizePaths)
        try save(values)
    }

    public func remove(commonDirectory: URL, canonicalizePaths: Bool = true) throws {
        var values = try repositories()
        let directory = try canonical(commonDirectory, resolveSymlinks: canonicalizePaths)
        values.removeAll { $0.commonDirectory.path == directory.path }
        try save(values)
    }

    private func save(_ values: [VisitedGitRepository]) throws {
        let archive = Archive(version: 1, repositories: Array(sorted(values).prefix(limit)))
        defaults.set(try JSONEncoder().encode(archive), forKey: key)
    }

    private func sorted(_ values: [VisitedGitRepository]) -> [VisitedGitRepository] {
        values.sorted {
            $0.lastVisitedAt == $1.lastVisitedAt
                ? $0.commonDirectory.path < $1.commonDirectory.path
                : $0.lastVisitedAt > $1.lastVisitedAt
        }
    }

    private func normalized(_ value: VisitedGitRepository, resolveSymlinks: Bool = true) throws -> VisitedGitRepository {
        guard value.lastVisitedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw GitRepositoryStoreError.invalidRepository
        }
        var seen = Set<String>()
        var worktrees: [GitWorktree] = []
        for worktree in value.worktrees {
            let url = try canonical(worktree.url, resolveSymlinks: resolveSymlinks)
            guard worktree.branch.map({ !$0.isEmpty && !$0.contains("\0") }) ?? true else {
                throw GitRepositoryStoreError.invalidRepository
            }
            if seen.insert(url.path).inserted {
                worktrees.append(GitWorktree(url: url, branch: worktree.branch, isBare: worktree.isBare,
                    isPrunable: worktree.isPrunable, isLocked: worktree.isLocked))
            }
        }
        return VisitedGitRepository(commonDirectory: try canonical(value.commonDirectory, resolveSymlinks: resolveSymlinks),
            lastVisitedWorktree: try canonical(value.lastVisitedWorktree, resolveSymlinks: resolveSymlinks), worktrees: worktrees,
            lastVisitedAt: value.lastVisitedAt)
    }

    private func canonical(_ url: URL, resolveSymlinks: Bool = true) throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, url.path.hasPrefix("/"),
              !url.path.contains("\0"), !url.absoluteString.lowercased().contains("%00") else {
            throw GitRepositoryStoreError.invalidRepository
        }
        let path = (resolveSymlinks ? url.resolvingSymlinksInPath() : url).standardizedFileURL.path
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
