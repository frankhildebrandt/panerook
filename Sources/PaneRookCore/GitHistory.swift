import Foundation

/// A version in the first-parent timeline. File paths follow renames backwards,
/// so each entry can be read independently of the file's current name.
public struct GitHistoryEntry: Equatable, Sendable {
    public let commit: GitCommit
    public let path: String?
    public let originalPath: String?
    public let isDirectory: Bool

    public init(commit: GitCommit, path: String? = nil, originalPath: String? = nil, isDirectory: Bool = false) {
        self.commit = commit
        self.path = path
        self.originalPath = originalPath
        self.isDirectory = isDirectory
    }
}

extension GitRepository {
    /// A linear timeline makes older/newer navigation and merge patches agree.
    /// NUL separators preserve spaces, tabs and newlines in literal file names.
    public func historyEntries(path: String? = nil, isDirectory: Bool = false, limit: Int = 200) throws -> [GitHistoryEntry] {
        let checked = try path.map(checkedPath)
        guard try hasHEAD() else { return [] }
        var arguments = ["log", "-z", "--first-parent", "--format=%x00%H%x00%h%x00%s%x00%an%x00%at",
                         "-n", String(max(1, min(2000, limit)))]
        if let checked {
            arguments += isDirectory
                ? ["--no-follow", "--", checked]
                : ["--name-status", "--find-renames", "--follow", "--", checked]
        }
        let fields = try command(arguments).components(separatedBy: "\0")
        var entries: [GitHistoryEntry] = []
        var index = 0
        var currentPath = checked
        while index < fields.count {
            while index < fields.count, fields[index].isEmpty { index += 1 }
            guard index < fields.count else { break }
            guard index + 4 < fields.count, let timestamp = Double(fields[index + 4]) else {
                throw GitError("Ungültige Git-Verlaufsausgabe.")
            }
            let commit = GitCommit(id: fields[index], shortID: fields[index + 1], subject: fields[index + 2],
                                   author: fields[index + 3], date: Date(timeIntervalSince1970: timestamp))
            index += 5
            let entryPath = currentPath
            var originalPath: String?
            if checked != nil && !isDirectory {
                while index < fields.count, !fields[index].isEmpty {
                    // Git separates the pretty header from its first status with a newline.
                    let status = fields[index].trimmingCharacters(in: .newlines)
                    index += 1
                    guard index < fields.count, !fields[index].isEmpty else {
                        throw GitError("Unvollständige Git-Verlaufsausgabe.")
                    }
                    let source = fields[index]
                    index += 1
                    if status.hasPrefix("R") || status.hasPrefix("C") {
                        guard index < fields.count, !fields[index].isEmpty else {
                            throw GitError("Unvollständiger Git-Umbenennungsverlauf.")
                        }
                        let destination = fields[index]
                        index += 1
                        if destination == currentPath {
                            originalPath = source
                            currentPath = source
                        }
                    }
                }
            }
            entries.append(GitHistoryEntry(commit: commit, path: entryPath, originalPath: originalPath, isDirectory: isDirectory))
        }
        return entries
    }

    /// Include both rename endpoints so the patch retains its rename metadata.
    public func historyDiff(_ entry: GitHistoryEntry) throws -> String {
        var arguments = ["show", "--format=fuller", "--first-parent", "--find-renames", "--no-ext-diff", "--no-textconv",
                         try resolvedCommit(entry.commit.id), "--"]
        if let path = entry.path { arguments.append(try checkedPath(path)) }
        if let originalPath = entry.originalPath { arguments.append(try checkedPath(originalPath)) }
        return try command(arguments)
    }

    public func historyFile(_ entry: GitHistoryEntry) throws -> String {
        guard !entry.isDirectory else { throw GitError("Für Verzeichnisse bitte die Diff-Ansicht verwenden.") }
        guard let path = entry.path else { throw GitError("Für die Versionsvorschau bitte eine Datei auswählen.") }
        let content: String
        do {
            content = try show(revision: entry.commit.id, path: path)
        } catch {
            throw GitError("Die Datei ist in dieser Version nicht verfügbar.\n" + error.localizedDescription)
        }
        guard !content.contains("\0") else { throw GitError("Binärdateien können nicht als Text angezeigt werden.") }
        return content
    }
}
