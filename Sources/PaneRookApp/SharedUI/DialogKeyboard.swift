import AppKit

extension NSAlert {
    /// Explicit equivalents work with text fields and avoid depending on localized button titles.
    func configureKeyboardShortcuts() {
        buttons.first?.keyEquivalent = "\r"
        buttons.first?.keyEquivalentModifierMask = []
        if buttons.count > 1 {
            buttons.last?.keyEquivalent = "\u{1b}"
            buttons.last?.keyEquivalentModifierMask = []
        } else {
            let close = NSButton(title: "", target: self, action: #selector(dismissWithEscape))
            close.keyEquivalent = "\u{1b}"
            close.keyEquivalentModifierMask = []
            close.frame = NSRect(x: -1, y: -1, width: 0, height: 0)
            window.contentView?.addSubview(close)
        }
    }
    @objc private func dismissWithEscape() {
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
    }
}

final class TransferPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (event.keyCode == 53 && modifiers.isEmpty) || (event.keyCode == 109 && modifiers.isEmpty)
            || (event.keyCode == 5 && modifiers == .control) {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
