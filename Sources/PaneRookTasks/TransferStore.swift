import Foundation

/// One atomic document per transfer: no closures, credentials or unrelated background jobs.
public final class TransferStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    public func load() throws -> [RecoverableTransfer] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                let value = try JSONDecoder().decode(RecoverableTransfer.self, from: Data(contentsOf: $0))
                guard value.version == 1, $0.deletingPathExtension().lastPathComponent == value.id.uuidString else {
                    throw RecoverableTransferError.invalidPlan
                }
                try value.validate()
                return value
            }
    }
    public func save(_ transfer: RecoverableTransfer) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(transfer.id.uuidString + ".json")
        try JSONEncoder().encode(transfer).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
}
