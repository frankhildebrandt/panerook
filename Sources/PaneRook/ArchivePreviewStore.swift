import Foundation
import PaneRookCore

/// Selected archive members are materialized only when opened or previewed.
/// Keep these copies alive for external viewers, and never write them back implicitly.
final class ArchivePreviewStore: @unchecked Sendable {
    static let shared = ArchivePreviewStore()
    private let lock = NSLock()
    private var root: URL?
    private var cached: [String: URL] = [:]

    func readableURL(for url: URL, cancellation: TransferCancellation = .init(),
                     progress: @escaping (OperationProgress) -> Void = { _ in }) throws -> URL {
        try cancellation.check()
        guard let location = ArchiveFileSystem.location(for: url), !location.memberPath.isEmpty else { return url }
        lock.lock(); defer { lock.unlock() }
        try cancellation.check()
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: location.archiveURL.path)
        let key = [url.path, String((attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0),
                   String(describing: attributes[.size]), String(describing: attributes[.systemFileNumber])].joined(separator: "\n")
        if let existing = cached[key], fm.fileExists(atPath: existing.path) { return existing }
        if root == nil {
            let directory = fm.temporaryDirectory.appendingPathComponent("PaneRook-archive-preview-" + UUID().uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            root = directory
        }
        let target = root!.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            guard let copy = try ArchiveFileSystem.extract([url], to: target, cancellation: cancellation, progress: progress).first else {
                throw CocoaError(.fileReadUnknown)
            }
            // A viewer may still offer Save As; the archive itself is never an edit target.
            if (try copy.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
            }
            cached[key] = copy
            return copy
        } catch {
            removeTemporaryDirectory(target)
            throw error
        }
    }

    func cleanUp() {
        lock.lock(); defer { lock.unlock() }
        if let root { removeTemporaryDirectory(root) }
        root = nil
        cached.removeAll()
    }

    private func removeTemporaryDirectory(_ directory: URL) {
        let fm = FileManager.default
        // Archive directory modes can omit owner write/search permission.
        // Only touch our private copies; never follow a viewer-created symlink.
        guard let attributes = try? fm.attributesOfItem(atPath: directory.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for child in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if (try? fm.attributesOfItem(atPath: child.path)[.type]) as? FileAttributeType == .typeDirectory {
                removeTemporaryDirectory(child)
            }
        }
        try? fm.removeItem(at: directory)
    }
}
