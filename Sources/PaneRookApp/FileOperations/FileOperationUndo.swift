import AppKit
import PaneRookCore

/// Native UndoManager facade over the asynchronous, checked filesystem journal.
/// The journal owns history because a native synchronous undo stack cannot represent partial I/O.
final class FileOperationUndoManager: UndoManager {
    private weak var operations: FileOperations?
    init(operations: FileOperations) { self.operations = operations; super.init(); groupsByEvent = false }
    override var canUndo: Bool { operations?.canUndoFiles == true }
    override var canRedo: Bool { operations?.canRedoFiles == true }
    override var undoActionName: String { operations?.journal.nextUndo?.description ?? "" }
    override var redoActionName: String { operations?.journal.nextRedo?.description ?? "" }
    override var undoMenuItemTitle: String { undoActionName.isEmpty ? "Rückgängig" : "Rückgängig: " + undoActionName }
    override var redoMenuItemTitle: String { redoActionName.isEmpty ? "Wiederholen" : "Wiederholen: " + redoActionName }
    override func undo() { operations?.restoreFiles(redo: false) }
    override func redo() { operations?.restoreFiles(redo: true) }
}

extension FileOperations {
    /// Responder-chain fallback must never turn a text/terminal undo into a file operation.
    var acceptsNativeFileUndo: Bool {
        guard owner.canUseMenus, owner.canUseNativeDirectory,
              owner.activePane.remoteContent == nil, owner.activePane.mode == .listing,
              let responder = owner.presentationWindow?.firstResponder,
              !(responder is NSTextView), !(responder is NSTextField) else { return false }
        return true
    }
    var canUndoFiles: Bool {
        acceptsNativeFileUndo && !isRestoringFiles && !owner.tasks.hasActiveTasks && journal.nextUndo != nil
    }
    var canRedoFiles: Bool {
        acceptsNativeFileUndo && !isRestoringFiles && !owner.tasks.hasActiveTasks && journal.nextRedo != nil
    }
    func trashLocalFiles(_ sources: [URL]) {
        owner.operations.runArchiveOperation("In den Papierkorb legen", detail: sources.map(\.path).joined(separator: "\n")) { [journal] token, report in
            try journal.trash(sources, cancellation: token, progress: report)
        }
    }
    func restoreFiles(redo: Bool) {
        guard redo ? canRedoFiles : canUndoFiles,
              let action = redo ? journal.nextRedo : journal.nextUndo else { return }
        isRestoringFiles = true
        let token = TransferCancellation()
        owner.tasks.submit(title: (redo ? "Wiederholen: " : "Rückgängig: ") + action.description,
            detail: action.paths.joined(separator: "\n") + "\n\nNur unveränderte Einträge werden wiederhergestellt. Bestehende Ziele bleiben erhalten. Bei Teilfehlern bleiben offene und abgeschlossene Schritte getrennt verfügbar.",
            cancellation: { token.cancel() }, work: { [journal] report in
                if redo { try journal.redo(expectedID: action.id, cancellation: token, progress: report) }
                else { try journal.undo(expectedID: action.id, cancellation: token, progress: report) }
            }, completion: { [weak self] _ in
                self?.isRestoringFiles = false
                self?.owner.refreshAfterTask()
            })
    }
    func showOperationHistory() {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let history = journal.history
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short; dateFormatter.timeStyle = .medium
        let content = history.reversed().map { event in
            "\(dateFormatter.string(from: event.date)) — \(event.title)\n\(event.completed) / \(event.total) Einträge abgeschlossen\n"
                + event.paths.joined(separator: "\n")
                + (event.error.map { "\nFehler/Abbruch: " + $0 } ?? "")
        }.joined(separator: "\n\n")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 340))
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.string = content.isEmpty ? "Noch keine protokollierten lokalen Dateiaktionen." : content
        text.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true; scroll.documentView = text
        let alert = NSAlert()
        alert.messageText = "Lokale Dateiaktionen"
        alert.informativeText = "Pro Fenster und Sitzung: bis zu 100 Aktionen. Rückgängig: \(journal.nextUndo?.description ?? "keine Aktion"). Wiederholen: \(journal.nextRedo?.description ?? "keine Aktion").\nKopieren, Shell-, Archiv- und Remote-Aktionen haben kein Datei-Undo."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Schließen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window)
    }
    func registerUndoCommands(in registry: CommandRegistry) {
        let undo = registry.add(.file, "Dateiaktion rückgängig", id: "files.undo", order: 10, group: -1,
            scope: .panel, enabled: { self.canUndoFiles }) { self.fileUndoManager.undo() }
        undo.menuTitle = { [weak self] in self?.fileUndoManager.undoMenuItemTitle ?? "Dateiaktion rückgängig" }
        let redo = registry.add(.file, "Dateiaktion wiederholen", id: "files.redo", order: 20, group: -1,
            scope: .panel, enabled: { self.canRedoFiles }) { self.fileUndoManager.redo() }
        redo.menuTitle = { [weak self] in self?.fileUndoManager.redoMenuItemTitle ?? "Dateiaktion wiederholen" }
        registry.add(.file, "Operationsprotokoll …", id: "files.history", order: 30, group: -1,
            enabled: { self.owner.canUseMenus }) { self.showOperationHistory() }
    }
}
