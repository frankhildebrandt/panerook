import Foundation
import PaneRookCore
import PaneRookTasks

/// Bridges durable transfer results into the existing session-only undo journal.
/// Called on the serial task worker, including after partial failure or cancellation.
final class RecoverableTransferJournal {
    private struct Key: Hashable { let transfer: UUID; let root: Int }
    private let journal: FileOperationJournal
    private var recorded = Set<Key>()
    init(_ journal: FileOperationJournal) { self.journal = journal }

    func record(_ transfer: RecoverableTransfer) {
        guard transfer.moving, let entries = transfer.entries else { return }
        let access = TransferFileAccess() // A committed move still needs journalling after cancellation.
        let roots = transfer.roots.enumerated().compactMap { index, root -> (Int, TransferRoot)? in
            guard root.source.endpoint == .local, root.destination.endpoint == .local,
                  !recorded.contains(Key(transfer: transfer.id, root: index)) else { return nil }
            let subtree = entries.filter { entry in
                entry.root.source.endpoint == root.source.endpoint && entry.root.destination.endpoint == root.destination.endpoint
                    && (entry.root.source.path == root.source.path || entry.root.source.path.hasPrefix(root.source.path + "/"))
            }
            guard let first = subtree.first(where: { $0.root.source == root.source && ($0.originalDestination ?? $0.root.destination) == root.destination }),
                  subtree.allSatisfy({ $0.sourceRemoved && $0.destination != nil && $0.error == nil && $0.skipped != true && $0.preserveSource != true && $0.replaced != true && $0.merged != true }) else { return nil }
            return (index, first.root)
        }
        journal.recordCompletedMoves(roots.map { (_, root) in
            (source: URL(fileURLWithPath: root.source.path), destination: URL(fileURLWithPath: root.destination.path))
        }, title: transfer.title) { source, destination in
            let sourceParent = (source.path as NSString).deletingLastPathComponent
            let destinationParent = (destination.path as NSString).deletingLastPathComponent
            for anchor in transfer.anchors ?? [] where anchor.path.endpoint == .local && [sourceParent, destinationParent].contains(anchor.path.path) {
                guard try access.fingerprint(anchor.path) == anchor.fingerprint else { throw RecoverableTransferError.changed(anchor.path.path) }
            }
            guard try access.fingerprint(TransferPath(source.path)) == nil else { throw RecoverableTransferError.changed(source.path) }
            let subtree = entries.filter {
                $0.root.source.endpoint == .local && $0.root.destination.endpoint == .local
                    && ($0.root.source.path == source.path || $0.root.source.path.hasPrefix(source.path + "/"))
            }
            for entry in subtree {
                guard try access.fingerprint(entry.root.destination) == entry.destination else { throw RecoverableTransferError.changed(entry.root.destination.path) }
                if entry.source.kind == .directory {
                    let expected = Set(subtree.filter {
                        ($0.root.destination.path as NSString).deletingLastPathComponent == entry.root.destination.path
                    }.map { ($0.root.destination.path as NSString).lastPathComponent })
                    guard Set(try access.children(entry.root.destination)) == expected else { throw RecoverableTransferError.changed(entry.root.destination.path) }
                }
            }
        }
        for (index, _) in roots { recorded.insert(Key(transfer: transfer.id, root: index)) }
    }
}
