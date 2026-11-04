import Foundation
import Darwin

// Deliberately independent of Core: Remote remains a UI-free domain target.
public enum RemoteConflictAction: String, Sendable { case skip, keepBoth, replace, merge }
public typealias RemoteConflictResolver = (RemoteTransferConflict) throws -> RemoteConflictAction
public struct RemoteTransferConflict: Sendable {
    public let source: String
    public let destination: String
    public let sourceEntry: RemoteEntry
    public let destinationEntry: RemoteEntry
    public let allowedActions: [RemoteConflictAction]
}

/// A job-scoped resolver is passed through every recursive operation. A false
/// result means skipped content; callers must never delete that move source.
final class ResolvedRemoteTransfer {
    let resolve: RemoteConflictResolver
    let token: RemoteCancellation
    let fm = FileManager.default
    init(resolve: @escaping RemoteConflictResolver, token: RemoteCancellation) { self.resolve = resolve; self.token = token }

    private func decision(source: String, target: String, entry: RemoteEntry, existing: RemoteEntry,
                          same: Bool = false) throws -> RemoteConflictAction {
        var allowed: [RemoteConflictAction] = [.skip, .keepBoth]
        if !same && !existing.isSymbolicLink {
            allowed.append(.replace)
            if entry.isDirectory && existing.isDirectory { allowed.append(.merge) }
        }
        let action = try resolve(.init(source: source, destination: target, sourceEntry: entry,
                                       destinationEntry: existing, allowedActions: allowed))
        try token.check()
        guard allowed.contains(action) else { throw RemoteError.process("Diese Konfliktentscheidung ist hier nicht verfügbar.") }
        return action
    }
    private func validate(_ entry: RemoteEntry) throws {
        try token.check()
        guard RemoteFileSystem.validName(entry.name) else { throw RemoteError.invalidPath }
        guard !entry.isSymbolicLink else { throw RemoteError.symbolicLink }
        guard entry.isDirectory || entry.isRegularFile else { throw RemoteError.specialFile }
    }
    private func existing(_ fs: RemoteFileSystem, _ path: String) throws -> RemoteEntry? {
        try fs.list((path as NSString).deletingLastPathComponent, cancellation: token).first { $0.name == (path as NSString).lastPathComponent }
    }
    private func unique(_ name: String, number: Int) -> String {
        let ext = (name as NSString).pathExtension
        return (ext.isEmpty ? name : (name as NSString).deletingPathExtension) + " (\(number))" + (ext.isEmpty ? "" : "." + ext)
    }
    private func remoteName(_ fs: RemoteFileSystem, _ path: String) throws -> String {
        var result = path, number = 2
        while try existing(fs, result) != nil {
            try token.check()
            result = try RemoteFileSystem.normalizedPath(unique((path as NSString).lastPathComponent, number: number), relativeTo: (path as NSString).deletingLastPathComponent)
            number += 1
        }
        return result
    }
    private func localName(_ url: URL) throws -> URL {
        var result = url, number = 2
        while try RemoteLocalStamp.read(result) != nil {
            try token.check()
            result = url.deletingLastPathComponent().appendingPathComponent(unique(url.lastPathComponent, number: number)); number += 1
        }
        return result
    }

    @discardableResult func download(_ fs: RemoteFileSystem, entry: RemoteEntry, directory: String,
                                    destination: URL, moving: Bool, depth: Int = 0) throws -> Bool {
        try validate(entry)
        guard depth < 256 else { throw RemoteError.invalidPath }
        let sourcePath = try RemoteFileSystem.normalizedPath(entry.name, relativeTo: directory)
        guard let currentSource = try fs.list(directory, cancellation: token).first(where: { $0.name == entry.name }),
              !currentSource.isSymbolicLink, currentSource.isDirectory == entry.isDirectory else { throw RemoteError.sourceChanged }
        let snapshot = moving ? try fs.captureTransferSnapshot(entry, from: directory, cancellation: token) : nil
        var target = destination
        var replacement: [String: RemoteLocalStamp]?
        if let stamp = try RemoteLocalStamp.read(target) {
            let captured = try RemoteLocalStamp.tree(target, token: token)
            let action = try decision(source: fs.connection.displayName + sourcePath, target: target.path,
                                      entry: entry, existing: stamp.entry(name: target.lastPathComponent))
            if action == .skip { return false }
            if action == .keepBoth { target = try localName(target) }
            else {
                guard try RemoteLocalStamp.tree(target, token: token) == captured else { throw RemoteError.targetChanged }
                if action == .merge {
                    var complete = true
                    for child in try fs.list(sourcePath, cancellation: token) {
                        guard try RemoteLocalStamp.read(target)?.identity == stamp.identity else { throw RemoteError.targetChanged }
                        if try !download(fs, entry: child, directory: sourcePath, destination: target.appendingPathComponent(child.name), moving: moving, depth: depth + 1) { complete = false }
                    }
                    if moving && complete {
                        guard try fs.list(sourcePath, cancellation: token).isEmpty else { throw RemoteError.sourceChanged }
                        try fs.transport.remove(sourcePath, directory: true, token: token)
                    }
                    return complete
                }
                replacement = captured
            }
        }
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let parentStamp = try RemoteLocalStamp.read(parent), parentStamp.directory else { throw RemoteError.invalidPath }
        let staging = parent.appendingPathComponent(".PaneRookTransfer-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveStaging = false
        defer { if !preserveStaging { RemoteLocalStamp.cleanup(staging) } }
        let output = staging.appendingPathComponent("content")
        try fs.downloadContent(entry, path: sourcePath, to: output, token: token, depth: depth)
        try token.check()
        guard try RemoteLocalStamp.read(parent)?.identity == parentStamp.identity,
              target.deletingLastPathComponent().resolvingSymlinksInPath() == parent else { throw RemoteError.targetChanged }
        if let replacement {
            guard try RemoteLocalStamp.tree(target, token: token) == replacement else { throw RemoteError.targetChanged }
        }
        let publishedIdentity = try RemoteLocalStamp.read(output)?.identity
        guard renamex_np(output.path, target.path, UInt32(replacement == nil ? RENAME_EXCL : RENAME_SWAP)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if let replacement {
            do {
                guard try RemoteLocalStamp.sameDisplacedTree(RemoteLocalStamp.tree(output, token: .init()), replacement) else { throw RemoteError.targetChanged }
            } catch {
                if (try? RemoteLocalStamp.read(target))?.identity == publishedIdentity,
                   renamex_np(output.path, target.path, UInt32(RENAME_SWAP)) == 0 { throw error }
                preserveStaging = true
                throw RemoteError.process("Das Ziel wurde gleichzeitig geändert. Der verdrängte Eintrag bleibt gesichert unter \(output.path). Bitte prüfen.")
            }
        }
        if let snapshot { try fs.removeTransferredSnapshot(snapshot, from: directory, cancellation: token) }
        return true
    }

    @discardableResult func upload(_ fs: RemoteFileSystem, source: URL, path: String, moving: Bool, depth: Int = 0) throws -> Bool {
        let snapshot = try LocalTransferSnapshot.capture(source, cancellation: token)
        let entry = RemoteEntry(name: source.lastPathComponent, isDirectory: snapshot.directory, size: Int64(snapshot.size), modified: snapshot.modified)
        try validate(entry)
        guard depth < 256 else { throw RemoteError.invalidPath }
        var target = path
        var replacement: RemoteTransferSnapshot?
        if let current = try existing(fs, target) {
            let captured = current.isSymbolicLink ? nil : try fs.captureTransferSnapshot(current, from: (target as NSString).deletingLastPathComponent, cancellation: token)
            let action = try decision(source: source.path, target: fs.connection.displayName + target, entry: entry, existing: current)
            if action == .skip { return false }
            if action == .keepBoth { target = try remoteName(fs, target) }
            else {
                guard let captured, try fs.captureTransferSnapshot(current, from: (target as NSString).deletingLastPathComponent, cancellation: token) == captured else { throw RemoteError.targetChanged }
                if action == .merge {
                    var complete = true
                    for child in snapshot.children {
                        guard let currentTarget = try existing(fs, target), currentTarget.isDirectory, !currentTarget.isSymbolicLink else { throw RemoteError.targetChanged }
                        if try !upload(fs, source: source.appendingPathComponent(child.name), path: RemoteFileSystem.normalizedPath(child.name, relativeTo: target), moving: moving, depth: depth + 1) { complete = false }
                    }
                    if moving && complete {
                        guard try fm.contentsOfDirectory(atPath: source.path).isEmpty else { throw RemoteError.sourceChanged }
                        guard try RemoteLocalStamp.read(source)?.identity == "\(snapshot.device):\(snapshot.inode)" else { throw RemoteError.sourceChanged }
                        guard rmdir(source.path) == 0 else { throw RemoteError.sourceChanged }
                    }
                    return complete
                }
                replacement = captured
            }
        }
        if let replacement { try replaceRemote(fs, source: source, target: target, captured: replacement, sourceSnapshot: snapshot) }
        else { try fs.uploadContent(source, path: target, token: token, depth: depth) }
        if moving {
            guard try LocalTransferSnapshot.capture(source, cancellation: token) == snapshot else { throw RemoteError.sourceChanged }
            try snapshot.remove(source, cancellation: token)
        }
        return true
    }

    private func replaceRemote(_ fs: RemoteFileSystem, source: URL, target: String, captured: RemoteTransferSnapshot, sourceSnapshot: LocalTransferSnapshot) throws {
        let parent = (target as NSString).deletingLastPathComponent
        let staging = try RemoteFileSystem.normalizedPath(".panerook-transfer-" + UUID().uuidString, relativeTo: parent)
        let backup = try RemoteFileSystem.normalizedPath(".panerook-backup-" + UUID().uuidString, relativeTo: parent)
        // A private remote sibling receives the entire transfer before the old
        // target is moved aside. The backup survives any failed restoration.
        defer {
            let cleanup = RemoteCancellation()
            if let entry = try? fs.list(parent, cancellation: cleanup).first(where: { $0.name == (staging as NSString).lastPathComponent }) {
                try? fs.remove(entry, from: parent, cancellation: cleanup)
            }
        }
        try fs.uploadContent(source, path: staging, token: token, depth: 0)
        guard try LocalTransferSnapshot.capture(source, cancellation: token) == sourceSnapshot else { throw RemoteError.sourceChanged }
        guard try fs.captureTransferSnapshot(captured.entry, from: parent, cancellation: token) == captured else { throw RemoteError.targetChanged }
        try token.check()
        try fs.available(backup, token: token)
        var backupSnapshot: RemoteTransferSnapshot?
        do {
            try fs.transport.move(target, to: backup, token: token)
            try token.check()
            guard let old = try existing(fs, backup) else { throw RemoteError.targetChanged }
            let saved = try fs.captureTransferSnapshot(old, from: parent, cancellation: token)
            guard saved.children == captured.children,
                  saved.entry.isDirectory == captured.entry.isDirectory,
                  saved.entry.size == captured.entry.size, saved.entry.modified == captured.entry.modified else { throw RemoteError.targetChanged }
            backupSnapshot = saved
            try fs.available(target, token: token)
            try fs.transport.move(staging, to: target, token: token)
        } catch {
            let restore = RemoteCancellation()
            do {
                let saved = try fs.list(parent, cancellation: restore).contains { $0.name == (backup as NSString).lastPathComponent }
                if saved {
                    try fs.available(target, token: restore)
                    try fs.transport.move(backup, to: target, token: restore)
                }
            } catch {
                throw RemoteError.process("Ersetzung fehlgeschlagen. Das bisherige Ziel ist gesichert unter \(backup). Wiederherstellung nicht möglich: \(error.localizedDescription)")
            }
            throw error
        }
        let cleanup = RemoteCancellation()
        if let backupSnapshot {
            do { try fs.removeTransferredSnapshot(backupSnapshot, from: parent, cancellation: cleanup) }
            catch { throw RemoteError.process("Ziel übertragen; die alte Sicherung konnte nicht entfernt werden: \(backup). \(error.localizedDescription)") }
        }
    }

    @discardableResult func remote(_ source: RemoteFileSystem, entry: RemoteEntry, directory: String,
                                  destination: RemoteFileSystem, target: String, moving: Bool, depth: Int = 0) throws -> Bool {
        try validate(entry)
        guard depth < 256 else { throw RemoteError.invalidPath }
        let path = try RemoteFileSystem.normalizedPath(entry.name, relativeTo: directory)
        guard let currentSource = try source.list(directory, cancellation: token).first(where: { $0.name == entry.name }),
              !currentSource.isSymbolicLink, currentSource.isDirectory == entry.isDirectory else { throw RemoteError.sourceChanged }
        let sameEndpoint = source.sharesEndpoint(with: destination)
        let removingSource = moving && !(sameEndpoint && path == target)
        guard !sameEndpoint || !entry.isDirectory || !target.hasPrefix(path + "/") else { throw RemoteError.invalidPath }
        var output = target
        if sameEndpoint && path == target {
            let action = try decision(source: source.connection.displayName + path, target: destination.connection.displayName + target,
                                      entry: entry, existing: entry, same: true)
            if action == .skip { return false }
            output = try remoteName(destination, target)
        }
        let outputExists = try existing(destination, output) != nil
        if sameEndpoint && removingSource && !outputExists {
            try destination.available(output, token: token)
            try token.check()
            try destination.transport.move(path, to: output, token: token)
            return true
        }
        if let current = try existing(destination, output) {
            let capturedTarget = current.isSymbolicLink ? nil : try destination.captureTransferSnapshot(current, from: (output as NSString).deletingLastPathComponent, cancellation: token)
            let action = try decision(source: source.connection.displayName + path, target: destination.connection.displayName + output,
                                      entry: entry, existing: current, same: sameEndpoint && path.hasPrefix(output + "/"))
            if action == .skip { return false }
            if action == .keepBoth { output = try remoteName(destination, output) }
            else if action == .merge {
                guard let capturedTarget, try destination.captureTransferSnapshot(current, from: (output as NSString).deletingLastPathComponent, cancellation: token) == capturedTarget else { throw RemoteError.targetChanged }
                var complete = true
                for child in try source.list(path, cancellation: token) {
                    guard let targetEntry = try existing(destination, output), targetEntry.isDirectory, !targetEntry.isSymbolicLink else { throw RemoteError.targetChanged }
                    if try !remote(source, entry: child, directory: path, destination: destination,
                                   target: RemoteFileSystem.normalizedPath(child.name, relativeTo: output), moving: removingSource, depth: depth + 1) { complete = false }
                }
                if removingSource && complete {
                    guard try source.list(path, cancellation: token).isEmpty else { throw RemoteError.sourceChanged }
                    try source.transport.remove(path, directory: true, token: token)
                }
                return complete
            } else {
                // Root replacement was explicitly chosen; reuse that decision once,
                // but bind it to the target snapshot captured before the dialog.
                guard let capturedTarget, try destination.captureTransferSnapshot(current, from: (output as NSString).deletingLastPathComponent, cancellation: token) == capturedTarget else { throw RemoteError.targetChanged }
                return try stagedRemote(source, entry: entry, directory: directory, destination: destination, output: output, moving: removingSource, rootDecision: action, expectedTarget: capturedTarget)
            }
        }
        return try stagedRemote(source, entry: entry, directory: directory, destination: destination, output: output, moving: removingSource)
    }

    private func stagedRemote(_ source: RemoteFileSystem, entry: RemoteEntry, directory: String,
                              destination: RemoteFileSystem, output: String, moving: Bool,
                              rootDecision: RemoteConflictAction? = nil, expectedTarget: RemoteTransferSnapshot? = nil) throws -> Bool {
        let captured = moving ? try source.captureTransferSnapshot(entry, from: directory, cancellation: token) : nil
        let temporary = fm.temporaryDirectory.appendingPathComponent("PaneRookRemote-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let local = temporary.appendingPathComponent(entry.name)
        try source.download(entry, from: directory, to: local, cancellation: token)
        if let expectedTarget {
            guard try destination.captureTransferSnapshot(expectedTarget.entry, from: (output as NSString).deletingLastPathComponent, cancellation: token) == expectedTarget else { throw RemoteError.targetChanged }
        }
        let worker = ResolvedRemoteTransfer(resolve: { conflict in
            if let rootDecision, conflict.destination == destination.connection.displayName + output { return rootDecision }
            let relative = String(conflict.source.dropFirst(local.path.count))
            return try self.resolve(.init(source: source.connection.displayName + directory + "/" + entry.name + relative,
                                          destination: conflict.destination, sourceEntry: conflict.sourceEntry,
                                          destinationEntry: conflict.destinationEntry, allowedActions: conflict.allowedActions))
        }, token: token)
        let complete = try worker.upload(destination, source: local, path: output, moving: false)
        if complete, let captured { try source.removeTransferredSnapshot(captured, from: directory, cancellation: token) }
        return complete
    }
}

private struct RemoteLocalStamp: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    var identity: String { "\(device):\(inode)" }
    var directory: Bool { mode & S_IFMT == S_IFDIR }
    static func read(_ url: URL) throws -> Self? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(device: value.st_dev, inode: value.st_ino, mode: value.st_mode, size: value.st_size,
                    modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanos: value.st_mtimespec.tv_nsec,
                    changedSeconds: value.st_ctimespec.tv_sec, changedNanos: value.st_ctimespec.tv_nsec)
    }
    func entry(name: String) -> RemoteEntry {
        .init(name: name, isDirectory: directory, isSymbolicLink: mode & S_IFMT == S_IFLNK,
              size: size, modified: Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1e9))
    }
    static func sameDisplacedTree(_ actual: [String: Self], _ expected: [String: Self]) -> Bool {
        guard Set(actual.keys) == Set(expected.keys) else { return false }
        return actual.allSatisfy { path, stamp in
            guard let other = expected[path] else { return false }
            if path.isEmpty {
                return stamp.identity == other.identity && stamp.mode == other.mode && stamp.size == other.size
                    && stamp.modifiedSeconds == other.modifiedSeconds && stamp.modifiedNanos == other.modifiedNanos
            }
            return stamp == other
        }
    }
    static func cleanup(_ url: URL) {
        if let stamp = try? read(url), stamp.directory {
            _ = chmod(url.path, 0o700)
            for child in (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { cleanup(child) }
        }
        try? FileManager.default.removeItem(at: url)
    }
    static func tree(_ root: URL, token: RemoteCancellation) throws -> [String: Self] {
        var result: [String: Self] = [:]
        func visit(_ url: URL, relative: String, depth: Int) throws {
            try token.check()
            guard depth < 256, let stamp = try read(url) else { throw RemoteError.targetChanged }
            result[relative] = stamp
            if stamp.directory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent, depth: depth + 1)
                }
            }
        }
        try visit(root, relative: "", depth: 0)
        return result
    }
}
