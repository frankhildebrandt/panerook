import AppKit
import Darwin
import PaneRookCore
import PaneRookRemote
import PaneRookTasks

final class RemoteBrowser: NSViewController, RemotePanelContent, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var viewController: NSViewController { self }
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    weak var peer: (any PanelAccess)?
    let fileSystem: RemoteFileSystem
    let tasks: TaskCenter
    var queuedTask: UUID?
    let table = FileTable()
    let surface = PaneSurface()
    var isActive = false { didSet { surface.isActive = isActive } }
    let pathField = NSTextField()
    let status = NSTextField(labelWithString: "")
    let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    let workQueue = DispatchQueue(label: "app.panerook.remote", qos: .userInitiated)
    var cancellation: RemoteCancellation?
    var directory = "/"
    var entries: [RemoteEntry] = []
    var allEntries: [RemoteEntry] = []
    var history: [String] = []
    var hasLoadedDirectory = false
    var pendingRefresh = false
    var showHidden = false { didSet { if isViewLoaded { rebuildListing() } } }
    var filterPattern = ""
    var sortKey = "name"
    var sortAscending = true
    var isBriefListing = false
    var iconsVisible = true
    let back = NSButton()
    let favoritesButton = NSPopUpButton()
    var themeObserver: NSObjectProtocol?
    var buttons: [NSButton] = []
    var disconnected = false
    var busy: Bool { cancellation != nil }
    var isBusy: Bool { busy }
    var hasSelection: Bool { !selection.isEmpty }
    var canDownload: Bool {
        guard !busy, !disconnected, hasSelection, let peer else { return false }
        if let remote = peer.remoteContent as? RemoteBrowser { return !remote.isBusy && !remote.disconnected }
        return peer.remoteContent == nil && !peer.isArchiveDirectory && peer.mode != .network
    }
    var canUpload: Bool { !busy && !disconnected && peer?.remoteContent == nil && peer?.isArchiveDirectory == false && peer?.selectedFiles.isEmpty == false }
    var connectionBookmark: ConnectionBookmark?
    private let workspaceConnectionID = UUID()
    var workspaceBookmark: ConnectionBookmark? {
        let connection = fileSystem.connection
        return try? ConnectionBookmark(id: connectionBookmark?.id ?? workspaceConnectionID, name: connectionBookmark?.name ?? displayName, kind: connection.kind, host: connection.host,
            port: connection.port, user: connection.user, path: directory, identityFile: connection.identityFile)
    }
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
    func refresh() {
        if busy { pendingRefresh = true } else { reload() }
    }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    func openSelection() { openSelected() }
    func disconnect() {
        guard !disconnected else { return }
        disconnected = true
        cancelRemoteOperation()
        onClose?()
    }

    func buildView() {
        view = surface
        let navigation = NSStackView()
        navigation.orientation = .horizontal; navigation.alignment = .centerY; navigation.spacing = 6
        navigation.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Zurück")
        back.target = self; back.action = #selector(goBack); back.toolTip = "Zurück"
        let up = button("", #selector(goUp))
        up.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Übergeordneter Ordner")
        up.toolTip = "Übergeordneter Ordner"
        for button in [back, up] {
            AppStyle.configureButton(button); button.isBordered = false; button.controlSize = .small
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        AppStyle.configureField(pathField)
        pathField.placeholderString = "Pfad"; pathField.target = self; pathField.action = #selector(pathEntered)
        pathField.delegate = self; pathField.cell?.isScrollable = true
        pathField.setAccessibilityLabel(displayName + ": Ordnerpfad")
        pathField.toolTip = displayName
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        AppStyle.configureButton(favoritesButton); favoritesButton.isBordered = false
        favoritesButton.controlSize = .small; favoritesButton.imagePosition = .imageOnly
        favoritesButton.setAccessibilityLabel("Favoriten und Laufwerke")
        favoritesButton.toolTip = "Favoriten und Laufwerke · ⌥↓"
        favoritesButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let close = NSButton(image: NSImage(systemSymbolName: "eject", accessibilityDescription: "Verbindung trennen")!,
                             target: self, action: #selector(disconnectClicked))
        AppStyle.configureButton(close); close.isBordered = false; close.controlSize = .small
        close.toolTip = "Verbindung trennen · " + displayName
        ContextCommands.configure(close, id: "remote.close")
        for child in [back, up, pathField, favoritesButton, close] { navigation.addArrangedSubview(child) }
        table.didFocus = { [weak self] in self?.onActivate?() }
        table.handleKey = { [weak self] event in
            guard let self else { return false }
            if self.busy, ContextCommands.isCancellation(event) || ContextCommands.matches("remote.close", event) {
                return self.handleContextKey(event)
            }
            return self.onKey?(event) ?? false
        }
        table.setAccessibilityLabel(displayName + ": Dateiliste")
        table.style = .inset; table.rowHeight = 29; table.intercellSpacing = NSSize(width: 8, height: 1)
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self; table.target = self; table.doubleAction = #selector(openSelected)
        table.backgroundColor = ThemeManager.surfaceColor
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.table.backgroundColor = ThemeManager.surfaceColor
            self?.table.reloadData()
        }
        for (id, title, width) in [("name", "Name", 270.0), ("size", "Größe", 85.0), ("modified", "Geändert", 132.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 140 : width
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: sortAscending)]
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let connection = NSTextField(labelWithString: displayName)
        connection.font = .systemFont(ofSize: 11, weight: .medium); connection.textColor = .secondaryLabelColor
        connection.lineBreakMode = .byTruncatingMiddle
        let statusRow = NSStackView(); statusRow.spacing = 8
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        cancel.target = self; cancel.action = #selector(cancelRemoteOperation)
        AppStyle.configureButton(cancel); cancel.controlSize = .small; cancel.isHidden = true
        ContextCommands.configure(cancel, id: "dialog.cancel")
        for child in [connection, NSView(), spinner, status, cancel] { statusRow.addArrangedSubview(child) }
        for child in [navigation, scroll, statusRow] { child.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(child) }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: surface.topAnchor),
            navigation.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            navigation.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            scroll.topAnchor.constraint(equalTo: navigation.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -10),
            statusRow.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            statusRow.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            statusRow.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12)
        ])
        updateNavigation()
    }
    func button(_ title: String, _ action: Selector) -> NSButton {
        let result = NSButton(title: title, target: self, action: action)
        AppStyle.configureButton(result); result.controlSize = .small
        let ids = ["goUp": "remote.parent", "download": "remote.download", "upload": "remote.upload",
                   "makeDirectory": "remote.mkdir", "deleteSelected": "remote.delete", "reload": "remote.refresh"]
        if let id = ids[NSStringFromSelector(action)] { ContextCommands.configure(result, id: id) }
        buttons.append(result)
        return result
    }
    @objc private func disconnectClicked() { disconnect() }
    func show(directory: String) { navigate(directory, recordHistory: false); focus() }
    func navigate(_ path: String, recordHistory: Bool = true, select name: String? = nil, usingHistory: Bool = false) {
        guard !busy, !disconnected else { return }
        do {
            let next = try RemoteFileSystem.normalizedPath(path, relativeTo: directory)
            let previous = directory
            let selected = next == directory ? Set(selectedRows.map(\.name)) : []
            perform("Verzeichnis wird gelesen", work: { token in try self.fileSystem.list(next, cancellation: token) }) { [weak self] result in
                guard let self else { return }
                if recordHistory && self.hasLoadedDirectory && previous != next { self.history.append(previous) }
                if usingHistory && self.history.last == next { self.history.removeLast() }
                self.hasLoadedDirectory = true
                self.directory = next; self.pathField.stringValue = next
                self.allEntries = result
                self.rebuildListing(selecting: name.map { [$0] } ?? selected)
                self.updateNavigation()
            }
        } catch { pathField.stringValue = directory; showError(error) }
    }
    @objc func reload() { navigate(directory, recordHistory: false) }
    @objc private func pathEntered() { navigate(pathField.stringValue); focus() }
    func controlTextDidBeginEditing(_ obj: Notification) { onActivate?() }
    @objc func goUp() {
        guard directory != "/" else { return }
        navigate((directory as NSString).deletingLastPathComponent, select: (directory as NSString).lastPathComponent)
    }
    @objc func goBack() {
        guard let previous = history.last else { return }
        navigate(previous, recordHistory: false, usingHistory: true)
    }
    @objc func openSelected() {
        guard !busy, let entry = selectedRows.first else { return }
        if entry.name == ".." { goUp() }
        else if entry.isDirectory && !entry.isSymbolicLink { navigate(directory + "/" + entry.name) }
        else {
            preparePreview { [weak self] files in
                for file in files where !NSWorkspace.shared.open(file) {
                    self?.showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Datei konnte nicht geöffnet werden."]))
                }
            }
        }
    }
    var selectedRows: [RemoteEntry] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    var selection: [RemoteEntry] { selectedRows.filter { $0.name != ".." } }

    func rebuildListing(selecting names: Set<String>? = nil) {
        let selected = names ?? Set(selectedRows.map(\.name))
        entries = allEntries.filter {
            (showHidden || !$0.name.hasPrefix(".")) && (filterPattern.isEmpty || LocalInspection.matches($0.name, pattern: filterPattern))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sortKey {
            case "size" where a.size != b.size: order = a.size < b.size ? .orderedAscending : .orderedDescending
            case "modified" where a.modified != b.modified:
                order = (a.modified ?? .distantPast) < (b.modified ?? .distantPast) ? .orderedAscending : .orderedDescending
            default: order = a.name.localizedStandardCompare(b.name)
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
        if directory != "/" { entries.insert(RemoteEntry(name: "..", isDirectory: true), at: 0) }
        table.reloadData()
        var indexes = IndexSet(entries.indices.filter { selected.contains(entries[$0].name) })
        if indexes.isEmpty, !entries.isEmpty { indexes.insert(entries.firstIndex(where: { $0.name != ".." }) ?? 0) }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { table.scrollRowToVisible(first) }
        updateSummary()
        onStateChanged?()
    }
    func setFilter(_ pattern: String) {
        filterPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if isViewLoaded { rebuildListing() }
    }
    func setSort(key: String, ascending: Bool) {
        guard ["name", "size", "modified"].contains(key) else { return }
        sortKey = key; sortAscending = ascending
        guard isViewLoaded else { return }
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
        rebuildListing()
    }
    func setBriefListing(_ brief: Bool) {
        isBriefListing = brief
        _ = view
        table.tableColumns.dropFirst().forEach { $0.isHidden = brief }
        table.sizeToFit()
    }
    func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool) {
        _ = view
        table.rowHeight = min(44, max(18, rowHeight)); iconsVisible = showIcons
        status.isHidden = !showSummary; table.reloadData()
    }
    func selectMatching(_ pattern: String, select: Bool) {
        guard !busy, !pattern.isEmpty else { return }
        let matches = IndexSet(entries.indices.filter { entries[$0].name != ".." && fnmatch(pattern, entries[$0].name, 0) == 0 })
        var indexes = table.selectedRowIndexes
        indexes.subtract(IndexSet(entries.indices.filter { entries[$0].name == ".." }))
        if select { indexes.formUnion(matches) } else { indexes.subtract(matches) }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
    }
    func invertSelection() {
        guard !busy else { return }
        let selected = table.selectedRowIndexes
        table.selectRowIndexes(IndexSet(entries.indices.filter { entries[$0].name != ".." && !selected.contains($0) }), byExtendingSelection: false)
    }
    func installFavoritesMenu(_ menu: NSMenu) { favoritesButton.menu = menu }
    func showFavorites() { favoritesButton.performClick(nil) }
    func updateNavigation() { back.isEnabled = !busy && !history.isEmpty }
    func updateSummary() {
        let count = entries.filter { $0.name != ".." }.count
        status.stringValue = "\(count) Einträge" + (selection.isEmpty ? "" : " · \(selection.count) ausgewählt")
            + (filterPattern.isEmpty ? "" : " · Filter: " + filterPattern)
    }
    func finishOperation() {
        updateNavigation()
        if pendingRefresh && !busy && !disconnected { pendingRefresh = false; reload() }
    }
    func showArchiveTransferError() {
        showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Remote-Transfers benötigen einen lokalen Ordner. Bitte Archiveinträge zuerst dorthin kopieren beziehungsweise vor dem Download einen lokalen Ordner im Panel öffnen."]))
    }
    @objc private func cancelRemoteOperation() {
        if let queuedTask { tasks.cancel(queuedTask) }
        else { cancellation?.cancel() }
    }
    func performQueued<Value>(_ title: String, paths: [String],
                                      work: @escaping (RemoteCancellation, @escaping (OperationProgress) -> Void) throws -> Value,
                                      completion: @escaping (Value) -> Void) {
        guard !busy, !disconnected else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false
        cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        updateNavigation(); onStateChanged?()
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
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    // A batch can have changed some entries before a later failure.
                    self.pendingRefresh = true
                }
                self.finishOperation(); self.onStateChanged?()
            })
    }
    func perform<Value>(_ title: String, work: @escaping (RemoteCancellation) throws -> Value, completion: @escaping (Value) -> Void) {
        guard !busy, !disconnected else { return }
        let token = RemoteCancellation(); cancellation = token
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false; cancel.isHidden = false; status.stringValue = title; spinner.startAnimation(nil)
        updateNavigation(); onStateChanged?()
        workQueue.async { [weak self] in
            let result = Result { try work(token) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancellation = nil; self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true; self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
                guard !self.disconnected else { return }
                switch result {
                case .success(let value): completion(value)
                case .failure(let error):
                    self.pathField.stringValue = self.directory
                    self.status.stringValue = error.localizedDescription
                    if !token.isCancelled { self.showError(error) }
                }
                self.finishOperation(); self.onStateChanged?()
            }
        }
    }
    func showError(_ error: Error) {
        guard let window = view.window, window.attachedSheet == nil else { status.stringValue = error.localizedDescription; return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = error.localizedDescription
        alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
    }
    /// The commander calls this inside its menu/focus guard before the shared command dispatcher.
    /// Shared copy/open/navigation defaults belong to the main registry; remote-only overrides stay here.
    func handleContextKey(_ event: NSEvent) -> Bool {
        guard isActive, !disconnected, !KeyboardCaptureState.isRecording, isViewLoaded,
              let window = view.window, window.isKeyWindow, event.window === window,
              window.attachedSheet == nil, let responder = window.firstResponder as? NSView,
              responder === view || responder.isDescendant(of: view) || pathField.currentEditor() === responder,
              !ContextCommands.preservesTextInput(event, in: window) else { return false }
        if busy, ContextCommands.isCancellation(event) { cancelRemoteOperation(); return true }
        guard let id = ContextCommands.matching(event, scope: .remote) else { return false }
        if id == "remote.close" {
            if busy { cancelRemoteOperation() } else { disconnect() }
            return true
        }
        guard ContextCommands.canHandle(event, in: window) else { return false }
        guard !busy else { return true }
        switch id {
        case "remote.focusPath": focusPath()
        case "remote.open", "remote.open.keypad": openSelected()
        case "remote.parent", "remote.parent.delete": goUp()
        case "remote.download": download()
        case "remote.upload": upload()
        case "remote.mkdir": makeDirectory()
        case "remote.delete": deleteSelected()
        case "remote.refresh": reload()
        default: return false
        }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedFileRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !busy { updateSummary() }
        onStateChanged?()
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        sortKey = key; sortAscending = descriptor.ascending; rebuildListing()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let text: String
        switch id {
        case "size": text = entry.isDirectory ? "" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        case "modified": text = entry.modified.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
        default: text = entry.name
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: id == "name" && entry.isDirectory ? .medium : .regular); label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label); cell.textField = label
        var leading = cell.leadingAnchor
        var inset: CGFloat = 0
        if id == "name" && iconsVisible {
            let symbol = entry.name == ".." ? "arrow.turn.up.left" : entry.isSymbolicLink ? "link" : entry.isDirectory ? "folder" : "doc"
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            icon.contentTintColor = entry.isDirectory ? ThemeManager.accentColor : .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(icon); cell.imageView = icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
            leading = icon.trailingAnchor; inset = 6
        }
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: inset), label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                                     label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
