import Foundation
import Darwin
import PaneRookTasks

/// Two phases free every original name before publishing destinations, including
/// case-only changes and cycles. Every rename is exclusive, including rollback.
final class BatchRenameWorker {
    private let items: [BatchRenamePlan.Item]
    private let cancellation: TransferCancellation
    private let progress: (OperationProgress) -> Void
    private var containers: [URL: URL] = [:]
    private var staging: [Int: URL] = [:]
    private var locations: [Int: URL] = [:]
    private var descriptors: [String: Int32] = [:]

    init(items: [BatchRenamePlan.Item], cancellation: TransferCancellation,
         progress: @escaping (OperationProgress) -> Void) {
        self.items = items; self.cancellation = cancellation; self.progress = progress
    }
    func run() throws {
        defer {
            // Never recursively delete a recovery container: it may still hold data.
            for (parent, container) in containers {
                if let descriptor = descriptors[parent.path] { _ = unlinkat(descriptor, container.lastPathComponent, AT_REMOVEDIR) }
            }
            for descriptor in descriptors.values { close(descriptor) }
        }
        do {
            for (index, item) in items.enumerated() {
                try cancellation.check()
                try item.source.validate()
                let parent = item.source.url.deletingLastPathComponent()
                if containers[parent] == nil {
                    let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard descriptor >= 0 else { throw posixError(parent) }
                    descriptors[parent.path] = descriptor
                    var value = stat()
                    guard fstat(descriptor, &value) == 0,
                          value.st_dev == item.source.parentIdentity.device,
                          value.st_ino == item.source.parentIdentity.inode else {
                        throw BatchRenameError("Der Quellordner wurde zwischenzeitlich ersetzt: \(parent.path)")
                    }
                    let container = parent.appendingPathComponent(".panerook-rename-\(UUID().uuidString)")
                    guard mkdirat(descriptor, container.lastPathComponent, 0o700) == 0 else { throw posixError(container) }
                    containers[parent] = container
                    let stagingFD = openat(descriptor, container.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stagingFD >= 0 else { throw posixError(container) }
                    descriptors[container.path] = stagingFD
                }
                let temporary = containers[parent]!.appendingPathComponent(String(index))
                staging[index] = temporary
                try move(item.source.url, to: temporary, identity: item.source.identity)
                locations[index] = temporary
                report(index + 1, temporary)
            }
            for (index, item) in items.enumerated() {
                try cancellation.check()
                try move(staging[index]!, to: item.destination, identity: item.source.identity)
                locations[index] = item.destination
                report(items.count + index + 1, item.destination)
            }
            try cancellation.check()
        } catch {
            let failure = error
            // Free published names first, so restoring a cycle cannot collide with
            // another item of this operation. Ignore cancellation while recovering.
            var recoveryErrors: [String] = []
            var restored: [String] = []
            for index in items.indices {
                guard let location = locations[index], location == items[index].destination,
                      let temporary = staging[index] else { continue }
                do {
                    try move(location, to: temporary, identity: items[index].source.identity)
                    locations[index] = temporary
                } catch { recoveryErrors.append(error.localizedDescription) }
            }
            for index in items.indices {
                guard let location = locations[index] else { continue }
                do {
                    try move(location, to: items[index].source.url, identity: items[index].source.identity)
                    restored.append(actualPath(items[index].source.url))
                    locations.removeValue(forKey: index)
                } catch { recoveryErrors.append(error.localizedDescription) }
            }
            let remaining = locations.keys.sorted().map {
                "\(items[$0].source.url.path) → \(actualPath(locations[$0]!))"
            }
            let recovery = remaining.isEmpty ? "Alle bereits verschobenen Einträge wurden zurückgesetzt." :
                "Teilweise umbenannt. Diese Einträge liegen noch hier (bitte sichern):\n" + remaining.joined(separator: "\n")
            let reason = failure is TransferError ? "Mehrfachumbenennen abgebrochen." : failure.localizedDescription
            throw BatchRenameError(recovery + "\n\nUrsache: " + reason +
                (restored.isEmpty ? "" : "\n\nZurückgesetzte Einträge (aktuelle Pfade):\n" + restored.joined(separator: "\n")) +
                (recoveryErrors.isEmpty ? "" : "\n\nFehler beim Zurücksetzen:\n" + recoveryErrors.joined(separator: "\n")))
        }
    }
    private func move(_ source: URL, to destination: URL, identity: RenameIdentity) throws {
        guard let sourceFD = descriptors[source.deletingLastPathComponent().path],
              let destinationFD = descriptors[destination.deletingLastPathComponent().path] else {
            throw BatchRenameError("Quell- oder Zielordner ist nicht mehr verfügbar: \(source.path)")
        }
        var value = stat()
        guard fstatat(sourceFD, source.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(source) }
        guard value.st_dev == identity.device, value.st_ino == identity.inode, value.st_mode & S_IFMT == identity.kind else {
            throw BatchRenameError("Ein Eintrag wurde zwischenzeitlich ersetzt: \(source.path)")
        }
        guard renameatx_np(sourceFD, source.lastPathComponent, destinationFD, destination.lastPathComponent,
                          UInt32(RENAME_EXCL)) == 0 else { throw posixError(destination) }
    }
    private func actualPath(_ url: URL) -> String {
        guard let descriptor = descriptors[url.deletingLastPathComponent().path] else { return url.path }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return url.path }
        return URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent(url.lastPathComponent).path
    }
    private func report(_ completed: Int, _ url: URL) {
        progress(OperationProgress(completedItems: completed, totalItems: items.count * 2, currentPath: url.path))
    }
    private func posixError(_ url: URL) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
