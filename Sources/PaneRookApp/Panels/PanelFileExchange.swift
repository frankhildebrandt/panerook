import AppKit
import PaneRookCore

extension PaneController {
    func installFileExchange(_ exchange: NativeFileExchange) { fileExchange = exchange }

    func configureFileExchange() {
        table.registerForDraggedTypes([.fileURL])
        table.toolTip = "Lokale Dateien ziehen oder mit ⌘C/⌘V kopieren, mit ⌘⌥V bewegen. Remote- und Archivinhalte zuerst mit F5 lokal kopieren."
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // The destination app owns external drops; do not promise source deletion after
        // a copy or create a second, unqueued move implementation here.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.copyFiles = { [weak self] in
            guard let self else { return }
            self.fileExchange?.copy(from: self)
        }
        table.pasteFiles = { [weak self] in
            guard let self else { return }
            self.fileExchange?.paste(into: self, kind: .copy)
        }
        table.canCopyFiles = { [weak self] in
            guard let self else { return false }
            return self.fileExchange?.canCopy(from: self) == true
        }
        table.canPasteFiles = { [weak self] in
            guard let self else { return false }
            return self.fileExchange?.canPaste(into: self) == true
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard fileExchange != nil, canExportNativeFiles, entries.indices.contains(row), !entries[row].isParent,
              (try? NativeFileURLs.validate([entries[row].url])) != nil else { return nil }
        return entries[row].url as NSURL
    }

    /// Drops between rows and in empty space refer to the panel directory. A row
    /// highlighted by AppKit must be a directory; a regular file is never a target.
    func fileDropDestination(row: Int, operation: NSTableView.DropOperation) -> URL? {
        guard canExportNativeFiles else { return nil }
        if operation == .on && row >= 0 {
            guard entries.indices.contains(row), entries[row].isDirectory else { return nil }
            return entries[row].url
        }
        return fileExchangeDirectory
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard let exchange = fileExchange,
              let target = fileDropDestination(row: row, operation: operation),
              let sources = try? NativeFileURLs.read(from: info.draggingPasteboard) else { return [] }
        let result = exchange.validateDrop(sources: sources, destination: target, pane: self,
            allowed: info.draggingSourceOperationMask, modifiers: NSEvent.modifierFlags)
        if !result.isEmpty, operation == .above { tableView.setDropRow(-1, dropOperation: .on) }
        return result
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard let exchange = fileExchange,
              let target = fileDropDestination(row: row, operation: operation),
              let sources = try? NativeFileURLs.read(from: info.draggingPasteboard) else { return false }
        // Acceptance reports races (removed sources, new collisions) through the host.
        let result = NativeFileURLs.dragOperation(sources: sources, destination: target,
            allowed: info.draggingSourceOperationMask, modifiers: NSEvent.modifierFlags)
        return exchange.acceptDrop(sources: sources, destination: target, pane: self, operation: result)
    }
}
