import PaneRookTasks
import Foundation
import Darwin

public enum TransferError: LocalizedError {
    case cancelled
    public var errorDescription: String? { "Vorgang abgebrochen. Bereits abgeschlossene Einträge bleiben erhalten." }
}

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled { throw TransferError.cancelled } }
}

/// Uses copyfile for macOS metadata, sparse data and per-write progress. All state
/// except the cancellation token belongs to the single worker executing the plan.
final class TransferWorker {
    private struct Entry {
        let bytes: Int64
        let isDirectory: Bool
    }
    private let plan: TransferPlan
    private let cancellation: TransferCancellation
    private let progress: (OperationProgress) -> Void
    private let resolveConflict: ((TransferConflict) throws -> TransferConflictAction)?
    private var entries: [String: Entry] = [:]
    private var finished = Set<String>()
    private var totalItems = 0
    private var completedItems = 0
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0

    init(plan: TransferPlan, cancellation: TransferCancellation,
         progress: @escaping (OperationProgress) -> Void,
         resolveConflict: ((TransferConflict) throws -> TransferConflictAction)? = nil) {
        self.plan = plan; self.cancellation = cancellation; self.progress = progress
        self.resolveConflict = resolveConflict
    }

    func run() throws {
        try cancellation.check()
        if !plan.allowsConflicts {
            for item in plan.items { try requireAvailable(item.destination) }
        }
        for item in plan.items { try scan(item.source) }
        report()
        for item in plan.items {
            finished.removeAll(keepingCapacity: true)
            try transfer(item)
        }
        report()
    }

    private func transfer(_ item: TransferPlan.Item) throws {
        try cancellation.check()
        // Recheck path ancestry after waiting in the queue or a conflict dialog.
        _ = try TransferPlan(sources: [item.source], outputs: [item.destination], kind: plan.kind, allowsConflicts: true)
        let parent = item.destination.deletingLastPathComponent().resolvingSymlinksInPath()
        guard let parentStamp = try TransferStamp.read(parent), parentStamp.kind == .directory else {
            throw FileActionError.invalidDirectory(parent.path)
        }
        var target = item.destination
        var replacement: [String: TransferStamp]?
        if try TransferStamp.read(target) != nil {
            let conflict = try TransferConflict(source: item.source, destination: target)
            guard let resolveConflict else { throw FileActionError.collision(target.lastPathComponent) }
            // Capture before asking: changes while the dialog is open invalidate consent.
            let sourceBeforeDecision = try TransferStamp.read(item.source)
            let captured = try TransferStamp.tree(target, cancellation: cancellation)
            let action = try resolveConflict(conflict)
            try cancellation.check()
            guard conflict.allowedActions.contains(action) else { throw FileActionError.unsupportedConflict }
            if action == .skip { finishTree(item.source); return }
            guard try TransferStamp.read(item.source) == sourceBeforeDecision else { throw FileActionError.transferChanged }
            if action == .keepBoth { target = try TransferNaming.available(target) }
            else {
                guard try TransferStamp.tree(target, cancellation: cancellation) == captured else { throw FileActionError.transferChanged }
                if action == .merge {
                    let sourceStamp = try TransferStamp.read(item.source)
                    let targetStamp = try TransferStamp.read(target)
                    for child in try FileManager.default.contentsOfDirectory(at: item.source, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                        guard try TransferStamp.read(target)?.identity == targetStamp?.identity,
                              try TransferStamp.read(item.source)?.identity == sourceStamp?.identity else { throw FileActionError.transferChanged }
                        try transfer(.init(source: child, destination: target.appendingPathComponent(child.lastPathComponent)))
                    }
                    if plan.kind == .move {
                        // Skipped children and concurrently added files keep their source folder.
                        if try FileManager.default.contentsOfDirectory(atPath: item.source.path).isEmpty {
                            guard try TransferStamp.read(item.source)?.identity == sourceStamp?.identity else { throw FileActionError.transferChanged }
                            guard rmdir(item.source.path) == 0 else { throw fileError(errno, path: item.source.path) }
                        }
                    }
                    finish(item.source.path)
                    return
                }
                replacement = captured
            }
        }
        guard try TransferStamp.read(parent)?.identity == parentStamp.identity,
              item.destination.deletingLastPathComponent().resolvingSymlinksInPath() == parent else { throw FileActionError.transferChanged }
        let resolved = TransferPlan.Item(source: item.source, destination: target)
        // A self-move with “keep both” is a duplicate: the existing target is
        // also the source and must remain in place.
        let moving = plan.kind == .move && key(item.source.path) != key(item.destination.path)
        if moving && replacement == nil {
            if renamex_np(item.source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                finishTree(item.source); return
            }
            let code = errno
            guard code == EXDEV else { throw fileError(code, path: target.path) }
        }
        try copyStaged(resolved, replacement: replacement, parent: parent, parentIdentity: parentStamp.identity, moving: moving)
    }

    private func scan(_ root: URL) throws {
        var pending = [root]
        while let url = pending.popLast() {
            try cancellation.check()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let directory = type == .typeDirectory
            let bytes = type == .typeRegular ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
            entries[key(url.path)] = Entry(bytes: bytes, isDirectory: directory)
            totalBytes += bytes
            totalItems += 1
            progress(OperationProgress(currentPath: url.path))
            if directory {
                pending += try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: nil, options: [])
            }
        }
    }

    private func requireAvailable(_ destination: URL) throws {
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)) != nil {
            throw FileActionError.collision(destination.lastPathComponent)
        }
    }

    private func copyStaged(_ item: TransferPlan.Item, replacement: [String: TransferStamp]?,
                            parent: URL, parentIdentity: String, moving: Bool) throws {
        let sourceSnapshot = try TransferStamp.tree(item.source, cancellation: cancellation)
        let staging = parent.appendingPathComponent(".panerook-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // This private container is always ours; the real destination never needs
        // deleting during error cleanup, even if somebody creates it meanwhile.
        var preserveStaging = false
        defer { if !preserveStaging { TransferStamp.cleanup(staging) } }
        let output = staging.appendingPathComponent("content")
        guard let state = copyfile_state_alloc() else { throw fileError(ENOMEM, path: item.source.path) }
        defer { copyfile_state_free(state) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: copyfile_callback_t = { what, stage, state, source, _, context in
            guard let context else { return COPYFILE_QUIT }
            let worker = Unmanaged<TransferWorker>.fromOpaque(context).takeUnretainedValue()
            return worker.handle(what: what, stage: stage, state: state,
                path: source.map { String(cString: $0) })
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context)
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        var preserveSetID: UInt32 = 1
        copyfile_state_set(state, UInt32(COPYFILE_STATE_PRESERVE_SUID), &preserveSetID)
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_DATA_SPARSE)
        let status = copyfile(item.source.path, output.path, state, flags)
        let code = errno
        try cancellation.check()
        guard status == 0 else { throw fileError(code, path: item.source.path) }
        guard try TransferStamp.tree(item.source, cancellation: cancellation) == sourceSnapshot,
              try TransferStamp.read(parent)?.identity == parentIdentity,
              item.destination.deletingLastPathComponent().resolvingSymlinksInPath() == parent else { throw FileActionError.transferChanged }
        if let replacement {
            guard try TransferStamp.tree(item.destination, cancellation: cancellation) == replacement else { throw FileActionError.transferChanged }
            // Exchange publishes the complete new tree atomically and keeps the old
            // entry inside our staging container until commit has succeeded.
            let publishedIdentity = try TransferStamp.read(output)?.identity
            if renamex_np(output.path, item.destination.path, UInt32(RENAME_SWAP)) != 0 {
                throw fileError(errno, path: item.destination.path)
            }
            do {
                // Also inspect the displaced entry: a concurrent rename between
                // the final check and exchange must not discard an unseen target.
                let displaced = try TransferStamp.tree(output, cancellation: .init())
                guard TransferStamp.sameDisplacedTree(displaced, replacement) else { throw FileActionError.transferChanged }
            } catch {
                if (try? TransferStamp.read(item.destination))?.identity == publishedIdentity,
                   renamex_np(output.path, item.destination.path, UInt32(RENAME_SWAP)) == 0 { throw error }
                preserveStaging = true
                throw NSError(domain: "PaneRookTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Das Ziel wurde gleichzeitig geändert. Der verdrängte Eintrag bleibt gesichert unter \(output.path). Bitte beide Ziele prüfen."])
            }
        } else if renamex_np(output.path, item.destination.path, UInt32(RENAME_EXCL)) != 0 {
            throw fileError(errno, path: item.destination.path)
        }
        if moving {
            guard try TransferStamp.tree(item.source, cancellation: .init()) == sourceSnapshot else { throw FileActionError.transferChanged }
            try removeSource(item.source, snapshot: sourceSnapshot, relative: "")
        }
        finishTree(item.source)
    }

    private func removeSource(_ url: URL, snapshot: [String: TransferStamp], relative: String) throws {
        guard let expected = snapshot[relative], try TransferStamp.read(url) == expected else { throw FileActionError.transferChanged }
        if expected.kind == .directory {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try removeSource(child, snapshot: snapshot, relative: relative + "/" + child.lastPathComponent)
            }
            guard try TransferStamp.read(url)?.identity == expected.identity else { throw FileActionError.transferChanged }
        }
        let result = expected.kind == .directory ? rmdir(url.path) : unlink(url.path)
        guard result == 0 else { throw fileError(errno, path: url.path) }
    }

    private func handle(what: Int32, stage: Int32, state: copyfile_state_t?, path: String?) -> Int32 {
        if cancellation.isCancelled { return COPYFILE_QUIT }
        if stage == COPYFILE_ERR { return COPYFILE_QUIT }
        if let path {
            if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS, let state {
                var bytes: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes)
                report(path: path, currentBytes: Int64(bytes))
            } else if stage == COPYFILE_START && (what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR) {
                report(path: path)
            } else if stage == COPYFILE_FINISH &&
                        (what == COPYFILE_RECURSE_FILE || what == COPYFILE_RECURSE_DIR_CLEANUP) {
                finish(path)
            }
        }
        return cancellation.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
    }

    private func finish(_ path: String) {
        let path = key(path)
        guard let entry = entries[path], finished.insert(path).inserted else { return }
        completedBytes += entry.bytes
        completedItems += 1
        report(path: path, currentBytes: entry.bytes, includeCurrentBytes: false)
    }

    private func finishTree(_ root: URL) {
        let rootPath = key(root.path)
        for path in entries.keys where path == rootPath || path.hasPrefix(rootPath + "/") {
            finish(path)
        }
    }

    private func report(path: String? = nil, currentBytes: Int64 = 0, includeCurrentBytes: Bool = true) {
        let entry = path.flatMap { entries[key($0)] }
        let bytes = min(currentBytes, entry?.bytes ?? currentBytes)
        progress(OperationProgress(completedItems: completedItems, totalItems: totalItems,
            completedBytes: completedBytes + (includeCurrentBytes ? bytes : 0), totalBytes: totalBytes,
            currentPath: path, currentFileBytes: bytes,
            currentFileTotalBytes: entry?.isDirectory == false ? entry?.bytes : nil))
    }

    /// contentsOfDirectory may return /private/var URLs even when its input uses
    /// /var. Resolve ancestors consistently, while retaining symlinks themselves.
    private func key(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private func fileError(_ code: Int32, path: String) -> Error {
        if code == EEXIST { return FileActionError.collision((path as NSString).lastPathComponent) }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
