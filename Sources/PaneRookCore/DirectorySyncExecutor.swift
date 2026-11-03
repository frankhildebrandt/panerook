import Foundation
import Darwin
import PaneRookTasks

/// Shares TransferCancellation, copyfile metadata/progress and the serial task queue contract
/// with ordinary transfers. Overwrites need their own staged, revalidated publication step.
final class SyncExecutor {
    let plan: DirectorySyncPlan
    let selected: Set<String>
    let cancellation: TransferCancellation
    let progress: (OperationProgress) -> Void
    var completedItems = 0
    var completedBytes: Int64 = 0
    var currentPath = ""
    var currentSize: Int64 = 0
    let totalBytes: Int64
    init(plan: DirectorySyncPlan, selected: Set<String>, cancellation: TransferCancellation,
         progress: @escaping (OperationProgress) -> Void) {
        self.plan = plan; self.selected = selected; self.cancellation = cancellation; self.progress = progress
        totalBytes = plan.transferBytes(selected: selected)
    }
    func run() throws {
        try cancellation.check()
        let allowed = plan.defaultSelection
        guard selected.isSubset(of: allowed) else { throw DirectorySyncError.invalidSelection("Unbekannte oder gesperrte Aktion") }
        let actions = plan.actions.filter { selected.contains($0.id) }
        let retainedParents = Set(plan.destinationInventory.items.keys.filter { !selected.contains($0) }.flatMap(syncParentPaths))
        let createdDirectories = Set(plan.actions.filter { $0.kind == .createDirectory }.map(\.id))
        for action in actions {
            if action.kind == .deleteDirectory {
                guard !retainedParents.contains(action.id) else {
                    throw DirectorySyncError.invalidSelection(action.id)
                }
            } else if !action.kind.isDeletion {
                for parent in syncParentPaths(action.id) where createdDirectories.contains(parent) {
                    guard selected.contains(parent) else { throw DirectorySyncError.invalidSelection(parent) }
                }
            }
        }
        let (source, target) = try SyncRoot.pair(plan.source, plan.destination)
        for (root, inventory) in [(source, plan.sourceInventory), (target, plan.destinationInventory)] {
            let current = try root.inventory(options: plan.options, cancellation: cancellation,
                maximumEntries: inventory.maximumEntries, maximumFileBytes: inventory.maximumFileBytes, progress: progress)
            guard current == inventory else { throw DirectorySyncError.changed(root.url.path) }
        }
        var targetItems = plan.destinationInventory.items
        let ordered = actions.sorted {
            func rank(_ item: DirectorySyncAction) -> Int { item.kind == .createDirectory ? 0 : item.kind.isDeletion ? 2 : 1 }
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            let ad = $0.id.split(separator: "/").count, bd = $1.id.split(separator: "/").count
            if ad != bd { return a == 2 ? ad > bd : ad < bd }
            return $0.id < $1.id
        }
        for action in ordered {
            try cancellation.check()
            currentPath = action.id; currentSize = action.bytes; report()
            // Reopen each root through a no-follow chain, detecting a root moved/replaced during the job.
            for (root, known) in [(source, plan.sourceInventory.root), (target, plan.destinationInventory.root)] {
                let reopened = try SyncRoot(root.url)
                guard try known.sameIdentity(as: reopened.rootSnapshot()) else { throw DirectorySyncError.changed(root.url.path) }
            }
            let parent = try target.parent(action.id, expected: targetItems); defer { close(parent) }
            let name = (action.id as NSString).lastPathComponent
            let before = try SyncRoot.snapshot(at: parent, name: name, cancellation: cancellation, maximumFileBytes: plan.destinationInventory.maximumFileBytes)
            let expected = plan.destinationInventory.items[action.id]
            if action.kind == .deleteDirectory {
                let directory = try tryDirectory(parent, name)
                defer { close(directory) }
                guard let before, let expected, before.sameIdentity(as: expected), try SyncRoot.names(directory, maximumEntries: 1).isEmpty else {
                    throw DirectorySyncError.changed(action.id)
                }
            } else if before != expected { throw DirectorySyncError.changed(action.id) }
            switch action.kind {
            case .createDirectory:
                guard mkdirat(parent, name, 0o755) == 0 else { throw syncPOSIX(action.id) }
                targetItems[action.id] = try SyncRoot.snapshot(at: parent, name: name, cancellation: cancellation, maximumFileBytes: 0)
            case .addFile, .updateFile:
                try copy(action, source: source, targetParent: parent, name: name, expected: expected) {
                    try self.validateLocation(source: source, target: target, parent: parent, path: action.id, expected: targetItems)
                }
                completedBytes += action.bytes
            case .deleteFile, .deleteDirectory:
                try validateLocation(source: source, target: target, parent: parent, path: action.id, expected: targetItems)
                try remove(action, parent: parent, name: name, expected: expected!)
                targetItems.removeValue(forKey: action.id)
            case .blocked: throw DirectorySyncError.invalidSelection(action.id)
            }
            completedItems += 1; report()
        }
    }
    private func validateLocation(source: SyncRoot, target: SyncRoot, parent: Int32, path: String, expected: [String: SyncSnapshot]) throws {
        for (root, known) in [(source, plan.sourceInventory.root), (target, plan.destinationInventory.root)] {
            let reopened = try SyncRoot(root.url)
            guard try known.sameIdentity(as: reopened.rootSnapshot()) else { throw DirectorySyncError.changed(root.url.path) }
        }
        let reopened = try target.parent(path, expected: expected)
        defer { close(reopened) }
        var original = stat(), current = stat()
        guard fstat(parent, &original) == 0, fstat(reopened, &current) == 0,
              SyncSnapshot(original, type: .directory).sameIdentity(as: SyncSnapshot(current, type: .directory)) else {
            throw DirectorySyncError.changed(path)
        }
    }
    private func remove(_ action: DirectorySyncAction, parent: Int32, name: String, expected: SyncSnapshot) throws {
        try cancellation.check()
        let holding = ".panerook-sync-delete-\(UUID().uuidString)"
        // Detach exactly one entry, then verify the detached object before permanent removal.
        // A racing replacement is restored without overwriting any newly created destination.
        guard renameatx_np(parent, name, parent, holding, UInt32(RENAME_EXCL)) == 0 else { throw syncPOSIX(action.id) }
        do {
            let captured = try SyncRoot.snapshot(at: parent, name: holding, cancellation: TransferCancellation(), maximumFileBytes: plan.destinationInventory.maximumFileBytes)
            guard action.kind == .deleteDirectory ? captured?.sameIdentity(as: expected) == true : Self.sameRelocatedFile(captured, expected) else {
                throw DirectorySyncError.changed(action.id)
            }
            // AT_REMOVEDIR only removes empty directories. Never recursively remove unpreviewed children.
            guard unlinkat(parent, holding, action.kind == .deleteDirectory ? AT_REMOVEDIR : 0) == 0 else { throw syncPOSIX(action.id) }
        } catch {
            guard renameatx_np(parent, holding, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                throw DirectorySyncError.changed("\(action.id) (erhaltener Eintrag: \(holding))")
            }
            throw error
        }
    }
    private func tryDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectorySyncError.changed(currentPath) }
        // names() owns only a duplicate. Close this descriptor at its caller instead.
        return fd
    }
    private func copy(_ action: DirectorySyncAction, source: SyncRoot, targetParent: Int32, name: String, expected: SyncSnapshot?, validateLocation: () throws -> Void) throws {
        let sourceParent = try source.parent(action.id, expected: plan.sourceInventory.items); defer { close(sourceParent) }
        let known = plan.sourceInventory.items[action.id]!
        guard try SyncRoot.snapshot(at: sourceParent, name: name, cancellation: cancellation, maximumFileBytes: plan.sourceInventory.maximumFileBytes) == known else {
            throw DirectorySyncError.changed(action.id)
        }
        let input = openat(sourceParent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw syncPOSIX(action.id) }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, SyncSnapshot(info, type: .file).sameIdentity(as: known), (info.st_mode & S_IFMT) == S_IFREG else {
            throw DirectorySyncError.changed(action.id)
        }
        let temporary = ".panerook-sync-\(UUID().uuidString)"
        let output = openat(targetParent, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw syncPOSIX(action.id) }
        var cleanTemporary = true
        defer { close(output); if cleanTemporary { unlinkat(targetParent, temporary, 0) } }
        guard let state = copyfile_state_alloc() else { throw syncPOSIX(action.id) }
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { _, stage, state, _, _, context in
            guard let context else { return COPYFILE_QUIT }
            let worker = Unmanaged<SyncExecutor>.fromOpaque(context).takeUnretainedValue()
            if worker.cancellation.isCancelled || stage == COPYFILE_ERR { return COPYFILE_QUIT }
            if let state {
                var bytes: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &bytes)
                worker.report(currentBytes: bytes)
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(self).toOpaque())
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        let status = fcopyfile(input, output, state, copyfile_flags_t(COPYFILE_ALL))
        try cancellation.check()
        guard status == 0 else { throw syncPOSIX(action.id) }
        try validateLocation()
        guard try source.snapshot(action.id, cancellation: cancellation, maximumFileBytes: plan.sourceInventory.maximumFileBytes) == known,
              let staged = try SyncRoot.snapshot(at: targetParent, name: temporary, cancellation: cancellation, maximumFileBytes: plan.sourceInventory.maximumFileBytes),
              staged.digest == known.digest, staged.size == known.size,
              try SyncRoot.snapshot(at: targetParent, name: name, cancellation: cancellation, maximumFileBytes: plan.destinationInventory.maximumFileBytes) == expected else {
            throw DirectorySyncError.changed(action.id)
        }
        try cancellation.check()
        try validateLocation()
        // New files use atomic no-replace. Updates atomically exchange the old file,
        // retaining it until post-publication identity/content validation completes.
        let flags = expected == nil ? RENAME_EXCL : RENAME_SWAP
        guard renameatx_np(targetParent, temporary, targetParent, name, UInt32(flags)) == 0 else { throw syncPOSIX(action.id) }
        if let expected {
            do {
                let displaced = try SyncRoot.snapshot(at: targetParent, name: temporary, cancellation: TransferCancellation(), maximumFileBytes: plan.destinationInventory.maximumFileBytes)
                guard Self.sameRelocatedFile(displaced, expected) else { throw DirectorySyncError.changed(action.id) }
            } catch {
                // Retain the old file even if validation or restoration fails.
                cleanTemporary = false
                let published = try? SyncRoot.snapshot(at: targetParent, name: name, cancellation: TransferCancellation(), maximumFileBytes: plan.sourceInventory.maximumFileBytes)
                guard Self.sameRelocatedFile(published, staged) else {
                    throw DirectorySyncError.changed("\(action.id) (Sicherung: \(temporary))")
                }
                guard renameatx_np(targetParent, temporary, targetParent, name, UInt32(RENAME_SWAP)) == 0 else {
                    throw DirectorySyncError.changed("\(action.id) (Sicherung: \(temporary))")
                }
                cleanTemporary = true
                throw error
            }
        }
    }
    private static func sameRelocatedFile(_ a: SyncSnapshot?, _ b: SyncSnapshot) -> Bool {
        guard let a else { return false }
        return a.sameIdentity(as: b) && a.size == b.size && a.modifiedSeconds == b.modifiedSeconds
            && a.modifiedNanos == b.modifiedNanos && a.digest == b.digest
    }
    private func report(currentBytes: Int64 = 0) {
        progress(OperationProgress(completedItems: completedItems, totalItems: selected.count,
            completedBytes: completedBytes + min(currentBytes, currentSize), totalBytes: totalBytes,
            currentPath: currentPath, currentFileBytes: currentBytes, currentFileTotalBytes: currentSize))
    }
}
