import Foundation

public struct GitWorktree: Codable, Equatable, Sendable {
    public let url: URL
    public let branch: String?
    public let isBare: Bool
    public let isPrunable: Bool
    public let isLocked: Bool

    public init(url: URL, branch: String?, isBare: Bool = false, isPrunable: Bool = false, isLocked: Bool = false) {
        self.url = url
        self.branch = branch
        self.isBare = isBare
        self.isPrunable = isPrunable
        self.isLocked = isLocked
    }

    /// Porcelain attributes are NUL-delimited; an empty attribute ends a worktree.
    static func parseList(_ data: Data) -> [Self]? {
        guard data.count >= 2, data.suffix(2).allSatisfy({ $0 == 0 }) else { return nil }
        var worktrees: [Self] = []
        var url: URL?
        var branch: String?
        var bare = false, detached = false, prunable = false, locked = false
        for field in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            if field.isEmpty {
                guard let path = url, bare || detached || branch != nil else { return nil }
                worktrees.append(Self(url: path, branch: branch, isBare: bare, isPrunable: prunable, isLocked: locked))
                url = nil; branch = nil
                bare = false; detached = false; prunable = false; locked = false
                continue
            }
            guard let attribute = String(data: Data(field), encoding: .utf8) else { return nil }
            if attribute.hasPrefix("worktree ") {
                guard url == nil else { return nil }
                let path = String(attribute.dropFirst("worktree ".count))
                guard path.hasPrefix("/") else { return nil }
                url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            } else {
                guard url != nil else { return nil }
                if attribute.hasPrefix("branch ") {
                    let ref = String(attribute.dropFirst("branch ".count))
                    guard ref.hasPrefix("refs/heads/"), ref.count > "refs/heads/".count, branch == nil else { return nil }
                    branch = String(ref.dropFirst("refs/heads/".count))
                } else if attribute == "bare" { bare = true }
                else if attribute == "detached" { detached = true }
                else if attribute == "prunable" || attribute.hasPrefix("prunable ") { prunable = true }
                else if attribute == "locked" || attribute.hasPrefix("locked ") { locked = true }
                // HEAD and future attributes do not affect navigation.
            }
        }
        guard url == nil, !worktrees.isEmpty else { return nil }
        return worktrees
    }
}

public struct GitRepositoryInfo: Equatable, Sendable {
    public let commonDirectory: URL
    public let worktreeRoot: URL
    public let worktrees: [GitWorktree]

    public init(commonDirectory: URL, worktreeRoot: URL, worktrees: [GitWorktree]) {
        self.commonDirectory = commonDirectory
        self.worktreeRoot = worktreeRoot
        self.worktrees = worktrees
    }
}

/// Discovers the working tree containing a visited directory and all registered siblings.
/// Calls are synchronous, serial per reader, and intended for a background queue.
public final class GitRepositoryReader: @unchecked Sendable {
    private let process: GitReadOnlyProcess

    public convenience init() { self.init(timeout: 5, outputLimit: 4 * 1024 * 1024) }
    init(timeout: TimeInterval, outputLimit: Int) {
        process = GitReadOnlyProcess(timeout: timeout, outputLimit: outputLimit)
    }

    public var isCancelled: Bool { process.isCancelled }
    public func cancel() { process.cancel() }

    public func repository(containing directory: URL) -> GitRepositoryInfo? {
        guard directory.isFileURL, !isCancelled,
              let rootData = process.run(["rev-parse", "--path-format=absolute", "--show-toplevel"], in: directory),
              let root = Self.path(from: rootData),
              let commonData = process.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory),
              let common = Self.path(from: commonData),
              let listData = process.run(["worktree", "list", "--porcelain", "-z"], in: directory),
              let worktrees = GitWorktree.parseList(listData),
              worktrees.contains(where: { $0.url == root && !$0.isBare && !$0.isPrunable }),
              !isCancelled else { return nil }
        return GitRepositoryInfo(commonDirectory: common, worktreeRoot: root, worktrees: worktrees)
    }

    private static func path(from data: Data) -> URL? {
        // Remove the command's single trailing LF, preserving newlines in filenames.
        guard data.last == 10, let path = String(data: data.dropLast(), encoding: .utf8),
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }
}
