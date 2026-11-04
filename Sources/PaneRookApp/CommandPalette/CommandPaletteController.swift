import AppKit

/// An overlay retains the main window's context and enabled policies. It never
/// pretends an unrelated sheet or auxiliary feature window is the main window.
final class CommandPaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: CommandPaletteModel
    private let registry: CommandRegistry
    private weak var window: NSWindow?
    private weak var originalResponder: NSResponder?
    private let originalSelection: NSRange?
    private let backdrop = CommandPaletteBackdrop()
    let search = NSSearchField()
    let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private(set) var results: [CommandPaletteEntry] = []
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var dismissed = false
    var onDismiss: (() -> Void)?

    init(model: CommandPaletteModel, registry: CommandRegistry, window: NSWindow) {
        self.model = model; self.registry = registry; self.window = window
        // AppKit shares a field editor between controls. Remember its owning field,
        // rather than restoring the palette's editor after it has been removed.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            originalResponder = editor.delegate as? NSResponder
            originalSelection = editor.selectedRange()
        } else {
            originalResponder = window.firstResponder
            originalSelection = nil
        }
        super.init()
        buildView()
    }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func present() {
        guard let window, let content = window.contentView else { return }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        backdrop.onCancel = { [weak self] in self?.dismiss() }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willBeginSheetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.dismiss(restoreFocus: name != NSWindow.willCloseNotification)
            })
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window === self.window,
               !self.backdrop.bounds.contains(self.backdrop.convert(event.locationInWindow, from: nil)) {
                self.dismiss()
            }
            return event
        }
        reload()
        window.makeFirstResponder(search)
    }

    private func buildView() {
        let card = NSVisualEffectView()
        card.material = .popover; card.blendingMode = .withinWindow; card.state = .active
        card.wantsLayer = true; card.layer?.cornerRadius = 12
        card.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalTo: backdrop.widthAnchor, constant: -48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth, card.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            card.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            card.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 24),
            card.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -24)
        ])
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        let heading = NSTextField(labelWithString: "Befehlspalette")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(heading)
        search.placeholderString = "Aktion, Favorit, Verbindung oder Ort suchen"
        search.setAccessibilityLabel("Befehlspalette durchsuchen")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        root.addArrangedSubview(search)
        search.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        for (id, title, width) in [("title", "Aktion oder Ort", CGFloat(470)), ("shortcut", "Tastenkürzel", CGFloat(110))] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title; column.width = width
            if id == "shortcut" { column.resizingMask = []; column.minWidth = width; column.maxWidth = width }
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.headerView = nil
        table.style = .inset; table.rowHeight = 48
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false; table.allowsEmptySelection = false
        table.target = self; table.doubleAction = #selector(executeSelection)
        table.setAccessibilityLabel("Verfügbare Aktionen und Orte")
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        root.addArrangedSubview(scroll)
        let height = scroll.heightAnchor.constraint(equalToConstant: 340)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: root.widthAnchor), height,
                                     scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func reload() {
        results = model.results(for: search.stringValue)
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        let summary = results.isEmpty ? "Keine verfügbaren Treffer." : "\(results.count) Treffer · ↑↓ auswählen · Return ausführen · Esc schließen"
        status.stringValue = ([summary] + model.sourceErrors).joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let entry = results[row]
        if tableColumn?.identifier.rawValue == "shortcut" {
            let label = NSTextField(labelWithString: entry.shortcut)
            label.font = .systemFont(ofSize: 12); label.alignment = .right
            label.textColor = .secondaryLabelColor
            return label
        }
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: entry.detail)
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        for label in [title, detail] { label.lineBreakMode = .byTruncatingMiddle; label.toolTip = entry.detail }
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 2
        title.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Called before the main registry and terminal dispatchers. Search text retains
    /// AppKit editing; other main-window shortcuts cannot run behind the palette.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, !dismissed else { return false }
        if KeyboardCaptureState.isRecording { dismiss(); return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = flags.isEmpty
        let hasMarkedText = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        if hasMarkedText && !flags.contains(.command) { return false }
        let preservesText = ContextCommands.preservesTextInput(event, in: window)
        if (plain && event.keyCode == 53) ||
            (!preservesText && registry.matching(event, scope: .dialog)?.id.hasPrefix("dialog.cancel") == true) {
            dismiss(); return true
        }
        if !preservesText, registry.matching(event, scope: .dialog)?.id.hasPrefix("dialog.accept") == true {
            executeSelection(); return true
        }
        if plain {
            switch event.keyCode {
            case 36, 76: executeSelection(); return true
            case 125: selectRow(table.selectedRow + 1); return true
            case 126: selectRow(table.selectedRow - 1); return true
            case 121: selectRow(table.selectedRow + 7); return true
            case 116: selectRow(table.selectedRow - 7); return true
            case 115: selectRow(0); return true
            case 119: selectRow(results.count - 1); return true
            default: break
            }
        }
        if !preservesText, let command = registry.matching(event, scope: .textEditing) { return command.perform() }
        let bindings = registry.bindings
        if let binding = bindings["commands.palette"], !binding.isTextInput, binding.matches(event) {
            dismiss(); return true
        }
        if flags.contains(.command) { return true }
        if !preservesText,
           registry.commands.contains(where: { $0.scope != .textEditing && bindings[$0.id]?.matches(event) == true }) {
            return true
        }
        return false
    }

    private func selectRow(_ proposed: Int) {
        guard !results.isEmpty else { return }
        let row = max(0, min(proposed, results.count - 1))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc func executeSelection() {
        guard !dismissed, results.indices.contains(table.selectedRow), let window,
              window.isKeyWindow, window.attachedSheet == nil else { return }
        let entry = results[table.selectedRow]
        guard entry.enabled() else { reload(); NSSound.beep(); return }
        // Remove the overlay and restore the originating responder before a command
        // opens a dialog, captures a transfer target or resolves the responder chain.
        dismiss()
        if !entry.perform() { NSSound.beep() }
    }

    func dismiss(restoreFocus: Bool = true) {
        guard !dismissed else { return }
        dismissed = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        backdrop.removeFromSuperview()
        if restoreFocus, let window, let originalResponder {
            window.makeFirstResponder(originalResponder)
            if let selection = originalSelection, let editor = window.firstResponder as? NSTextView {
                editor.setSelectedRange(selection)
            }
        }
        onDismiss?()
    }
}

private final class CommandPaletteBackdrop: NSView {
    var onCancel: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.withAlphaComponent(0.14).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func mouseDown(with event: NSEvent) { onCancel?() }
    override func scrollWheel(with event: NSEvent) {}
}
