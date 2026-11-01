import AppKit
import PaneRookCore

final class ConnectionArchiveController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: ConnectionBookmarkStore
    private let completion: (ConnectionBookmark?) -> Void
    private let search = NSSearchField()
    private let protocolFilter = NSPopUpButton()
    private let table = FileTable()
    private let empty = NSTextField(labelWithString: "Keine gespeicherten Verbindungen")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let edit = NSButton(title: "Bearbeiten …", target: nil, action: nil)
    private let remove = NSButton(title: "Entfernen", target: nil, action: nil)
    private let undo = NSButton(title: "Widerrufen", target: nil, action: nil)
    private let connect = NSButton(title: "Verbinden", target: nil, action: nil)
    private var bookmarks: [ConnectionBookmark] = []
    private var visible: [ConnectionBookmark] = []
    private var deleted: [ConnectionBookmark] = []
    private var editor: ConnectionEditorDialog?
    private var chosen: ConnectionBookmark?
    private var creationKind: RemoteProtocol
    private let kinds: [RemoteProtocol] = [.sftp, .shell, .ftp]
    private var keyMonitor: Any?

    init(store: ConnectionBookmarkStore, initialKind: RemoteProtocol? = nil, completion: @escaping (ConnectionBookmark?) -> Void) {
        self.store = store; self.completion = completion
        creationKind = initialKind ?? .sftp
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 730, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Verbindungsarchiv"; panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.closeArchive(nil) }
        panel.contentView = AppStyle.background(material: .sheet)
        search.placeholderString = "Verbindungen suchen"
        search.setAccessibilityLabel("Verbindungen suchen")
        search.delegate = self
        protocolFilter.addItems(withTitles: ["Alle Protokolle"] + kinds.map(ConnectionEditorDialog.title))
        protocolFilter.setAccessibilityLabel("Protokollfilter")
        protocolFilter.target = self; protocolFilter.action = #selector(filterChanged)
        if let initialKind { protocolFilter.selectItem(at: (kinds.firstIndex(of: initialKind) ?? 0) + 1) }
        protocolFilter.widthAnchor.constraint(equalToConstant: 155).isActive = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filter = NSStackView(views: [search, protocolFilter]); filter.spacing = 10
        table.dataSource = self; table.delegate = self; table.style = .inset
        table.rowHeight = 30; table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.target = self; table.doubleAction = #selector(connectSelected)
        table.setAccessibilityLabel("Gespeicherte Verbindungen")
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.handleKey = { [weak self] event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  event.keyCode == 36 || event.keyCode == 76 else { return false }
            self?.connectSelected(); return true
        }
        for (id, title, width) in [("name", "Name", 230.0), ("kind", "Protokoll", 90.0), ("server", "Server", 350.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "kind" ? 80 : 130
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = NSView(); scroll.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(scroll)
        empty.font = .systemFont(ofSize: 13); empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        errorLabel.font = .systemFont(ofSize: 12); errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        errorLabel.setAccessibilityLabel("Fehler im Verbindungsarchiv")
        let new = NSButton(title: "Neu …", target: self, action: #selector(newBookmark))
        new.keyEquivalent = "n"; new.keyEquivalentModifierMask = .command
        edit.target = self; edit.action = #selector(editSelected)
        edit.keyEquivalent = "e"; edit.keyEquivalentModifierMask = .command
        remove.target = self; remove.action = #selector(removeSelected)
        remove.keyEquivalent = "\u{8}"; remove.keyEquivalentModifierMask = .command
        undo.target = self; undo.action = #selector(undoRemoval)
        undo.keyEquivalent = "z"; undo.keyEquivalentModifierMask = .command; undo.isHidden = true
        connect.target = self; connect.action = #selector(connectSelected)
        connect.keyEquivalent = "\r"; connect.keyEquivalentModifierMask = []
        let close = NSButton(title: "Schließen", target: self, action: #selector(closeArchive(_:)))
        close.keyEquivalent = "\u{1b}"; close.keyEquivalentModifierMask = []
        for button in [new, edit, remove, undo, connect, close] { AppStyle.configureButton(button); button.controlSize = .small }
        let footer = NSStackView(views: [new, edit, remove, undo, NSView(), close, connect]); footer.spacing = 8
        let root = NSStackView(views: [filter, content, errorLabel, footer])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor)
        ])
        for child in root.arrangedSubviews { child.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true }
        let keyViews: [NSView] = [search, protocolFilter, table, new, edit, remove, undo, close, connect]
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
        panel.initialFirstResponder = table
        reload()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return event }
            // Handle archive actions before the main window's menu equivalents.
            // Text fields retain their normal deletion and text-undo behavior.
            let editingText = self.window?.firstResponder is NSTextView
            switch event.keyCode {
            case 45: self.newBookmark() // Cmd-N
            case 14: self.editSelected() // Cmd-E
            case 51 where !editingText: self.removeSelected() // Cmd-Backspace
            case 6 where !editingText && !self.deleted.isEmpty: self.undoRemoval() // Cmd-Z
            default: return event
            }
            return nil
        }
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in completion(chosen) }
    }
    private var selection: ConnectionBookmark? { visible.indices.contains(table.selectedRow) ? visible[table.selectedRow] : nil }
    private func reload(select id: UUID? = nil) {
        do { bookmarks = try store.load(); errorLabel.isHidden = true }
        catch { bookmarks = []; showError(error) }
        filter(select: id)
    }
    private func filter(select id: UUID? = nil) {
        let selectedID = id ?? selection?.id
        let kind = protocolFilter.indexOfSelectedItem > 0 ? kinds[protocolFilter.indexOfSelectedItem - 1] : nil
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = bookmarks.filter { bookmark in
            (kind == nil || bookmark.kind == kind) && (query.isEmpty || [bookmark.name, bookmark.host, bookmark.user, bookmark.path, bookmark.kind.rawValue].contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.host.localizedStandardCompare($1.host) == .orderedAscending : order == .orderedAscending
        }
        table.reloadData()
        if let index = visible.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !visible.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        empty.stringValue = bookmarks.isEmpty ? "Keine gespeicherten Verbindungen" : "Keine passenden Verbindungen"
        empty.isHidden = !visible.isEmpty
        updateButtons()
    }
    func controlTextDidChange(_ obj: Notification) { filter() }
    @objc private func filterChanged() { filter() }
    private func updateButtons() {
        edit.isEnabled = selection != nil; remove.isEnabled = selection != nil; connect.isEnabled = selection != nil
        undo.isHidden = deleted.isEmpty
    }
    @objc private func newBookmark() {
        let index = protocolFilter.indexOfSelectedItem
        presentEditor(nil, kind: index > 0 ? kinds[index - 1] : creationKind)
    }
    @objc private func editSelected() { if let selected = selection { presentEditor(selected, kind: selected.kind) } }
    private func presentEditor(_ bookmark: ConnectionBookmark?, kind: RemoteProtocol) {
        guard let window, window.attachedSheet == nil else { return }
        let editor = ConnectionEditorDialog(kind: kind, bookmark: bookmark, purpose: .bookmark,
            saveBookmark: { [store] in _ = try store.upsert($0) }) { [weak self] result in
                guard let self else { return }
                self.editor = nil
                if case .saved(let bookmark) = result {
                    self.creationKind = bookmark.kind
                    self.search.stringValue = ""
                    if self.protocolFilter.indexOfSelectedItem > 0 {
                        self.protocolFilter.selectItem(at: (self.kinds.firstIndex(of: bookmark.kind) ?? 0) + 1)
                    }
                    self.reload(select: bookmark.id)
                }
                self.window?.makeFirstResponder(self.table)
            }
        self.editor = editor; editor.begin(on: window)
    }
    @objc private func removeSelected() {
        guard let selected = selection, window?.attachedSheet == nil else { return }
        do {
            try store.remove(id: selected.id)
            deleted.append(selected); reload()
        } catch { showError(error) }
    }
    @objc private func undoRemoval() {
        guard let bookmark = deleted.last, window?.attachedSheet == nil else { return }
        do {
            try store.upsert(bookmark); deleted.removeLast()
            search.stringValue = ""; protocolFilter.selectItem(at: 0); reload(select: bookmark.id)
        } catch { showError(error) }
    }
    @objc private func connectSelected() {
        guard let selected = selection, let window, window.attachedSheet == nil else { return }
        chosen = selected
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: .OK) }
    }
    @objc private func closeArchive(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        chosen = nil
        if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
    }
    private func showError(_ error: Error) {
        errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let bookmark = visible[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "kind": value = bookmark.kind == .shell ? "Shell" : bookmark.kind.rawValue.uppercased()
        case "server": value = (bookmark.user.isEmpty ? "" : bookmark.user + "@") + bookmark.host + ":" + String(bookmark.port)
        default: value = bookmark.name
        }
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = value + "\n" + bookmark.path
        return field
    }
}
