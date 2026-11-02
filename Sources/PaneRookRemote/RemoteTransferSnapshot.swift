import Foundation
import Darwin

struct RemoteTransferSnapshot: Equatable {
    let entry: RemoteEntry
    let children: [RemoteTransferSnapshot]
}

/// A local move must not recursively delete files created while uploading, nor
/// remove a replacement file that happens to have the same path.
struct LocalTransferSnapshot: Equatable {
    let name: String
    let inode: UInt64
    let device: UInt64
    let directory: Bool
    let size: UInt64
    let modified: Date
    let children: [LocalTransferSnapshot]

    static func capture(_ url: URL, depth: Int = 0, cancellation: RemoteCancellation) throws -> LocalTransferSnapshot {
        try cancellation.check()
        guard depth < 256 else { throw RemoteError.invalidPath }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw RemoteError.sourceChanged }
        guard type != .typeSymbolicLink else { throw RemoteError.symbolicLink }
        guard type == .typeDirectory || type == .typeRegular else { throw RemoteError.specialFile }
        let directory = type == .typeDirectory
        let children = directory ? try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try capture($0, depth: depth + 1, cancellation: cancellation) } : []
        return LocalTransferSnapshot(name: url.lastPathComponent, inode: inode.uint64Value, device: device.uint64Value,
                                     directory: directory, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                                     modified: modified, children: children)
    }

    func remove(_ url: URL, cancellation: RemoteCancellation) throws {
        try cancellation.check()
        // Validate each subtree immediately before touching it. Directory
        // metadata naturally changes as its captured children are removed.
        guard try Self.capture(url, cancellation: cancellation) == self else { throw RemoteError.sourceChanged }
        if directory {
            for child in children { try child.remove(url.appendingPathComponent(child.name), cancellation: cancellation) }
        }
        try cancellation.check()
        let result = url.path.withCString { directory ? Darwin.rmdir($0) : Darwin.unlink($0) }
        guard result == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST { throw RemoteError.sourceChanged }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
