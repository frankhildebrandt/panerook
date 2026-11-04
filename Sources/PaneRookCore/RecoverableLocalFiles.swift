import Foundation
import CryptoKit
import Darwin
import PaneRookTasks

/// File-level adapter retaining copyfile's staging, metadata preservation and cancellation.
public enum RecoverableLocalFiles {
    public static func canonicalPath(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }
    private static func checkedURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), canonicalPath(url) == path else { throw RecoverableTransferError.changed(path) }
        return url
    }
    public static func fingerprint(_ path: String, cancellation: TransferCancellation) throws -> TransferFingerprint? {
        try cancellation.check()
        let url = try checkedURL(path)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
        let identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        let kind = attributes[.type] as? FileAttributeType
        if kind == .typeDirectory { return .init(kind: .directory, identity: identity) }
        if kind == .typeSymbolicLink {
            return .init(kind: .symbolicLink, identity: identity,
                         digest: try FileManager.default.destinationOfSymbolicLink(atPath: path))
        }
        guard kind == .typeRegular else { throw RecoverableTransferError.invalidPlan }
        let hash = try digest(url, cancellation: cancellation)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        for key in [FileAttributeKey.systemFileNumber, .size, .modificationDate] {
            guard (attributes[key] as? NSObject) == (after[key] as? NSObject) else { throw RecoverableTransferError.changed(path) }
        }
        return .init(kind: .file, size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                     modified: attributes[.modificationDate] as? Date, identity: identity, digest: hash)
    }
    public static func digest(_ url: URL, cancellation: TransferCancellation) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while true {
            try cancellation.check()
            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func children(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: checkedURL(path).path)
    }
    public static func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(at: checkedURL(path), withIntermediateDirectories: false)
    }
    public static func copy(_ source: String, to destination: String, cancellation: TransferCancellation,
                            progress: @escaping (OperationProgress) -> Void) throws {
        let plan = try TransferPlan(sources: [checkedURL(source)], sourcePattern: "*", destinationPath: checkedURL(destination).path,
                                    relativeTo: URL(fileURLWithPath: "/"), kind: .copy)
        try plan.execute(cancellation: cancellation, progress: progress)
    }
    public static func finishDirectory(from source: String, to destination: String) throws {
        let source = try checkedURL(source), destination = try checkedURL(destination)
        guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
    public static func remove(_ path: String, directory: Bool) throws {
        let path = try checkedURL(path).path
        let status = path.withCString { directory ? Darwin.rmdir($0) : Darwin.unlink($0) }
        if status != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }
    }
}
