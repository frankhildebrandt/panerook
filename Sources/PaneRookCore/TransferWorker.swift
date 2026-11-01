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
    private var entries: [String: Entry] = [:]
    private var finished = Set<String>()
    private var totalItems = 0
    private var completedItems = 0
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0

    init(plan: TransferPlan, cancellation: TransferCancellation,
         progress: @escaping (OperationProgress) -> Void) {
        self.plan = plan; self.cancellation = cancellation; self.progress = progress
    }

    func run() throws {
        try cancellation.check()
        // A queued plan may be executed much later than its input dialog.
        // Revalidate all destinations before touching the first source.
        for item in plan.items { try requireAvailable(item.destination) }
        for item in plan.items { try scan(item.source) }
        report()
        for item in plan.items {
            // A panelized selection can include both a folder and one of its files.
            // Each top-level transfer copies its own occurrence of that file.
            finished.removeAll(keepingCapacity: true)
            try cancellation.check()
            try requireAvailable(item.destination)
            if plan.kind == .move {
                if renamex_np(item.source.path, item.destination.path, UInt32(RENAME_EXCL)) == 0 {
                    finishTree(item.source)
                    continue
                }
                let code = errno
                guard code == EXDEV else { throw fileError(code, path: item.destination.path) }
            }
            try copyStaged(item)
        }
        report()
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

    private func copyStaged(_ item: TransferPlan.Item) throws {
        let staging = item.destination.deletingLastPathComponent()
            .appendingPathComponent(".panerook-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        // This private container is always ours; the real destination never needs
        // deleting during error cleanup, even if somebody creates it meanwhile.
        defer { try? FileManager.default.removeItem(at: staging) }
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
        if renamex_np(output.path, item.destination.path, UInt32(RENAME_EXCL)) != 0 {
            throw fileError(errno, path: item.destination.path)
        }
        // Treat commit + source removal as one move step. Cancellation is checked
        // before commit and before the next item; it cannot delete an uncopied source.
        if plan.kind == .move { try FileManager.default.removeItem(at: item.source) }
        finishTree(item.source)
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
