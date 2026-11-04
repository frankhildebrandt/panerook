import Foundation
import PaneRookCore
import PaneRookTasks
import PaneRookRemote

extension TransferFileAccess {
    /// Fingerprints include file contents; directories include their exact children.
    /// Retain this snapshot only in memory: retrying a destructive operation asks again.
    func conflictTree(_ root: TransferPath, depth: Int = 0) throws -> [TransferPath: TransferFingerprint] {
        try checkCancellation()
        guard depth < 256, let current = try fingerprint(root) else { throw RecoverableTransferError.changed(root.path) }
        var result = [root: current]
        if current.kind == .directory {
            for name in try children(root) {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw RecoverableTransferError.invalidPlan }
                result.merge(try conflictTree(root.appending(name), depth: depth + 1)) { _, new in new }
                guard result.count <= 100_000 else { throw RecoverableTransferError.invalidPlan }
            }
        }
        return result
    }

    func resolveConflict(_ root: TransferRoot, source: TransferFingerprint, target: TransferFingerprint) throws -> RecoverableConflictAction? {
        guard conflicts != nil || conflictChoice != nil else { return nil }
        var allowed: [TransferConflictAction] = [.skip, .keepBoth]
        if root.source.endpoint == .local && root.destination.endpoint == .local {
            allowed = try TransferConflict(source: URL(fileURLWithPath: root.source.path), destination: URL(fileURLWithPath: root.destination.path)).allowedActions
        } else if root.source != root.destination, target.kind != .symbolicLink,
                  !(root.source.endpoint == root.destination.endpoint && root.source.path.hasPrefix(root.destination.path + "/")) {
            allowed.append(.replace)
            if source.kind == .directory && target.kind == .directory { allowed.append(.merge) }
        }
        let snapshot = try conflictTree(root.destination)
        func description(_ entry: TransferFingerprint, at path: TransferPath) throws -> String {
            if path.endpoint == .local, let info = try TransferEntryInfo.read(URL(fileURLWithPath: path.path)) {
                return TransferConflictPrompt.describe(info)
            }
            let type = entry.kind == .directory ? "Ordner" : entry.kind == .symbolicLink ? "Symbolischer Link (Link selbst)" : "Datei"
            return TransferConflictPrompt.describe(type: type, size: entry.size, modified: entry.modified)
        }
        func path(_ path: TransferPath) -> String {
            path.endpoint == .local ? path.path : "\(path.endpoint.scheme)://\(path.endpoint.user)@\(path.endpoint.host):\(path.endpoint.port)\(path.path)"
        }
        let action: TransferConflictAction
        if let conflictChoice { action = try conflictChoice(root, allowed) }
        else {
            action = try conflicts!.resolve(source: path(root.source), destination: path(root.destination),
                sourceInfo: description(source, at: root.source), destinationInfo: description(target, at: root.destination), allowed: allowed,
                remoteDestination: root.destination.endpoint != .local,
                cancelled: { self.localToken.isCancelled || self.remoteToken.isCancelled })
        }
        guard allowed.contains(action) else { throw RecoverableTransferError.conflict(root.destination.path) }
        if action == .replace || action == .merge {
            guard try conflictTree(root.destination) == snapshot else { throw RecoverableTransferError.changed(root.destination.path) }
            if action == .replace { conflictTargets[root.destination] = snapshot }
        }
        return RecoverableConflictAction(action)
    }

    func replaceItem(from source: TransferPath, to destination: TransferPath, expected: TransferFingerprint,
                     progress: @escaping (OperationProgress) -> Void) throws {
        let snapshot = conflictTargets.removeValue(forKey: destination)
        guard let snapshot, snapshot[destination] == expected else { throw RecoverableTransferError.conflict(destination.path) }
        let sourceSnapshot = try conflictTree(source)
        try withTemporaryDirectory { directory in
            let staged = directory.appendingPathComponent((destination.path as NSString).lastPathComponent)
            if source.endpoint == .local {
                try RecoverableLocalFiles.copy(source.path, to: staged.path, cancellation: localToken, progress: progress)
            } else {
                let fs = try remote(source)
                guard let entry = try fs.entry(at: source.path, cancellation: remoteToken) else { throw RemoteError.sourceChanged }
                try fs.download(entry, from: (source.path as NSString).deletingLastPathComponent, to: staged, cancellation: remoteToken)
            }
            try checkCancellation()
            guard try conflictTree(source) == sourceSnapshot else { throw RecoverableTransferError.changed(source.path) }
            let validate = {
                guard try self.conflictTree(destination) == snapshot else { throw RecoverableTransferError.changed(destination.path) }
            }
            try validate()
            if destination.endpoint == .local {
                try RecoverableLocalFiles.replace(staged, to: URL(fileURLWithPath: destination.path), cancellation: localToken, validate: validate, progress: progress)
            } else {
                try remote(destination).upload(staged, to: (destination.path as NSString).deletingLastPathComponent,
                    resolveConflict: { _ in try validate(); return .replace }, cancellation: remoteToken)
            }
        }
    }
}

private extension RecoverableConflictAction {
    init(_ action: TransferConflictAction) {
        switch action {
        case .skip: self = .skip
        case .keepBoth: self = .keepBoth
        case .replace: self = .replace
        case .merge: self = .merge
        }
    }
}
