import Foundation
import Darwin

public struct GitFileStatus: Equatable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let workTreeStatus: String
    public init(path: String, originalPath: String? = nil, indexStatus: String, workTreeStatus: String) {
        self.path = path; self.originalPath = originalPath
        self.indexStatus = indexStatus; self.workTreeStatus = workTreeStatus
    }
    public var isUntracked: Bool { indexStatus == "?" }
    public var isIgnored: Bool { indexStatus == "!" }
    public var isConflicted: Bool {
        indexStatus == "U" || workTreeStatus == "U"
            || ["AA", "DD"].contains(indexStatus + workTreeStatus)
    }
    public var isStaged: Bool { !isConflicted && ![".", " ", "?", "!"].contains(indexStatus) }
    public var isChanged: Bool { !isIgnored && (![".", " "].contains(indexStatus) || ![".", " "].contains(workTreeStatus)) }
}

public struct GitStash: Equatable, Sendable {
    public let id: String
    public let objectID: String
    public let subject: String
    public var reference: String { id }
    public var message: String { subject }
    public init(id: String, objectID: String, subject: String) {
        self.id = id; self.objectID = objectID; self.subject = subject
    }
}

public struct GitSnapshot: Sendable {
    public let root: URL
    public let branch: String
    public let head: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [GitFileStatus]
    public let stashes: [GitStash]
    public let operation: String?
    public let trackedPaths: Set<String>
    public let stashedPaths: Set<String>
    public init(root: URL, branch: String, head: String? = nil, upstream: String? = nil,
                ahead: Int = 0, behind: Int = 0, files: [GitFileStatus] = [], stashes: [GitStash] = [],
                operation: String? = nil, trackedPaths: Set<String> = [], stashedPaths: Set<String> = []) {
        self.root = root; self.branch = branch; self.head = head; self.upstream = upstream
        self.ahead = ahead; self.behind = behind; self.files = files; self.stashes = stashes
        self.operation = operation; self.trackedPaths = trackedPaths; self.stashedPaths = stashedPaths
    }
}

public struct GitBranch: Equatable, Sendable {
    public let name: String
    public let current: Bool
    public let remote: Bool
    public init(name: String, current: Bool, remote: Bool) {
        self.name = name; self.current = current; self.remote = remote
    }
}

public struct GitCommit: Equatable, Sendable {
    public let id: String
    public let shortID: String
    public let subject: String
    public let author: String
    public let date: Date
    public init(id: String, shortID: String, subject: String, author: String, date: Date) {
        self.id = id; self.shortID = shortID; self.subject = subject; self.author = author; self.date = date
    }
}

public enum GitOperation: Sendable {
    case stage([String]), unstage([String]), commit(String)
    case switchBranch(String), createBranch(String), checkoutRevision(String)
    case stashSave(String), stashApply(String), stashPop(String), stashDrop(String)
    case fetch, pull, push, merge(String), deleteBranch(String), createTag(String)
}

public struct GitError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Synchronous Git operations. Callers run these off the main thread. Arguments are
/// passed directly, paths are literal, and inherited Git repository overrides are removed.
public struct GitRepository: Sendable {
    public let root: URL
    private init(root: URL) { self.root = root }
    public init(directory: URL) throws {
        guard let repository = try Self.discover(in: directory) else {
            throw GitError("Dieser Ordner gehört zu keinem Git-Repository.")
        }
        self = repository
    }
    public static func discover(in directory: URL) throws -> GitRepository? {
        let result = try execute(in: directory, arguments: ["rev-parse", "--show-toplevel"], acceptingFailure: true)
        guard result.status == 0 else {
            if result.error.contains("not a git repository") || result.error.contains("must be run in a work tree") {
                return nil
            }
            throw GitError(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let path = result.output.hasSuffix("\n") ? String(result.output.dropLast()) : result.output
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
    }
    public static func initialize(in directory: URL) throws -> GitRepository {
        _ = try execute(in: directory, arguments: ["init"])
        return try GitRepository(directory: directory)
    }

    public func snapshot() throws -> GitSnapshot {
        let output = try command(["status", "--porcelain=v2", "-z", "--branch", "--ignored=matching", "--untracked-files=all"])
        var head: String?, upstream: String?, branch = "HEAD", ahead = 0, behind = 0
        var files: [GitFileStatus] = []
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst(13)); head = value == "(initial)" ? nil : value
            } else if record.hasPrefix("# branch.head ") {
                branch = String(record.dropFirst(14))
            } else if record.hasPrefix("# branch.upstream ") {
                upstream = String(record.dropFirst(18))
            } else if record.hasPrefix("# branch.ab ") {
                let counts = record.dropFirst(12).split(separator: " ")
                if counts.count == 2 {
                    ahead = Int(counts[0].dropFirst()) ?? 0; behind = Int(counts[1].dropFirst()) ?? 0
                }
            } else if record.hasPrefix("? ") || record.hasPrefix("! ") {
                let flag = String(record.prefix(1))
                files.append(.init(path: String(record.dropFirst(2)), indexStatus: flag, workTreeStatus: flag))
            } else if record.hasPrefix("1 ") || record.hasPrefix("2 ") || record.hasPrefix("u ") {
                let isRename = record.hasPrefix("2 ")
                let fields = record.split(separator: " ", maxSplits: record.hasPrefix("u ") ? 10 : (isRename ? 9 : 8), omittingEmptySubsequences: false)
                guard fields.count >= 9, fields[1].count == 2 else { throw GitError("Ungültige Git-Statusausgabe.") }
                let xy = Array(fields[1])
                var original: String?
                if isRename {
                    guard index < records.count else { throw GitError("Unvollständiger Git-Umbenennungsstatus.") }
                    original = records[index]; index += 1
                }
                files.append(.init(path: String(fields.last!), originalPath: original,
                                   indexStatus: String(xy[0]), workTreeStatus: String(xy[1])))
            }
        }
        if branch == "(detached)" { branch = "HEAD · " + String((head ?? "").prefix(8)) }
        let tracked = Set(try command(["ls-files", "--cached", "-z"]).split(separator: "\0").map(String.init))
        let stashOutput = try command(["stash", "list", "-z", "--format=%gd%x00%H%x00%gs"])
        let stashFields = stashOutput.split(separator: "\0", omittingEmptySubsequences: false)
        var stashes: [GitStash] = []
        for offset in stride(from: 0, to: max(0, stashFields.count - 2), by: 3) {
            stashes.append(.init(id: String(stashFields[offset]), objectID: String(stashFields[offset + 1]), subject: String(stashFields[offset + 2])))
        }
        var stashedPaths = Set<String>()
        for stash in stashes {
            for endpoint in [stash.objectID, stash.objectID + "^2"] {
                let paths = try command(["diff", "--name-only", "--no-renames", "-z", stash.objectID + "^1", endpoint, "--"])
                stashedPaths.formUnion(paths.split(separator: "\0").map(String.init))
            }
            let untracked = try Self.execute(in: root, arguments: ["ls-tree", "-r", "--name-only", "-z", stash.objectID + "^3"], acceptingFailure: true)
            if untracked.status == 0 { stashedPaths.formUnion(untracked.output.split(separator: "\0").map(String.init)) }
        }
        var operation: String?
        for (marker, label) in [("MERGE_HEAD", "Merge"), ("rebase-merge", "Rebase"), ("rebase-apply", "Rebase"),
                                ("CHERRY_PICK_HEAD", "Cherry-pick"), ("REVERT_HEAD", "Revert"), ("BISECT_LOG", "Bisect")] {
            let path = try command(["rev-parse", "--git-path", marker]).trimmingCharacters(in: .newlines)
            let url = URL(fileURLWithPath: path, relativeTo: root)
            if FileManager.default.fileExists(atPath: url.path) { operation = label; break }
        }
        return .init(root: root, branch: branch, head: head, upstream: upstream, ahead: ahead, behind: behind,
                     files: files, stashes: stashes, operation: operation, trackedPaths: tracked, stashedPaths: stashedPaths)
    }

    public func branches() throws -> [GitBranch] {
        let output = try command(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(HEAD)%00%(symref)", "refs/heads/", "refs/remotes/"])
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[2].isEmpty else { return nil }
            let ref = String(parts[0]); let remote = ref.hasPrefix("refs/remotes/")
            return .init(name: String(ref.dropFirst(remote ? 13 : 11)), current: parts[1] == "*", remote: remote)
        }
    }
    public func tags() throws -> [String] {
        try command(["tag", "--list", "--sort=-creatordate"]).split(separator: "\n").map(String.init)
    }
    public func history(path: String? = nil, limit: Int = 200) throws -> [GitCommit] {
        guard try hasHEAD() else { return [] }
        var arguments = ["log", "-z", "--format=%H%x00%h%x00%s%x00%an%x00%at", "-n", String(max(1, min(2000, limit)))]
        if let path { arguments += ["--follow", "--", try checkedPath(path)] }
        let parts = try command(arguments).split(separator: "\0", omittingEmptySubsequences: false)
        return stride(from: 0, to: max(0, parts.count - 4), by: 5).map { offset in
            .init(id: String(parts[offset]), shortID: String(parts[offset + 1]), subject: String(parts[offset + 2]),
                  author: String(parts[offset + 3]), date: Date(timeIntervalSince1970: Double(parts[offset + 4]) ?? 0))
        }
    }
    public func diff(path: String? = nil, staged: Bool = false, revision: String? = nil) throws -> String {
        var arguments: [String]
        if let revision {
            arguments = ["show", "--format=fuller", "--first-parent", "--no-ext-diff", "--no-textconv", try resolvedCommit(revision)]
        } else {
            arguments = ["diff", "--no-ext-diff", "--no-textconv"]
            if staged { arguments.append("--cached") }
        }
        arguments.append("--")
        if let path { arguments.append(try checkedPath(path)) }
        return try command(arguments)
    }
    public func show(revision: String, path: String) throws -> String {
        let checked = try checkedPath(path)
        return try command(["show", "--no-ext-diff", "--no-textconv", try resolvedCommit(revision) + ":" + checked])
    }

    @discardableResult public func run(_ operation: GitOperation) throws -> String {
        var arguments: [String]
        var network = false
        switch operation {
        case .stage(let paths):
            arguments = ["add", "--"] + (try checkedPaths(paths))
        case .unstage(let paths):
            let checked = try checkedPaths(paths)
            arguments = try hasHEAD() ? ["restore", "--staged", "--"] + checked : ["rm", "--cached", "-r", "--"] + checked
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitError("Bitte eine Commit-Nachricht eingeben.") }
            arguments = ["commit", "-m", message]
        case .switchBranch(let name):
            try checkedBranch(name)
            let remote = try branches().contains { $0.name == name && $0.remote }
            arguments = ["switch"] + (remote ? ["--track"] : []) + ["--", name]
        case .createBranch(let name):
            try checkedBranch(name); arguments = ["switch", "-c", name]
        case .checkoutRevision(let revision):
            arguments = ["switch", "--detach", try resolvedCommit(revision)]
        case .stashSave(let message):
            arguments = ["stash", "push", "--include-untracked", "-m", message.isEmpty ? "PaneRook" : message]
        case .stashApply(let reference): arguments = ["stash", "apply", "--index", try checkedStash(reference)]
        case .stashPop(let reference): arguments = ["stash", "pop", "--index", try checkedStash(reference)]
        case .stashDrop(let reference): arguments = ["stash", "drop", try checkedStash(reference)]
        case .fetch: arguments = ["fetch", "--all", "--prune"]; network = true
        case .pull: arguments = ["pull", "--ff-only"]; network = true
        case .push: arguments = ["push"]; network = true
        case .merge(let revision): arguments = ["merge", "--no-edit", try resolvedCommit(revision)]
        case .deleteBranch(let name): try checkedBranch(name); arguments = ["branch", "-d", "--", name]
        case .createTag(let name):
            guard !name.hasPrefix("-"), !name.isEmpty else { throw GitError("Ungültiger Tagname.") }
            _ = try command(["check-ref-format", "refs/tags/" + name]); arguments = ["tag", "--", name]
        }
        let result = try Self.execute(in: root, arguments: arguments, timeout: network ? 120 : 60)
        return [result.output, result.error].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func command(_ arguments: [String]) throws -> String { try Self.execute(in: root, arguments: arguments).output }
    private func hasHEAD() throws -> Bool {
        try Self.execute(in: root, arguments: ["rev-parse", "--verify", "HEAD"], acceptingFailure: true).status == 0
    }
    private func resolvedCommit(_ revision: String) throws -> String {
        guard !revision.isEmpty, !revision.contains("\0") else { throw GitError("Ungültige Git-Version.") }
        return try command(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func checkedPath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw GitError("Ungültiger Repository-Pfad.") }
        return path
    }
    private func checkedPaths(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { throw GitError("Bitte Dateien auswählen.") }
        return try paths.map(checkedPath)
    }
    private func checkedBranch(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains("\0"), !name.hasPrefix("@{-") else { throw GitError("Ungültiger Branchname.") }
        _ = try command(["check-ref-format", "--branch", name])
    }
    private func checkedStash(_ reference: String) throws -> String {
        guard reference.range(of: #"^stash@\{[0-9]+\}$"#, options: .regularExpression) != nil else { throw GitError("Ungültiger Stash-Verweis.") }
        return reference
    }

    private struct Output { let output: String; let error: String; let status: Int32 }
    private static func execute(in directory: URL, arguments: [String], acceptingFailure: Bool = false,
                                timeout: TimeInterval = 30, limit: Int = 8 * 1024 * 1024) throws -> Output {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-git-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdoutURL = temporary.appendingPathComponent("stdout"), stderrURL = temporary.appendingPathComponent("stderr")
        for url in [stdoutURL, stderrURL] { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        // Limit literal pathspecs to commands that consume user-selected paths.
        // `stash -u` internally uses Git's :(top) pathspec when cleaning saved
        // untracked files, which a global literal flag would silently disable.
        let literalPaths = ["add", "restore", "rm", "log", "diff", "show"].contains(arguments.first ?? "")
        process.arguments = (literalPaths ? ["--literal-pathspecs"] : [])
            + ["-c", "color.ui=false", "-c", "core.quotepath=false", "-c", "core.pager=cat"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=15"
        environment["GIT_EDITOR"] = "/usr/bin/false"; environment["GIT_SEQUENCE_EDITOR"] = "/usr/bin/false"
        environment["GIT_OPTIONAL_LOCKS"] = "0"; environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var failure: String?
        while process.isRunning {
            let exceeded = [stdoutURL, stderrURL].contains {
                ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? NSNumber)?.intValue ?? 0 > limit
            }
            if exceeded || Date() > deadline {
                failure = exceeded ? "Die Git-Ausgabe überschreitet das Limit von 8 MiB." : "Git wurde nach einer Zeitüberschreitung beendet."
                process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        if let failure { throw GitError(failure) }
        func read(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw GitError("Die Git-Ausgabe überschreitet das Limit von 8 MiB.") }
            return String(decoding: data, as: UTF8.self)
        }
        let result = try Output(output: read(stdoutURL), error: read(stderrURL), status: process.terminationStatus)
        if result.status != 0 && !acceptingFailure {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message.isEmpty ? "Git ist mit Status \(result.status) fehlgeschlagen." : message)
        }
        return result
    }
}
