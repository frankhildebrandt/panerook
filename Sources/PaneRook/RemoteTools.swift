import AppKit
import PaneRookCore

/// Remote browsers have their own focus and operation lifetime; local panels remain usable.
final class RemoteTools {
    enum ConnectionKind { case ftp, sftp, shell, nextcloud }
    private unowned let owner: CommanderController
    private var browsers: [UUID: RemoteBrowser] = [:]
    private let bookmarkStore = ConnectionBookmarkStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PaneRook/connections.json"))
    private var connectionDialog: ConnectionEditorDialog?
    private var archiveDialog: ConnectionArchiveController?
    init(owner: CommanderController) { self.owner = owner }
    func savedBookmarks() throws -> [ConnectionBookmark] { try bookmarkStore.load() }
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: PaneController) {
        guard !owner.isPerformingOperation, owner.view.window?.attachedSheet == nil else { return }
        owner.activate(pane)
        if bookmark.kind == .ftp || bookmark.kind == .nextcloud { showConnection(bookmark.kind, pane: pane, bookmark: bookmark) }
        else {
            do {
                let timeout = UserDefaults.standard.object(forKey: "remoteTimeout") as? Int ?? 20
                openBrowser(try bookmark.connection(timeout: timeout), directory: bookmark.path, pane: pane)
            } catch { owner.showError(error) }
        }
    }
    func closeAll() { for browser in Array(browsers.values) { browser.window.performClose(nil) } }

    func connect(_ kind: ConnectionKind, pane: PaneController) {
        guard owner.canUseMenus else { return }
        let remoteKind: RemoteProtocol
        switch kind {
        case .ftp: remoteKind = .ftp
        case .sftp: remoteKind = .sftp
        case .shell: remoteKind = .shell
        case .nextcloud: remoteKind = .nextcloud
        }
        showConnection(remoteKind, pane: pane)
    }

    private func showConnection(_ kind: RemoteProtocol, pane: PaneController, bookmark: ConnectionBookmark? = nil) {
        guard !owner.isPerformingOperation, let window = owner.view.window, window.attachedSheet == nil else { return }
        var bookmarks: [ConnectionBookmark] = []
        var archiveError: String?
        do { bookmarks = try bookmarkStore.load() }
        catch { archiveError = "Archiv konnte nicht geladen werden: " + error.localizedDescription }
        let dialog = ConnectionEditorDialog(kind: kind, bookmark: bookmark, bookmarks: bookmarks,
            purpose: .connection, archiveError: archiveError, allowsArchive: true,
            saveBookmark: { [bookmarkStore] in _ = try bookmarkStore.upsert($0) }) { [weak self, weak pane] outcome in
            guard let self, let pane else { return }
            self.connectionDialog = nil
            // AppKit finishes detaching the old sheet after its completion returns.
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.owner.view.window?.makeKeyAndOrderFront(nil)
                self.owner.activate(pane)
                switch outcome {
                case .connect(let connection, let path): self.openBrowser(connection, directory: path, pane: pane)
                case .archive: self.showArchive(pane: pane, kind: kind)
                default: break
                }
            }
        }
        connectionDialog = dialog
        dialog.begin(on: window)
    }

    func showArchive(pane: PaneController, kind: RemoteProtocol? = nil) {
        guard !owner.isPerformingOperation, let window = owner.view.window, window.attachedSheet == nil else { return }
        let dialog = ConnectionArchiveController(store: bookmarkStore, initialKind: kind) { [weak self, weak pane] bookmark in
            guard let self, let pane else { return }
            self.archiveDialog = nil
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.owner.view.window?.makeKeyAndOrderFront(nil)
                self.owner.activate(pane)
                guard let bookmark else { return }
                self.openSavedBookmark(bookmark, pane: pane)
            }
        }
        archiveDialog = dialog
        dialog.begin(on: window)
    }

    private func openBrowser(_ connection: RemoteConnection, directory: String, pane: PaneController) {
        let browser = RemoteBrowser(connection: connection, peer: pane, tasks: owner.tasks)
        let id = UUID(); browsers[id] = browser
        browser.onClose = { [weak self] in self?.browsers.removeValue(forKey: id) }
        browser.show(directory: directory)
    }

    func showConnections() {
        guard owner.canUseMenus, let window = owner.view.window else { return }
        let alert = NSAlert(); alert.messageText = "Aktive VFS-Verbindungen"
        let entries = Array(browsers.values).sorted { $0.window.title < $1.window.title }
        if entries.isEmpty {
            alert.informativeText = "Keine Verbindung geöffnet."
            alert.addButton(withTitle: "Schließen"); alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        popup.addItems(withTitles: entries.map { $0.window.title })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Anzeigen"); alert.addButton(withTitle: "Trennen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { response in
            guard entries.indices.contains(popup.indexOfSelectedItem) else { return }
            let browser = entries[popup.indexOfSelectedItem]
            if response == .alertFirstButtonReturn { browser.window.makeKeyAndOrderFront(nil) }
            else if response == .alertSecondButtonReturn { browser.window.performClose(nil) }
        }
    }

    func configure() {
        guard owner.canUseMenus, let window = owner.view.window else { return }
        let alert = NSAlert(); alert.messageText = "Virtuelles Dateisystem"
        let timeout = NSTextField(string: String(max(3, UserDefaults.standard.integer(forKey: "remoteTimeout") == 0 ? 20 : UserDefaults.standard.integer(forKey: "remoteTimeout"))))
        AppStyle.configureField(timeout)
        let hidden = NSButton(checkboxWithTitle: "Versteckte Remote-Dateien anzeigen", target: nil, action: nil)
        hidden.state = UserDefaults.standard.bool(forKey: "remoteShowHidden") ? .on : .off
        alert.accessoryView = Self.form([("Verbindungs-Timeout (s)", timeout), ("", hidden)])
        alert.addButton(withTitle: "Speichern"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(max(3, min(Int(timeout.stringValue) ?? 20, 300)), forKey: "remoteTimeout")
            UserDefaults.standard.set(hidden.state == .on, forKey: "remoteShowHidden")
            self?.browsers.values.forEach { $0.reload() }
        }
    }

    private static func form(_ rows: [(String, NSView)]) -> NSView {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        for (title, control) in rows {
            let row = NSStackView(); row.spacing = 10
            let label = NSTextField(labelWithString: title); label.font = .systemFont(ofSize: 12); label.widthAnchor.constraint(equalToConstant: 145).isActive = true
            row.addArrangedSubview(label); row.addArrangedSubview(control); control.widthAnchor.constraint(equalToConstant: 290).isActive = true
            stack.addArrangedSubview(row)
        }
        stack.frame.size = NSSize(width: 445, height: CGFloat(rows.count * 36))
        return stack
    }
}

private final class RemoteWindow: NSWindow {
    var onKey: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool { onKey?(event) == true || super.performKeyEquivalent(with: event) }
}

private final class RemoteTable: NSTableView {
    override func keyDown(with event: NSEvent) {
        if handleListNavigation(event) { return }
        super.keyDown(with: event)
    }
}

private final class RemoteBrowser: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: RemoteWindow
    var onClose: (() -> Void)?
    private weak var peer: PaneController?
    private let fileSystem: RemoteFileSystem
    private let tasks: TaskCenter
    private var queuedTask: UUID?
    private let table = RemoteTable()
    private let pathField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let workQueue = DispatchQueue(label: "app.panerook.remote", qos: .userInitiated)
    private var cancellation: RemoteCancellation?
    private var directory = "/"
    private var entries: [RemoteEntry] = []
    private var buttons: [NSButton] = []
    private var busy: Bool { cancellation != nil }

    init(connection: RemoteConnection, peer: PaneController, tasks: TaskCenter) {
        self.tasks = tasks
        self.peer = peer; fileSystem = RemoteFileSystem(connection: connection)
        window = RemoteWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = connection.displayName; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 380); window.delegate = self; window.center()
        window.onKey = { [weak self] in self?.key($0) ?? false }
        buildView()
    }

    private func buildView() {
        let background = AppStyle.background(); window.contentView = background
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading; stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12), stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14)])
        let pathRow = NSStackView(); pathRow.spacing = 8
        let up = button("", #selector(goUp)); up.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Übergeordneter Ordner")
        pathRow.addArrangedSubview(up); AppStyle.configureField(pathField); pathField.target = self; pathField.action = #selector(pathEntered); pathField.setAccessibilityLabel("Remote-Pfad")
        pathRow.addArrangedSubview(pathField); stack.addArrangedSubview(pathRow); pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        table.style = .inset; table.rowHeight = 28; table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        for (id, title, width) in [("name", "Name", 430.0), ("size", "Größe", 100.0), ("type", "Art", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 150 : 75
            if id == "name" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        scroll.documentView = table
        let surface = PaneSurface(); surface.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 5), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -5), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 5), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -5)])
        stack.addArrangedSubview(surface); surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        let actions = NSStackView(); actions.spacing = 8
        for (title, action) in [("F5 Laden", #selector(download)), ("Hochladen …", #selector(upload)), ("F7 Ordner", #selector(makeDirectory)), ("F8 Löschen", #selector(deleteSelected)), ("Aktualisieren", #selector(reload))] {
            actions.addArrangedSubview(button(title, action))
        }
        stack.addArrangedSubview(actions)
        let statusRow = NSStackView(); statusRow.spacing = 8
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        cancel.target = self; cancel.action = #selector(cancelOperation); AppStyle.configureButton(cancel); cancel.controlSize = .small; cancel.isHidden = true
        statusRow.addArrangedSubview(spinner); statusRow.addArrangedSubview(status); statusRow.addArrangedSubview(NSView()); statusRow.addArrangedSubview(cancel)
        stack.addArrangedSubview(statusRow); statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action); AppStyle.configureButton(result); result.controlSize = .small; buttons.append(result); return result
    }
    func show(directory: String) { window.makeKeyAndOrderFront(nil); navigate(directory); window.makeFirstResponder(table) }
    private func navigate(_ path: String) {
        guard !busy else { return }
        do {
            let next = try RemoteFileSystem.normalizedPath(path, relativeTo: directory)
            perform("Verzeichnis wird gelesen", work: { token in try self.fileSystem.list(next, cancellation: token) }) { [weak self] result in
                guard let self else { return }
                self.directory = next; self.pathField.stringValue = next
                self.entries = result.filter { UserDefaults.standard.bool(forKey: "remoteShowHidden") || !$0.name.hasPrefix(".") }
                self.table.reloadData(); self.status.stringValue = "\(self.entries.count) Einträge"
                if !self.entries.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            }
        } catch { showError(error) }
    }
    @objc func reload() { navigate(directory) }
    @objc private func pathEntered() { navigate(pathField.stringValue) }
    @objc private func goUp() { navigate((directory as NSString).deletingLastPathComponent) }
    @objc private func openSelected() {
        guard !busy, let entry = selection.first, entry.isDirectory, !entry.isSymbolicLink else { return }
        navigate(directory + "/" + entry.name)
    }
    private var selection: [RemoteEntry] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil } }
    @objc private func download() {
        guard !busy, let peer, !selection.isEmpty else { return }
        guard !peer.isArchiveDirectory else { showArchiveTransferError(); return }
        let selected = selection, destination = peer.directory, path = directory
        performQueued("Laden nach \(destination.path)", paths: selected.map { path + "/" + $0.name }, work: { token, report in
            for (index, entry) in selected.enumerated() {
                try token.check()
                report(OperationProgress(completedItems: index, totalItems: selected.count, currentPath: entry.name))
                try self.fileSystem.download(entry, from: path, to: destination.appendingPathComponent(entry.name), cancellation: token)
                report(OperationProgress(completedItems: index + 1, totalItems: selected.count, currentPath: entry.name))
            }
        }) { [weak peer, weak self] _ in peer?.refreshAfterTask(); self?.status.stringValue = "\(selected.count) Einträge geladen" }
    }
    @objc private func upload() {
        guard !busy, let peer else { return }
        guard !peer.isArchiveDirectory else { showArchiveTransferError(); return }
        let sources = peer.selectedFiles, path = directory
        guard !sources.isEmpty else { status.stringValue = "Zuerst Dateien im lokalen Panel auswählen."; return }
        let alert = NSAlert(); alert.messageText = "\(sources.count) Einträge hochladen?"; alert.informativeText = "\(peer.directory.path) → \(directory)"
        alert.addButton(withTitle: "Hochladen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performQueued("Dateien hochladen", paths: sources.map(\.path), work: { token, report in
                for (index, source) in sources.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: sources.count, currentPath: source.path))
                    try self.fileSystem.upload(source, to: path, cancellation: token)
                    report(OperationProgress(completedItems: index + 1, totalItems: sources.count, currentPath: source.path))
                }
            }) { [weak self] _ in self?.reload() }
        }
    }
    @objc private func makeDirectory() {
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = "Remote-Ordner anlegen"
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 28)); AppStyle.configureField(name); name.setAccessibilityLabel("Ordnername")
        alert.accessoryView = name; alert.addButton(withTitle: "Anlegen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts(); alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                try FileActions.validateName(name.stringValue)
                let path = try RemoteFileSystem.normalizedPath(name.stringValue, relativeTo: self.directory)
                self.perform("Ordner wird angelegt", work: { try self.fileSystem.createDirectory(path, cancellation: $0) }) { [weak self] _ in self?.reload() }
            } catch { self.showError(error) }
        }
    }
    @objc private func deleteSelected() {
        guard !busy, !selection.isEmpty else { return }
        let selected = selection, path = directory
        let alert = NSAlert(); alert.alertStyle = .warning
        if fileSystem.connection.kind == .nextcloud {
            alert.messageText = "\(selected.count) Nextcloud-Einträge löschen?"
            alert.informativeText = "Ordner werden mit ihrem Inhalt gelöscht. Eine Wiederherstellung hängt vom Papierkorb und den Einstellungen der Nextcloud-Instanz ab."
        } else {
            alert.messageText = "\(selected.count) Remote-Einträge endgültig löschen?"
            alert.informativeText = "Ordner werden mit ihrem Inhalt gelöscht. PaneRook verwendet dabei keinen Papierkorb."
        }
        alert.addButton(withTitle: "Löschen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.performQueued("Remote-Dateien löschen", paths: selected.map { path + "/" + $0.name }, work: { token, report in
                for (index, entry) in selected.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: selected.count, currentPath: entry.name))
                    try self.fileSystem.remove(entry, from: path, cancellation: token)
                    report(OperationProgress(completedItems: index + 1, totalItems: selected.count, currentPath: entry.name))
                }
            }) { [weak self] _ in self?.reload() }
        }
    }
    private func showArchiveTransferError() {
        showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Remote-Transfers benötigen einen lokalen Ordner. Bitte Archiveinträge zuerst dorthin kopieren beziehungsweise vor dem Download einen lokalen Ordner im Panel öffnen."]))
    }
    @objc private func cancelOperation() {
        if let queuedTask { tasks.cancel(queuedTask) }
        else { cancellation?.cancel() }
    }
    private func performQueued<Value>(_ title: String, paths: [String],
                                      work: @escaping (RemoteCancellation, @escaping (OperationProgress) -> Void) throws -> Value,
                                      completion: @escaping (Value) -> Void) {
        guard !busy else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false
        cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        queuedTask = tasks.submit(title: title, detail: window.title + "\n" + paths.joined(separator: "\n") + "\nBereits übertragene Remote-Einträge bleiben bei Abbruch erhalten.",
            cancellation: { token.cancel() }, work: { report in try work(token, report) }, completion: { [weak self] result in
                guard let self else { return }
                self.queuedTask = nil; self.cancellation = nil
                self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true
                self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
                // Refresh local panels even if this browser was closed during work.
                self.peer?.refreshAfterTask()
                switch result {
                case .success(let value): if self.window.isVisible { completion(value) }
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
            })
    }
    private func perform<Value>(_ title: String, work: @escaping (RemoteCancellation) throws -> Value, completion: @escaping (Value) -> Void) {
        guard !busy else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false; cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        workQueue.async { [weak self] in
            let result = Result { try work(token) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancellation = nil; self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true; self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
                guard self.window.isVisible else { return }
                switch result {
                case .success(let value): completion(value)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    if !token.isCancelled { self.showError(error) }
                    self.peer?.refreshAfterTask()
                }
            }
        }
    }
    private func showError(_ error: Error) {
        guard window.attachedSheet == nil else { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = error.localizedDescription
        alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
    }
    private func key(_ event: NSEvent) -> Bool {
        guard window.attachedSheet == nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 || (event.keyCode == 5 && flags == .control) { if busy { cancelOperation(); return true }; return false }
        if flags == .command && event.keyCode == 37 { window.makeFirstResponder(pathField); pathField.selectText(nil); return true }
        guard flags.isEmpty, window.firstResponder === table else { return false }
        switch event.keyCode {
        case 36, 76: openSelected()
        case 51, 117: goUp()
        case 96: download()
        case 98: makeDirectory()
        case 100: deleteSelected()
        case 109: if busy { cancelOperation() } else { window.performClose(nil) }
        default: return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) { cancelOperation(); onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let text: String
        switch id {
        case "size": text = entry.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        case "type": text = entry.isSymbolicLink ? "Link" : entry.isDirectory ? "Ordner" : entry.isRegularFile ? "Datei" : "Spezialdatei"
        default: text = entry.name
        }
        let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
