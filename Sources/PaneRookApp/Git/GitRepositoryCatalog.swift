import Foundation
import PaneRookCore

/// Shared by both panels and all windows. Git runs on a worker; preferences change on main.
final class GitRepositoryCatalog {
    static let shared = GitRepositoryCatalog()
    private let store: GitRepositoryStore
    private let queue = DispatchQueue(label: "app.panerook.git-catalog", qos: .utility)
    private var reader: GitRepositoryReader?
    private(set) var refreshing = false
    private(set) var errorMessage: String?

    init(store: GitRepositoryStore = GitRepositoryStore()) { self.store = store }
    deinit { reader?.cancel() }

    func repositories() -> [VisitedGitRepository] {
        do {
            let repositories = try store.repositories()
            errorMessage = nil
            return repositories
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func record(_ repository: GitRepositoryInfo) {
        do { try store.record(repository, canonicalizePaths: false); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func remove(_ repository: VisitedGitRepository) throws {
        try store.remove(commonDirectory: repository.commonDirectory, canonicalizePaths: false)
    }

    /// Refresh remembered snapshots without changing visit order or reviving removed entries.
    func refresh() {
        guard !refreshing else { return }
        let repositories = repositories()
        guard !repositories.isEmpty else { return }
        let reader = GitRepositoryReader()
        self.reader = reader
        refreshing = true
        queue.async { [weak self] in
            for repository in repositories {
                guard !reader.isCancelled else { break }
                var seen = Set<URL>()
                let candidates = ([repository.lastVisitedWorktree]
                    + repository.worktrees.filter { !$0.isBare && !$0.isPrunable }.map(\.url))
                    .filter { seen.insert($0).inserted }
                for candidate in candidates {
                    guard !reader.isCancelled else { break }
                    guard let updated = reader.repository(containing: candidate),
                          updated.commonDirectory == repository.commonDirectory else { continue }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        do { try self.store.update(updated, canonicalizePaths: false); self.errorMessage = nil }
                        catch { self.errorMessage = error.localizedDescription }
                    }
                    break
                }
            }
            DispatchQueue.main.async { [weak self] in self?.refreshing = false; self?.reader = nil }
        }
    }
}
