import AppKit

extension CommanderController: NSMenuItemValidation {
    @objc func undo(_ sender: Any?) { fileOperations.fileUndoManager.undo() }
    @objc func redo(_ sender: Any?) { fileOperations.fileUndoManager.redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = fileOperations.fileUndoManager.undoMenuItemTitle
            return fileOperations.canUndoFiles
        case #selector(redo(_:)):
            menuItem.title = fileOperations.fileUndoManager.redoMenuItemTitle
            return fileOperations.canRedoFiles
        default: return false
        }
    }
}
