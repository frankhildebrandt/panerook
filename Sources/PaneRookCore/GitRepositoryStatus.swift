import Foundation

/// A local snapshot of one working tree, including its already-known upstream state.
public struct GitRepositoryStatus: Equatable, Sendable {
    public let branch: String?
    public let stagedCount: Int
    public let modifiedCount: Int
    public let untrackedCount: Int
    public let conflictCount: Int
    public let aheadCount: Int
    public let behindCount: Int

    public var isClean: Bool {
        stagedCount == 0 && modifiedCount == 0 && untrackedCount == 0 && conflictCount == 0
    }

    public init(branch: String?, stagedCount: Int = 0, modifiedCount: Int = 0,
                untrackedCount: Int = 0, conflictCount: Int = 0,
                aheadCount: Int = 0, behindCount: Int = 0) {
        self.branch = branch
        self.stagedCount = stagedCount
        self.modifiedCount = modifiedCount
        self.untrackedCount = untrackedCount
        self.conflictCount = conflictCount
        self.aheadCount = aheadCount
        self.behindCount = behindCount
    }

    /// NUL records keep whitespace, newlines, and rename source paths out of parsing.
    static func parse(_ data: Data) -> Self? {
        guard data.last == 0 else { return nil }
        let records = data.split(separator: 0)
        var branch: String?
        var foundHead = false
        var staged = 0, modified = 0, untracked = 0, conflicts = 0, ahead = 0, behind = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let type = record.first else { return nil }
            if type == 35 { // Header: # branch.head / # branch.ab
                let header = String(decoding: record, as: UTF8.self)
                if header.hasPrefix("# branch.head ") {
                    let head = String(header.dropFirst("# branch.head ".count))
                    guard !head.isEmpty else { return nil }
                    foundHead = true
                    branch = head == "(detached)" ? nil : head
                } else if header.hasPrefix("# branch.ab ") {
                    let values = header.dropFirst("# branch.ab ".count).split(separator: " ")
                    guard values.count == 2, values[0].first == "+", values[1].first == "-",
                          let a = Int(values[0].dropFirst()), let b = Int(values[1].dropFirst()),
                          a >= 0, b >= 0 else { return nil }
                    ahead = a; behind = b
                }
            } else if type == 49 || type == 50 { // Ordinary entry or rename/copy.
                let fieldCount = type == 49 ? 9 : 10
                let fields = record.split(separator: 32, maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
                guard fields.count == fieldCount, fields[1].count == 2,
                      fields[2].count == 4, !fields.last!.isEmpty else { return nil }
                let xy = Array(fields[1])
                guard xy.allSatisfy({ Array(".MTADRCU".utf8).contains($0) }) else { return nil }
                if xy[0] != 46 { staged += 1 }
                // Submodule worktree changes can be represented in the submodule field.
                if xy[1] != 46 || fields[2].dropFirst(2).contains(where: { $0 != 46 }) { modified += 1 }
                if type == 50 {
                    guard index < records.count else { return nil }
                    index += 1 // The original filename is a separate NUL record.
                }
            } else if type == 117 { // Unmerged entry.
                let fields = record.split(separator: 32, maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11, fields[1].count == 2, !fields.last!.isEmpty else { return nil }
                conflicts += 1
            } else if type == 63 || type == 33 { // Untracked / ignored.
                guard record.count > 2, record[record.index(after: record.startIndex)] == 32 else { return nil }
                if type == 63 { untracked += 1 }
            } else {
                return nil
            }
        }
        guard foundHead else { return nil }
        return Self(branch: branch, stagedCount: staged, modifiedCount: modified,
                    untrackedCount: untracked, conflictCount: conflicts,
                    aheadCount: ahead, behindCount: behind)
    }
}

/// Synchronous reader for a background scan. Cancellation is permanent for this
/// instance, so a new listing should create a new reader. Calls are serial per reader.
public final class GitStatusReader: @unchecked Sendable {
    private let process: GitReadOnlyProcess

    public convenience init() { self.init(timeout: 5, outputLimit: 4 * 1024 * 1024) }
    init(timeout: TimeInterval, outputLimit: Int) {
        process = GitReadOnlyProcess(timeout: timeout, outputLimit: outputLimit)
    }

    public var isCancelled: Bool { process.isCancelled }
    public func cancel() { process.cancel() }

    public func status(for directory: URL) -> GitRepositoryStatus? {
        guard directory.isFileURL,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path),
              let data = process.run(["status", "--porcelain=v2", "--branch", "-z",
                                      "--untracked-files=all", "--ignore-submodules=none"], in: directory) else { return nil }
        return GitRepositoryStatus.parse(data)
    }
}
