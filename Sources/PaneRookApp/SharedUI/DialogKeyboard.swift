import AppKit

extension NSAlert {
    /// Stable identifiers let the dialog dispatcher invoke the buttons with the current mapping.
    func configureKeyboardShortcuts() {
        if buttons.isEmpty { addButton(withTitle: "OK") }
        if let button = buttons.first { ContextCommands.configure(button, id: "dialog.accept") }
        buttons.first?.keyEquivalentModifierMask = []
        if buttons.count > 1 {
            if let button = buttons.last { ContextCommands.configure(button, id: "dialog.cancel") }
            buttons.last?.keyEquivalentModifierMask = []
        }
        window.defaultButtonCell = nil
    }

}

final class TransferPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let event = NSApp.currentEvent, event.type == .keyDown, !ContextCommands.isCancellation(event) { return }
        onCancel?()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !ContextCommands.preservesTextInput(event, in: self), ContextCommands.isCancellation(event) {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
