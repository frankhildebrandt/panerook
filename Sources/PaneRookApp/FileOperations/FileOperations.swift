import AppKit
import PaneRookCore
import PaneRookTasks

protocol FileOperationsHost: PanelPresenting, TaskProviding {
    var otherPane: any PanelAccess { get }
    var canUseSelection: Bool { get }
    var canUseLocalDirectory: Bool { get }
    var canUseNativeDirectory: Bool { get }
    var operations: OperationRunner { get }
    func refreshAfterTask()
}

final class FileOperations {
    unowned let owner: any FileOperationsHost
    let journal = FileOperationJournal()
    lazy var fileUndoManager = FileOperationUndoManager(operations: self)
    var isRestoringFiles = false
    private var transferDialog: TransferDialog?
    private var sparseFileDialog: SparseFileDialog?
    var batchRenameDialog: BatchRenameDialog?
    init(owner: any FileOperationsHost) { self.owner = owner }
    var canCopySelection: Bool {
        guard owner.canUseMenus else { return false }
        if let remote = owner.activePane.remoteContent { return remote.canDownload }
        if let remote = owner.otherPane.remoteContent { return owner.canUseSelection && remote.canUpload }
        return owner.canUseSelection
    }
    var canMoveSelection: Bool {
        guard owner.canUseMenus else { return false }
        if let remote = owner.activePane.remoteContent { return remote.canMove }
        if let remote = owner.otherPane.remoteContent { return owner.canUseSelection && remote.canUpload }
        return owner.canUseSelection
    }
    var canMakeDirectory: Bool {
        if let remote = owner.activePane.remoteContent { return owner.canUseMenus && !remote.isBusy && !remote.awaitsWorkspaceAuthentication }
        return owner.canUseLocalDirectory
    }
    var canTrashSelection: Bool {
        if let remote = owner.activePane.remoteContent { return owner.canUseMenus && !remote.isBusy && remote.hasSelection }
        return owner.canUseSelection
    }
    func copySelection() {
        guard canCopySelection else { return }
        if let remote = owner.activePane.remoteContent { remote.download(); return }
        if let remote = owner.otherPane.remoteContent { remote.upload(); return }
        transfer(.copy)
    }
    var canRenameSelection: Bool {
        guard owner.canUseMenus else { return false }
        if let remote = owner.activePane.remoteContent { return remote.canRename }
        return owner.canUseSelection && (owner.activePane.selectedFiles.count == 1 || canBatchRenameSelection)
    }
    func renameSelection() {
        guard canRenameSelection else { return }
        if let remote = owner.activePane.remoteContent { remote.renameSelection(); return }
        if owner.activePane.selectedFiles.count > 1 { batchRenameSelection(); return }
        transfer(.move, rename: true)
    }
    func moveSelection() {
        guard canMoveSelection else { return }
        if let remote = owner.activePane.remoteContent { remote.moveSelection(); return }
        if let remote = owner.otherPane.remoteContent { remote.moveLocalSelection(); return }
        transfer(.move)
    }
    private func transfer(_ kind: TransferKind, rename: Bool = false) {
        guard owner.canUseSelection, owner.activePane.remoteContent == nil, (rename || owner.otherPane.remoteContent == nil),
              let window = owner.presentationWindow else { return }
        let sources = owner.activePane.selectedFiles
        guard !sources.isEmpty else { NSSound.beep(); return }
        let destination = rename ? owner.activePane.directory : owner.otherPane.directory
        confirmTransfer(sources: sources, sourceDirectory: owner.activePane.directory,
            destination: destination, kind: kind, rename: rename, focusPane: owner.activePane, window: window)
    }

    /// Every entry point captures its inputs before presenting the shared transfer dialog.
    func confirmTransfer(sources: [URL], sourceDirectory: URL, destination: URL, kind: TransferKind,
                         rename: Bool = false, focusPane: any PanelAccess, window: NSWindow) {
        let verb = rename ? "Umbenennen" : kind == .copy ? "Kopieren" : "Verschieben"
        let dialog = TransferDialog(sources: sources, sourceDirectory: sourceDirectory,
            destinationDirectory: destination, kind: kind) { [weak self] plan in
            guard let self else { return }
            self.transferDialog = nil
            self.owner.activate(focusPane)
            guard let plan else { return }
            if !rename && !plan.items.contains(where: { ArchiveFileSystem.location(for: $0.source).map { !$0.memberPath.isEmpty } == true || ArchiveFileSystem.location(for: $0.destination).map { !$0.memberPath.isEmpty } == true }) {
                let record = RecoverableTransfer(title: verb, moving: kind == .move, roots: plan.items.map {
                    TransferRoot(source: TransferPath(RecoverableLocalFiles.canonicalPath($0.source)),
                                 destination: TransferPath(RecoverableLocalFiles.canonicalPath($0.destination)))
                })
                self.owner.tasks.submitTransfer(record, journal: self.journal, resolveConflicts: true) { [weak self] in self?.owner.refreshAfterTask() }
                return
            }
            let token = TransferCancellation()
            var taskID: UUID?
            let conflicts = TransferConflictPrompt(parent: self.owner.presentationWindow, onCancel: { [weak self] in
                token.cancel()
                if let taskID { self?.owner.tasks.cancel(taskID) }
            })
            taskID = self.owner.tasks.submit(title: verb, detail: plan.items.map { "\($0.source.path) → \($0.destination.path)" }.joined(separator: "\n"),
                cancellation: { token.cancel() }, work: { report in
                    let isLocalMove = kind == .move && plan.items.allSatisfy {
                        (ArchiveFileSystem.location(for: $0.source)?.memberPath.isEmpty ?? true) && (ArchiveFileSystem.location(for: $0.destination)?.memberPath.isEmpty ?? true)
                    }
                    if try isLocalMove && plan.items.allSatisfy({ try TransferEntryInfo.read($0.destination) == nil }) {
                        try self.journal.move(plan, title: verb, cancellation: token, progress: report)
                    } else {
                        try plan.execute(cancellation: token, resolveConflict: {
                            try conflicts.resolve($0, cancelled: { token.isCancelled })
                        }, progress: report)
                    }
                }, completion: { [weak self] _ in self?.owner.refreshAfterTask() })
        }
        transferDialog = dialog
        dialog.begin(on: window)
    }
    func makeDirectory() {
        guard canMakeDirectory else { return }
        if let remote = owner.activePane.remoteContent { remote.makeDirectory(); return }
        let directory = owner.activePane.directory
        let pane = owner.activePane
        let alert = NSAlert()
        alert.messageText = "Neuer Ordner"
        alert.informativeText = "In: \(directory.path)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        input.placeholderString = "Ordnername"
        alert.accessoryView = input
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: owner.presentationWindow!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = input.stringValue
            guard let self else { return }
            self.owner.operations.runArchiveOperation("Ordner anlegen …", detail: directory.path, completion: {
                guard pane.canApplyTaskResult(in: directory) else { return }
                pane.refresh(select: directory.appendingPathComponent(name))
            }) { token, report in
                if ArchiveFileSystem.location(for: directory) == nil {
                    try self.journal.createDirectory(named: name, in: directory, cancellation: token, progress: report)
                } else {
                    try FileActions.createDirectory(named: name, in: directory, cancellation: token, progress: report)
                }
            }
        }
    }
    func createSparseFile() {
        guard owner.canUseNativeDirectory, let window = owner.presentationWindow else { return }
        let pane = owner.activePane
        let directory = pane.directory
        let dialog = SparseFileDialog(directory: directory) { [weak self] request in
            guard let self else { return }
            self.sparseFileDialog = nil
            self.owner.activate(pane)
            guard let request else { return }
            self.owner.operations.runOperation("Sparse-Datei erstellen …", completion: {
                guard pane.canApplyTaskResult(in: directory) else { return }
                pane.setMode(.listing)
                if !pane.filterPattern.isEmpty && !LocalInspection.matches(request.name, pattern: pane.filterPattern) {
                    pane.setFilter("")
                }
                pane.refresh(select: directory.appendingPathComponent(request.name))
            }, errorDetail: "") {
                try SparseFile.create(named: request.name, in: directory, logicalSize: request.logicalSize)
            }
        }
        sparseFileDialog = dialog
        dialog.begin(on: window)
    }
    func trashSelection() {
        guard canTrashSelection else { return }
        if let remote = owner.activePane.remoteContent { remote.deleteSelected(); return }
        let sources = owner.activePane.selectedFiles
        guard !sources.isEmpty else { NSSound.beep(); return }
        if sources.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(sources.count) Einträge endgültig aus dem Archiv löschen?"
            alert.informativeText = sources.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
                + "\n\nArchiv-Inhalte werden nicht in den Papierkorb gelegt. Diese Aktion lässt sich nicht widerrufen."
            alert.addButton(withTitle: "Aus Archiv löschen")
            alert.addButton(withTitle: "Abbrechen")
            alert.configureKeyboardShortcuts()
            alert.beginSheetModal(for: owner.presentationWindow!) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.owner.operations.runArchiveOperation("Aus Archiv löschen …", detail: "Das Archiv wird erst nach erfolgreichem Schreiben ersetzt.") { token, report in
                    try ArchiveFileSystem.remove(sources, cancellation: token, progress: report)
                }
            }
            return
        }
        if UserDefaults.standard.object(forKey: "confirmTrash") as? Bool == false {
            trashLocalFiles(sources)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(sources.count) Einträge in den Papierkorb legen?"
        alert.informativeText = sources.prefix(5).map(\.lastPathComponent).joined(separator: "\n") + "\n\nDu kannst diese Aktion über Bearbeiten → Rückgängig widerrufen, solange die Einträge unverändert im Papierkorb liegen. Auch die Wiederherstellung im Finder bleibt möglich."
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: owner.presentationWindow!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.trashLocalFiles(sources)
        }
    }
}
