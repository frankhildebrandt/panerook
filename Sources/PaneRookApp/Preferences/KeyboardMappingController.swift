import AppKit

/// App shortcuts must yield to the recorder, including Escape and Return.
enum KeyboardCaptureState {
    static var isRecording = false
}

final class KeyCapture: NSTextField {
    private(set) var binding: AppKeyBinding?
    var onCapture: ((AppKeyBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func keyDown(with event: NSEvent) { capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        capture(event)
        return true
    }
    func clear() { binding = nil; stringValue = "" }
    func capture(_ event: NSEvent) {
        guard let binding = AppKeyBinding(event: event) else { return }
        self.binding = binding
        stringValue = binding.label
        onCapture?(binding)
    }
}

/// The catalog includes actions without a default shortcut and actions in other windows.
final class KeyboardMappingController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    private let registry: CommandRegistry
    private let didChange: () -> Void
    private let didClose: () -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let count = NSTextField(labelWithString: "")
    private let selection = NSTextField(labelWithString: "Aktion auswählen")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let capture = KeyCapture()
    private let assign = NSButton(title: "Belegen …", target: nil, action: nil)
    private let remove = NSButton(title: "Belegung entfernen", target: nil, action: nil)
    private let restore = NSButton(title: "Standard wiederherstellen", target: nil, action: nil)
    private let resetAll = NSButton(title: "Alle zurücksetzen …", target: nil, action: nil)
    private let save = NSButton(title: "Speichern", target: nil, action: nil)
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let closeButton = NSButton(title: "Fertig", target: nil, action: nil)
    private var filtered: [AppCommand] = []
    private var recordingID: String?
    private var keyMonitor: Any?
    private var finished = false

    init(registry: CommandRegistry, didChange: @escaping () -> Void, didClose: @escaping () -> Void) {
        self.registry = registry
        self.didChange = didChange
        self.didClose = didClose
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Tastaturbelegung"
        panel.minSize = NSSize(width: 820, height: 560)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        buildView()
        reloadCommands()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if recordingID != nil { KeyboardCaptureState.isRecording = false }
    }

    func present(asSheetOf parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in self?.finish() }
        window.makeFirstResponder(search)
    }

    private func buildView() {
        guard let window else { return }
        let background = AppStyle.background()
        window.contentView = background
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16)
        ])
        let intro = NSTextField(wrappingLabelWithString:
            "Jede Aktion kann eine eigene Tastenkombination erhalten. Der Bereich zeigt, wo die Belegung gilt. Änderungen werden sofort gespeichert.")
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(intro)
        search.placeholderString = "Aktion, Bereich oder Tastenkombination suchen"
        search.setAccessibilityLabel("Tastaturbelegungen durchsuchen")
        search.delegate = self
        root.addArrangedSubview(search)

        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.rowHeight = 28
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(beginRecording)
        table.setAccessibilityLabel("Aktionen und Tastaturbelegungen")
        for (id, title, width) in [
            ("action", "Aktion", 295.0), ("category", "Bereich", 235.0),
            ("binding", "Belegung", 130.0), ("default", "Standard", 130.0)
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "action" ? 160 : 90
            column.resizingMask = [.autoresizingMask, .userResizingMask]
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        root.addArrangedSubview(scroll)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .secondaryLabelColor
        root.addArrangedSubview(count)
        selection.font = .systemFont(ofSize: 12, weight: .semibold)
        selection.lineBreakMode = .byTruncatingTail
        root.addArrangedSubview(selection)

        let editing = NSStackView(views: [assign, remove, restore, NSView()])
        editing.spacing = 8
        root.addArrangedSubview(editing)
        capture.placeholderString = "Tastenkombination drücken"
        capture.isEditable = false
        capture.isSelectable = false
        capture.setAccessibilityLabel("Neue Tastenkombination")
        AppStyle.configureField(capture)
        capture.onCapture = { [weak self] binding in self?.validate(binding) }
        capture.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        let recorder = NSStackView(views: [capture, save, cancel])
        recorder.spacing = 8
        root.addArrangedSubview(recorder)
        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(message)
        let footer = NSStackView(views: [resetAll, NSView(), closeButton])
        footer.spacing = 8
        root.addArrangedSubview(footer)

        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        let buttons: [(NSButton, Selector)] = [
            (assign, #selector(beginRecording)), (remove, #selector(removeBinding)),
            (restore, #selector(restoreBinding)), (resetAll, #selector(resetBindings)),
            (save, #selector(saveBinding)), (cancel, #selector(cancelRecording)), (closeButton, #selector(closeMapping))
        ]
        for (button, action) in buttons {
            AppStyle.configureButton(button)
            button.target = self
            button.action = action
            // A Return or Escape is recordable; no button claims these keys.
            button.keyEquivalent = ""
        }
        closeButton.identifier = .init("dialog.accept")
        updateControls()
    }

    private var selectedCommand: AppCommand? {
        filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil
    }
    private func reloadCommands(selecting id: String? = nil) {
        let selectedID = id ?? selectedCommand?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let bindings = registry.bindings
        filtered = registry.customizableCommands.filter { command in
            query.isEmpty || [command.title, command.categoryTitle, command.scope.label, command.id,
                              bindings[command.id]?.label ?? "", command.defaultBinding?.label ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }
        table.reloadData()
        if let index = filtered.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        count.stringValue = "\(filtered.count) von \(registry.customizableCommands.count) Aktionen"
        updateControls()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search { reloadCommands() }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let command = filtered[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "category":
            text = command.categoryTitle == command.scope.label || command.scope == .application
                ? command.categoryTitle : "\(command.categoryTitle) · \(command.scope.label)"
        case "binding": text = registry.bindings[command.id]?.label ?? "Nicht belegt"
        case "default": text = command.defaultBinding?.label ?? "—"
        default: text = command.title
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        if tableColumn?.identifier.rawValue == "binding", registry.bindings[command.id] == nil {
            label.textColor = .secondaryLabelColor
        }
        label.toolTip = "\(command.title) · \(command.categoryTitle) · \(command.scope.label)"
        return label
    }

    private func updateControls() {
        let recording = recordingID != nil
        let command = selectedCommand
        selection.stringValue = command.map { "\($0.title) · \($0.categoryTitle)" } ?? "Aktion auswählen"
        assign.isEnabled = command != nil && !recording
        remove.isEnabled = command.flatMap { registry.bindings[$0.id] } != nil && !recording
        restore.isEnabled = command != nil && !recording
        resetAll.isEnabled = !recording
        search.isEnabled = !recording
        table.isEnabled = !recording
        capture.isHidden = !recording
        save.isHidden = !recording
        cancel.isHidden = !recording
        closeButton.isEnabled = !recording
        if !recording {
            message.textColor = .secondaryLabelColor
            message.stringValue = "Belegen per Doppelklick. Eine entfernte Belegung bleibt auch nach einem Neustart frei."
        }
    }

    @objc private func beginRecording() {
        guard recordingID == nil, let command = selectedCommand else { return }
        recordingID = command.id
        KeyboardCaptureState.isRecording = true
        capture.clear()
        save.isEnabled = false
        updateControls()
        message.stringValue = "Tastenkombination drücken. Auch Return, Tab und Escape können belegt werden. Mit den Schaltflächen speichern oder abbrechen."
        window?.makeFirstResponder(capture)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recordingID != nil, NSApp.keyWindow === self.window else { return event }
            self.capture.capture(event)
            return nil
        }
    }
    private func validate(_ binding: AppKeyBinding) {
        guard let id = recordingID else { return }
        if let conflict = registry.conflicts(for: binding, assigningTo: id) {
            message.textColor = .systemRed
            message.stringValue = "\(binding.label) ist bereits mit „\(conflict.title)“ (\(conflict.categoryTitle)) belegt. Diese Belegung dort zuerst entfernen oder eine andere Kombination wählen."
            save.isEnabled = false
        } else {
            message.textColor = .secondaryLabelColor
            message.stringValue = "\(binding.label) ist verfügbar. Zum Übernehmen auf „Speichern“ klicken."
            save.isEnabled = true
        }
    }
    @objc private func saveBinding() {
        guard let id = recordingID, let binding = capture.binding, save.isEnabled else { return }
        do {
            try registry.setBinding(binding, for: id)
            endRecording()
            didChange()
            reloadCommands(selecting: id)
        } catch {
            message.textColor = .systemRed
            message.stringValue = error.localizedDescription
            save.isEnabled = false
        }
    }
    @objc private func cancelRecording() { endRecording(); updateControls() }
    private func endRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        recordingID = nil
        KeyboardCaptureState.isRecording = false
        window?.makeFirstResponder(table)
    }
    @objc private func removeBinding() {
        guard let command = selectedCommand else { return }
        do {
            try registry.setBinding(nil, for: command.id)
            didChange()
            reloadCommands(selecting: command.id)
        } catch { showError(error.localizedDescription) }
    }
    @objc private func restoreBinding() {
        guard let command = selectedCommand else { return }
        if let binding = command.defaultBinding,
           let conflict = registry.conflicts(for: binding, assigningTo: command.id) {
            showError("Die Standardbelegung \(binding.label) ist bereits mit „\(conflict.title)“ (\(conflict.categoryTitle)) belegt. Diese Belegung zuerst entfernen.")
            return
        }
        registry.resetBinding(for: command.id)
        didChange()
        reloadCommands(selecting: command.id)
    }
    @objc private func resetBindings() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Alle Tastaturbelegungen zurücksetzen?"
        alert.informativeText = "Eigene Belegungen und entfernte Kürzel werden durch die Standardbelegung ersetzt."
        alert.addButton(withTitle: "Zurücksetzen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            self.registry.resetBindings()
            self.didChange()
            self.reloadCommands()
        }
    }
    private func showError(_ text: String) {
        message.textColor = .systemRed
        message.stringValue = text
    }
    @objc private func closeMapping() {
        guard recordingID == nil, let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.close(); finish() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if recordingID != nil { endRecording() }
        if let parent = sender.sheetParent { parent.endSheet(sender); return false }
        finish()
        return true
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        endRecording()
        didClose()
    }
}
