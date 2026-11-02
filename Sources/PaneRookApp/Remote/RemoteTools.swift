import PaneRookRemote
import PaneRookTasks
import AppKit
import PaneRookCore

/// Connections occupy their originating panel and transfer to the opposite panel.
final class RemoteTools {
    unowned let owner: any RemoteHost
    private var browsers: [RemoteBrowser] {
        [owner.leftPane, owner.rightPane].compactMap { $0.remoteContent as? RemoteBrowser }
    }
    private let bookmarkStore = ConnectionBookmarkStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PaneRook/connections.json"))
    private var connectionDialog: ConnectionEditorDialog?
    private var archiveDialog: ConnectionArchiveController?
    init(owner: any RemoteHost) { self.owner = owner }
    func savedBookmarks() throws -> [ConnectionBookmark] { try bookmarkStore.load() }
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess) {
        guard !owner.isPerformingOperation, owner.presentationWindow?.attachedSheet == nil else { return }
        owner.activate(pane)
        if bookmark.kind.provider.usesPassword { showConnection(bookmark.kind, pane: pane, bookmark: bookmark) }
        else {
            do {
                let timeout = UserDefaults.standard.object(forKey: "remoteTimeout") as? Int ?? 20
                openBrowser(try bookmark.connection(timeout: timeout), directory: bookmark.path, pane: pane)
            } catch { owner.showError(error) }
        }
    }
    func closeAll() { browsers.forEach { $0.disconnect() } }

    func connect(_ kind: RemoteProtocol, pane: any PanelAccess) {
        guard owner.canUseMenus else { return }
        showConnection(kind, pane: pane)
    }

    private func showConnection(_ kind: RemoteProtocol, pane: any PanelAccess, bookmark: ConnectionBookmark? = nil) {
        guard !owner.isPerformingOperation, let window = owner.presentationWindow, window.attachedSheet == nil else { return }
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
                self.owner.presentationWindow?.makeKeyAndOrderFront(nil)
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

    func showArchive(pane: any PanelAccess, kind: RemoteProtocol? = nil) {
        guard !owner.isPerformingOperation, let window = owner.presentationWindow, window.attachedSheet == nil else { return }
        let dialog = ConnectionArchiveController(store: bookmarkStore, initialKind: kind) { [weak self, weak pane] bookmark in
            guard let self, let pane else { return }
            self.archiveDialog = nil
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.owner.presentationWindow?.makeKeyAndOrderFront(nil)
                self.owner.activate(pane)
                guard let bookmark else { return }
                self.openSavedBookmark(bookmark, pane: pane)
            }
        }
        archiveDialog = dialog
        dialog.begin(on: window)
    }

    func openBrowser(_ connection: RemoteConnection, directory: String, pane: any PanelAccess,
                     runner: @escaping RemoteFileSystem.Runner = RemoteFileSystem.run) {
        let peer = pane === owner.leftPane ? owner.rightPane : owner.leftPane
        let browser = RemoteBrowser(connection: connection, peer: peer, tasks: owner.tasks, runner: runner)
        browser.onActivate = { [weak pane] in pane?.activate() }
        browser.onClose = { [weak pane, weak browser] in
            guard let pane, let browser, pane.remoteContent === browser else { return }
            pane.showRemoteContent(nil)
        }
        browser.onStateChanged = { [weak pane] in pane?.remoteStateDidChange() }
        pane.showRemoteContent(browser)
        owner.activate(pane)
        browser.show(directory: directory)
    }

    func showConnections() {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let alert = NSAlert(); alert.messageText = "Aktive VFS-Verbindungen"
        let entries = browsers.sorted { $0.displayName < $1.displayName }
        if entries.isEmpty {
            alert.informativeText = "Keine Verbindung geöffnet."
            alert.addButton(withTitle: "Schließen"); alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        popup.addItems(withTitles: entries.map(\.displayName))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Anzeigen"); alert.addButton(withTitle: "Trennen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { response in
            guard entries.indices.contains(popup.indexOfSelectedItem) else { return }
            let browser = entries[popup.indexOfSelectedItem]
            DispatchQueue.main.async {
                if response == .alertFirstButtonReturn { browser.onActivate?(); browser.focus() }
                else if response == .alertSecondButtonReturn { browser.disconnect() }
            }
        }
    }

    func settingsChanged() {
        browsers.forEach { $0.refresh() }
    }
}

final class RemoteBrowser: NSViewController, RemotePanelContent, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var viewController: NSViewController { self }
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    private weak var peer: (any PanelAccess)?
    private let fileSystem: RemoteFileSystem
    private let tasks: TaskCenter
    private var queuedTask: UUID?
    private let table = FileTable()
    private let surface = PaneSurface()
    var isActive = false { didSet { surface.isActive = isActive } }
    private let pathField = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let workQueue = DispatchQueue(label: "app.panerook.remote", qos: .userInitiated)
    private var cancellation: RemoteCancellation?
    private var directory = "/"
    private var entries: [RemoteEntry] = []
    private var buttons: [NSButton] = []
    private var disconnected = false
    private var busy: Bool { cancellation != nil }
    var isBusy: Bool { busy }
    var hasSelection: Bool { !selection.isEmpty }
    var canDownload: Bool { !busy && hasSelection && peer?.remoteContent == nil && peer?.isArchiveDirectory == false && peer?.mode != .network }
    var canUpload: Bool { !busy && peer?.remoteContent == nil && peer?.isArchiveDirectory == false && peer?.selectedFiles.isEmpty == false }
    var displayName: String { fileSystem.connection.displayName }

    init(connection: RemoteConnection, peer: any PanelAccess, tasks: TaskCenter,
         runner: @escaping RemoteFileSystem.Runner = RemoteFileSystem.run) {
        self.tasks = tasks
        self.peer = peer
        fileSystem = RemoteFileSystem(connection: connection, runner: runner)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func loadView() { buildView() }
    func focus() { view.window?.makeFirstResponder(table) }
    func focusPath() { view.window?.makeFirstResponder(pathField); pathField.selectText(nil) }
    func refresh() { reload() }
    func openSelection() { openSelected() }
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        cancelRemoteOperation()
        onClose?()
    }

    private func buildView() {
        let background = AppStyle.background(); view = background
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 10; stack.alignment = .leading; stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 10), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12), stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14)])
        let connection = NSTextField(labelWithString: displayName)
        connection.font = .systemFont(ofSize: 12, weight: .semibold); connection.lineBreakMode = .byTruncatingMiddle
        connection.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let close = NSButton(title: "Trennen", target: self, action: #selector(disconnectClicked))
        AppStyle.configureButton(close); close.controlSize = .small
        let header = NSStackView(views: [connection, NSView(), close]); header.spacing = 8
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let pathRow = NSStackView(); pathRow.spacing = 8
        let up = button("", #selector(goUp)); up.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Übergeordneter Ordner")
        pathRow.addArrangedSubview(up); AppStyle.configureField(pathField); pathField.target = self; pathField.action = #selector(pathEntered); pathField.setAccessibilityLabel("Remote-Pfad")
        pathField.delegate = self
        pathRow.addArrangedSubview(pathField); stack.addArrangedSubview(pathRow); pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        table.didFocus = { [weak self] in self?.onActivate?() }
        table.handleKey = { [weak self] event in
            guard let self, self.view.window?.attachedSheet == nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if self.busy && (event.keyCode == 53 || (event.keyCode == 5 && flags == .control)) {
                self.cancelRemoteOperation(); return true
            }
            return self.onKey?(event) ?? false
        }
        table.setAccessibilityLabel("Remote-Dateiliste")
        table.style = .inset; table.rowHeight = 28; table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        for (id, title, width) in [("name", "Name", 430.0), ("size", "Größe", 100.0), ("type", "Art", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 150 : 75
            if id == "name" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        scroll.documentView = table
        surface.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 5), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -5), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 5), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -5)])
        stack.addArrangedSubview(surface); surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        surface.setContentHuggingPriority(.defaultLow, for: .vertical)
        let transfers = NSStackView(views: [button("Laden", #selector(download)), button("Hochladen …", #selector(upload))])
        transfers.spacing = 8
        let actions = NSStackView(views: [button("Ordner", #selector(makeDirectory)), button("Löschen", #selector(deleteSelected)), button("Aktualisieren", #selector(reload))])
        actions.spacing = 8
        stack.addArrangedSubview(transfers); stack.addArrangedSubview(actions)
        let statusRow = NSStackView(); statusRow.spacing = 8
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        cancel.target = self; cancel.action = #selector(cancelRemoteOperation); AppStyle.configureButton(cancel); cancel.controlSize = .small; cancel.isHidden = true
        statusRow.addArrangedSubview(spinner); statusRow.addArrangedSubview(status); statusRow.addArrangedSubview(NSView()); statusRow.addArrangedSubview(cancel)
        stack.addArrangedSubview(statusRow); statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action); AppStyle.configureButton(result); result.controlSize = .small; buttons.append(result); return result
    }
    @objc private func disconnectClicked() { disconnect() }
    func show(directory: String) { navigate(directory); focus() }
    private func navigate(_ path: String) {
        guard !busy, !disconnected else { return }
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
    func controlTextDidBeginEditing(_ obj: Notification) { onActivate?() }
    @objc func goUp() { navigate((directory as NSString).deletingLastPathComponent) }
    @objc private func openSelected() {
        guard !busy, let entry = selection.first, entry.isDirectory, !entry.isSymbolicLink else { return }
        navigate(directory + "/" + entry.name)
    }
    private var selection: [RemoteEntry] { table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil } }
    @objc func download() {
        guard !busy, let peer, !selection.isEmpty else { return }
        guard peer.remoteContent == nil, !peer.isArchiveDirectory, peer.mode != .network else { showArchiveTransferError(); return }
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
    @objc func upload() {
        guard !busy, let peer, let window = view.window else { return }
        guard peer.remoteContent == nil, !peer.isArchiveDirectory, peer.mode != .network else { showArchiveTransferError(); return }
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
    @objc func makeDirectory() {
        guard !busy, let window = view.window else { return }
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
    @objc func deleteSelected() {
        guard !busy, !selection.isEmpty, let window = view.window else { return }
        let selected = selection, path = directory
        let alert = NSAlert(); alert.alertStyle = .warning
        let provider = fileSystem.connection.kind.provider
        alert.messageText = "\(selected.count) " + provider.deleteTitle
        alert.informativeText = provider.deleteNotice
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
    @objc private func cancelRemoteOperation() {
        if let queuedTask { tasks.cancel(queuedTask) }
        else { cancellation?.cancel() }
    }
    private func performQueued<Value>(_ title: String, paths: [String],
                                      work: @escaping (RemoteCancellation, @escaping (OperationProgress) -> Void) throws -> Value,
                                      completion: @escaping (Value) -> Void) {
        guard !busy, !disconnected else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false
        cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        onStateChanged?()
        queuedTask = tasks.submit(title: title, detail: displayName + "\n" + paths.joined(separator: "\n") + "\nBereits übertragene Remote-Einträge bleiben bei Abbruch erhalten.",
            cancellation: { token.cancel() }, work: { report in try work(token, report) }, completion: { [weak self, weak peer] result in
                // A disconnected browser can be released before this main-queue completion.
                peer?.refreshAfterTask()
                guard let self else { return }
                self.queuedTask = nil; self.cancellation = nil
                self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true
                self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
                switch result {
                case .success(let value): if !self.disconnected { completion(value) }
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                self.onStateChanged?()
            })
    }
    private func perform<Value>(_ title: String, work: @escaping (RemoteCancellation) throws -> Value, completion: @escaping (Value) -> Void) {
        guard !busy, !disconnected else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false; cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        onStateChanged?()
        workQueue.async { [weak self] in
            let result = Result { try work(token) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancellation = nil; self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true; self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
                guard !self.disconnected else { return }
                switch result {
                case .success(let value): completion(value)
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    if !token.isCancelled { self.showError(error) }
                    self.peer?.refreshAfterTask()
                }
                self.onStateChanged?()
            }
        }
    }
    private func showError(_ error: Error) {
        guard let window = view.window, window.attachedSheet == nil else { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = error.localizedDescription
        alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { onStateChanged?() }
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

protocol RemoteHost: PanelPresenting, PanelPairProviding, ErrorPresenting, TaskProviding {
    var isPerformingOperation: Bool { get }
}
