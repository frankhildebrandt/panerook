import AppKit
import PaneRookCore
import PaneRookRemote
import PaneRookTasks

/// Readable copies stay available while an external viewer or Quick Look uses them.
/// They are private, read-only session files; opening them never writes back to the server.
private final class RemoteReadableFiles {
    static let shared = RemoteReadableFiles()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-Remote-" + UUID().uuidString, isDirectory: true)
    private init() {}
    deinit { try? FileManager.default.removeItem(at: root) }
    func newDirectory() throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
}

extension RemoteBrowser {
    var remoteEditRequests: [RemoteEditRequest] {
        guard !busy, !disconnected, !selection.isEmpty,
              selection.allSatisfy({ $0.isRegularFile && !$0.isSymbolicLink }) else { return [] }
        return selection.compactMap { entry in
            guard let path = try? RemoteFileSystem.normalizedPath(entry.name, relativeTo: directory) else { return nil }
            return RemoteEditRequest(fileSystem: fileSystem, path: path)
        }
    }
    var canMove: Bool { canDownload }
    var canRename: Bool { !busy && !disconnected && selection.count == 1 && selection.first?.isSymbolicLink == false }
    var canPreview: Bool { !busy && selection.contains { $0.isRegularFile && !$0.isSymbolicLink } }

    @objc func download() { transferSelection(move: false) }
    func moveSelection() { transferSelection(move: true) }

    private func transferSelection(move: Bool) {
        guard !busy, let peer, !selection.isEmpty else { return }
        let remoteDestination = peer.remoteContent as? RemoteBrowser
        if let remoteDestination {
            guard !remoteDestination.busy, !remoteDestination.disconnected else { return }
        } else {
            guard peer.remoteContent == nil, !peer.isArchiveDirectory, peer.mode != .network else { showArchiveTransferError(); return }
        }
        let selected = selection, path = directory, source = fileSystem
        // Keep the actual destination, even if either panel navigates before the task starts.
        let localDirectory = peer.directory
        let destinationFS = remoteDestination?.fileSystem
        let remoteDirectory = remoteDestination?.directory
        let target = remoteDestination.map { $0.displayName + $0.directory } ?? localDirectory.path
        let execute = { [weak self, weak peer] in
            guard let self else { return }
            self.performQueued(move ? "Verschieben nach \(target)" : "Kopieren nach \(target)",
                paths: selected.map { path + "/" + $0.name }, work: { token, report in
                    for (index, entry) in selected.enumerated() {
                        try token.check()
                        report(OperationProgress(completedItems: index, totalItems: selected.count, currentPath: entry.name))
                        if let destinationFS, let remoteDirectory {
                            if move { try source.move(entry, from: path, to: destinationFS, directory: remoteDirectory, cancellation: token) }
                            else { try source.copy(entry, from: path, to: destinationFS, directory: remoteDirectory, cancellation: token) }
                        } else {
                            let destination = localDirectory.appendingPathComponent(entry.name)
                            if move { try source.move(entry, from: path, to: destination, cancellation: token) }
                            else { try source.download(entry, from: path, to: destination, cancellation: token) }
                        }
                        report(OperationProgress(completedItems: index + 1, totalItems: selected.count, currentPath: entry.name))
                    }
                }) { [weak self, weak peer] _ in
                    peer?.refreshAfterTask()
                    if move { self?.reload() }
                    else { self?.status.stringValue = "\(selected.count) Einträge kopiert" }
                }
        }
        if move {
            guard let window = view.window else { return }
            let alert = NSAlert(); alert.messageText = "\(selected.count) Einträge verschieben?"
            alert.informativeText = displayName + path + " → " + target
            alert.addButton(withTitle: "Verschieben"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
            alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { execute() } }
        } else { execute() }
    }

    @objc func upload() { transferLocalSelection(move: false) }
    func moveLocalSelection() { transferLocalSelection(move: true) }
    private func transferLocalSelection(move: Bool) {
        guard !busy, let peer, let window = view.window else { return }
        guard peer.remoteContent == nil, !peer.isArchiveDirectory, peer.mode != .network else { showArchiveTransferError(); return }
        let sources = peer.selectedFiles, path = directory, destination = fileSystem
        guard !sources.isEmpty else { status.stringValue = "Zuerst Dateien im anderen Panel auswählen."; return }
        let verb = move ? "Verschieben" : "Kopieren"
        let alert = NSAlert(); alert.messageText = "\(sources.count) Einträge \(move ? "verschieben" : "kopieren")?"
        alert.informativeText = "\(peer.directory.path) → \(displayName)\(path)"
        alert.addButton(withTitle: verb); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self, weak peer] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performQueued(verb, paths: sources.map(\.path), work: { token, report in
                for (index, source) in sources.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: sources.count, currentPath: source.path))
                    try destination.upload(source, to: path, movingSource: move, cancellation: token)
                    report(OperationProgress(completedItems: index + 1, totalItems: sources.count, currentPath: source.path))
                }
            }) { [weak self, weak peer] _ in self?.reload(); peer?.refreshAfterTask() }
        }
    }

    func renameSelection() {
        guard !busy, selection.count == 1, let entry = selection.first, let window = view.window else { return }
        let path = directory, source = fileSystem
        let alert = NSAlert(); alert.messageText = "Umbenennen"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        AppStyle.configureField(name); name.stringValue = entry.name; name.setAccessibilityLabel("Neuer Name")
        alert.accessoryView = name; alert.addButton(withTitle: "Umbenennen"); alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts(); alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileActions.validateName(name.stringValue)
                let destination = try RemoteFileSystem.normalizedPath(name.stringValue, relativeTo: path)
                self.performQueued("Umbenennen", paths: [path + "/" + entry.name], work: { token, _ in
                    try source.move(entry, from: path, to: destination, cancellation: token)
                }) { [weak self] _ in self?.reload() }
            } catch { self.showError(error) }
        }
    }

    func preparePreview(completion: @escaping ([URL]) -> Void) {
        guard canPreview else { return }
        let selected = selection.filter { $0.isRegularFile && !$0.isSymbolicLink }
        let path = directory, source = fileSystem
        performQueued("Vorschau vorbereiten", paths: selected.map { path + "/" + $0.name }, work: { token, report in
            let directory = try RemoteReadableFiles.shared.newDirectory()
            do {
                var files: [URL] = []
                for (index, entry) in selected.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: selected.count, currentPath: entry.name))
                    let file = directory.appendingPathComponent(entry.name)
                    try source.download(entry, from: path, to: file, cancellation: token)
                    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
                    files.append(file)
                }
                try token.check()
                report(OperationProgress(completedItems: selected.count, totalItems: selected.count))
                return files
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
        }, completion: completion)
    }

    @objc func makeDirectory() {
        guard !busy, let window = view.window else { return }
        let directory = self.directory, destination = fileSystem
        let alert = NSAlert(); alert.messageText = "Neuer Ordner"
        alert.informativeText = "In: " + displayName + directory
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 28)); AppStyle.configureField(name); name.setAccessibilityLabel("Ordnername")
        alert.accessoryView = name; alert.addButton(withTitle: "Anlegen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts(); alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileActions.validateName(name.stringValue)
                let path = try RemoteFileSystem.normalizedPath(name.stringValue, relativeTo: directory)
                self.perform("Ordner wird angelegt", work: { try destination.createDirectory(path, cancellation: $0) }) { [weak self] _ in self?.reload() }
            } catch { self.showError(error) }
        }
    }
    @objc func deleteSelected() {
        guard !busy, !selection.isEmpty, let window = view.window else { return }
        let selected = selection, path = directory
        let alert = NSAlert(); alert.alertStyle = .warning
        let provider = fileSystem.connection.kind.provider
        alert.messageText = "\(selected.count) " + provider.deleteTitle
        alert.informativeText = provider.deleteNotice
        alert.addButton(withTitle: "Löschen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performQueued("Dateien löschen", paths: selected.map { path + "/" + $0.name }, work: { token, report in
                for (index, entry) in selected.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: selected.count, currentPath: entry.name))
                    try self.fileSystem.remove(entry, from: path, cancellation: token)
                    report(OperationProgress(completedItems: index + 1, totalItems: selected.count, currentPath: entry.name))
                }
            }) { [weak self] _ in self?.reload() }
        }
    }
}
