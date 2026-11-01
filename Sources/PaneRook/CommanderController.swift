import AppKit
import Quartz
import PaneRookCore

final class CommanderController: NSViewController, QLPreviewPanelDataSource, NSToolbarDelegate {
    let left: PaneController
    let right: PaneController
    private(set) var active: PaneController!
    private let status = NSTextField(labelWithString: "")
    private let statusBar = NSStackView()
    private let progress = NSProgressIndicator()
    private let hiddenButton = NSButton()
    private let operationQueue = DispatchQueue(label: "app.panerook.file-operations", qos: .userInitiated)
    private var busy = false
    private var transferDialog: TransferDialog?
    private var sparseFileDialog: SparseFileDialog?
    private var previewURLs: [URL] = []
    private var actions: [NSButton] = []
    private var splitController: NSSplitViewController!
    private var actionDock: NSView!
    private var console: NSStackView!
    private let commandInput = NSTextField()
    private var panelsHidden = false
    var arePanelsHidden: Bool { panelsHidden }
    lazy var workflow = WorkflowTools(owner: self)
    lazy var preferences = PreferencesTools(owner: self)
    lazy var localTools = LocalTools(owner: self)
    lazy var metadata = FileMetadataTools(owner: self)
    lazy var remote = RemoteTools(owner: self)
    private let favoriteDestinations = FavoriteDestinationCache()
    private var favoritesMenus: [PanelFavoritesController] = []
    var onShowMenu: (() -> Void)?
    var menuIsTracking: (() -> Bool)?
    var onKeyBindingsChanged: (() -> Void)?
    var canUseMenus: Bool { !busy && view.window?.attachedSheet == nil && view.window?.isKeyWindow == true }
    var canUseSelection: Bool { canUseMenus && !panelsHidden && !active.selectedFiles.isEmpty }
    var canUseLocalDirectory: Bool { canUseMenus && !panelsHidden && active.mode != .network }
    var canUseNativeDirectory: Bool { canUseLocalDirectory && !active.isArchiveDirectory }
    var canUseNativeSelection: Bool {
        canUseSelection && !active.selectedFiles.contains {
            ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false
        }
    }
    var isPerformingOperation: Bool { busy }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func restored(_ key: String, fallback: URL) -> URL {
            if UserDefaults.standard.object(forKey: "restorePanels") as? Bool == false { return fallback }
            guard let path = UserDefaults.standard.string(forKey: key),
                  let directory = try? FileSystem.directory(from: path, relativeTo: home) else { return fallback }
            return directory
        }
        left = PaneController(label: "Links", directory: restored("leftDirectory", fallback: home))
        right = PaneController(label: "Rechts", directory: restored("rightDirectory", fallback: home.appendingPathComponent("Downloads")))
        super.init(nibName: nil, bundle: nil)
        active = left
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    var other: PaneController { active === left ? right : left }

    override func loadView() {
        view = AppStyle.background()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14)
        ])

        hiddenButton.title = ""
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hiddenButton.imagePosition = .imageOnly
        hiddenButton.setAccessibilityLabel("Versteckte Dateien")
        hiddenButton.toolTip = "Versteckte Dateien · ⌘⇧."
        AppStyle.configureButton(hiddenButton)
        hiddenButton.setButtonType(.pushOnPushOff)
        hiddenButton.target = self
        hiddenButton.action = #selector(toggleHidden)
        hiddenButton.state = UserDefaults.standard.bool(forKey: "showHidden") ? .on : .off

        let split = NSSplitViewController()
        splitController = split
        for pane in [left, right] {
            favoritesMenus.append(PanelFavoritesController(owner: self, pane: pane, cache: favoriteDestinations))
            pane.showHidden = hiddenButton.state == .on
            pane.onActivate = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.active = pane
                self.left.isActive = pane === self.left
                self.right.isActive = pane === self.right
                self.updateDirectoryActionAvailability()
            }
            pane.onKey = { [weak self] in self?.handleKey($0) ?? false }
            pane.onError = { [weak self] in self?.showError($0) }
            pane.onOpenSelection = { [weak self] in self?.openSelection() }
            pane.onDirectoryChanged = { [weak self] in self?.saveDirectories() }
            pane.onSelectionChanged = { [weak self, weak pane] url in
                guard let self, let pane else { return }
                (pane === self.left ? self.right : self.left).showInspection(of: url)
                self.updateDirectoryActionAvailability()
            }
            let item = NSSplitViewItem(viewController: pane)
            item.minimumThickness = 390
            split.addSplitViewItem(item)
        }
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = "PaneRook.Split"
        addChild(split)
        root.addArrangedSubview(split.view)
        split.view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.view.setContentHuggingPriority(.defaultLow, for: .vertical)

        console = NSStackView()
        console.orientation = .vertical
        console.alignment = .leading
        console.spacing = 8
        AppStyle.configureField(commandInput)
        commandInput.placeholderString = "Shell-Befehl"
        commandInput.setAccessibilityLabel("Befehl")
        commandInput.target = self
        commandInput.action = #selector(runConsoleCommand)
        let execute = NSButton(title: "Ausführen", target: self, action: #selector(runConsoleCommand))
        AppStyle.configureButton(execute)
        let commandRow = NSStackView(views: [commandInput, execute])
        commandRow.spacing = 8
        console.addArrangedSubview(commandRow)
        console.addArrangedSubview(NSView())
        root.addArrangedSubview(console)
        console.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        commandRow.widthAnchor.constraint(equalTo: console.widthAnchor).isActive = true
        console.isHidden = true

        let functionBar = NSStackView()
        functionBar.spacing = 6
        functionBar.distribution = .fillEqually
        functionBar.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        functionBar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        for (title, action) in [
            ("F3  Vorschau", #selector(previewSelection)),
            ("F4  Bearbeiten", #selector(editSelection)),
            ("F5  Kopieren", #selector(copySelection)),
            ("F6  Verschieben", #selector(moveSelection)),
            ("F7  Neuer Ordner", #selector(makeDirectory)),
            ("F8  Papierkorb", #selector(trashSelection))
        ] {
            let control = NSButton(title: title, target: self, action: action)
            AppStyle.configureButton(control)
            control.isBordered = false
            control.contentTintColor = .labelColor
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11, weight: .regular)
            control.heightAnchor.constraint(equalToConstant: 22).isActive = true
            functionBar.addArrangedSubview(control)
            actions.append(control)
        }
        actionDock = AppStyle.glass(around: functionBar, cornerRadius: 8)
        root.setCustomSpacing(6, after: split.view)
        root.addArrangedSubview(actionDock)
        actionDock.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        root.setCustomSpacing(10, after: actionDock)
        statusBar.spacing = 8
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusBar.addArrangedSubview(progress)
        statusBar.addArrangedSubview(status)
        statusBar.addArrangedSubview(NSView())
        root.addArrangedSubview(statusBar)
        statusBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        statusBar.isHidden = true
        left.isActive = true
        preferences.restorePanels()
        preferences.apply()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        preferences.apply()
    }

    func applyLayout(vertical: Bool, functionBar: Bool, toolbar: Bool) {
        guard splitController != nil else { return }
        splitController.splitView.isVertical = vertical
        for item in splitController.splitViewItems { item.minimumThickness = vertical ? 320 : 140 }
        actionDock.isHidden = !functionBar
        view.window?.toolbar?.isVisible = toolbar
    }
    func togglePanels() {
        panelsHidden.toggle()
        splitController.view.isHidden = panelsHidden
        console.isHidden = !panelsHidden
        if panelsHidden { view.window?.makeFirstResponder(commandInput) }
        else { activate(active) }
    }
    @objc private func runConsoleCommand() {
        let command = commandInput.stringValue
        commandInput.stringValue = ""
        workflow.runCommand(command)
    }

    private enum ToolbarID {
        static let home = NSToolbarItem.Identifier("PaneRook.Home")
        static let refresh = NSToolbarItem.Identifier("PaneRook.Refresh")
        static let swap = NSToolbarItem.Identifier("PaneRook.Swap")
        static let hidden = NSToolbarItem.Identifier("PaneRook.Hidden")
        static let help = NSToolbarItem.Identifier("PaneRook.Help")
        static let menu = NSToolbarItem.Identifier("PaneRook.Menu")
    }

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "PaneRook.Navigation")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.home, ToolbarID.refresh, ToolbarID.swap, ToolbarID.menu, .flexibleSpace, ToolbarID.hidden, ToolbarID.help]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == ToolbarID.hidden {
            item.label = "Versteckte Dateien"
            item.view = hiddenButton
            item.visibilityPriority = .high
            return item
        }
        let title: String
        let symbol: String
        let action: Selector
        switch id {
        case ToolbarID.home: (title, symbol, action) = ("Benutzerordner", "house", #selector(goHome))
        case ToolbarID.refresh: (title, symbol, action) = ("Aktualisieren", "arrow.clockwise", #selector(refresh))
        case ToolbarID.swap: (title, symbol, action) = ("Panels tauschen", "arrow.left.arrow.right", #selector(swapPanels))
        case ToolbarID.help: (title, symbol, action) = ("Hilfe", "questionmark.circle", #selector(showHelp))
        case ToolbarID.menu: (title, symbol, action) = ("Menü · F9", "line.3.horizontal", #selector(showMenu))
        default: return nil
        }
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        item.isBordered = true
        item.isNavigational = id != ToolbarID.help && id != ToolbarID.menu
        return item
    }

    func activate(_ pane: PaneController) {
        active = pane
        left.isActive = pane === left
        right.isActive = pane === right
        pane.focus()
        updateDirectoryActionAvailability()
    }
    private func updateDirectoryActionAvailability() {
        if actions.indices.contains(4) { actions[4].isEnabled = !busy && active.mode != .network }
        if actions.indices.contains(1) { actions[1].isEnabled = !busy && !active.isArchiveDirectory }
        if actions.indices.contains(5) {
            let title = active.isArchiveDirectory ? "Löschen" : "Papierkorb"
            actions[5].title = "\(AppKeyBinding.saved["trash"]?.label ?? "F8")  \(title)"
        }
    }
    @objc func openSelection() {
        guard !busy, let entry = active.selectedEntries.first else { return }
        // Archives enter the panel before extension-to-app associations are considered.
        if entry.isDirectory || (!entry.isSymbolicLink && ArchiveFileSystem.location(for: entry.url)?.memberPath.isEmpty == true) {
            active.openSelection()
            return
        }
        if let location = ArchiveFileSystem.location(for: entry.url), !location.memberPath.isEmpty {
            withReadableFiles([entry.url]) { [weak self] files in
                guard let self else { return }
                if !self.workflow.openUsingExtension(files), let file = files.first, !NSWorkspace.shared.open(file) {
                    self.showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Archivdatei konnte nicht geöffnet werden."]))
                }
            }
            return
        }
        if active.selectedEntries.contains(where: { !$0.isDirectory && !$0.isParent }), workflow.openUsingExtension(active.selectedFiles) { return }
        active.openSelection()
    }
    @objc func goUp() { active.goUp() }
    @objc func goHome() { active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func focusPath() {
        view.window?.makeFirstResponder(active.pathField)
        active.pathField.selectText(nil)
    }
    @objc func refresh() { left.refresh(); right.refresh(); workflow.applyHighlights() }
    @objc func swapPanels() {
        let url = left.directory
        left.navigate(to: right.directory)
        right.navigate(to: url)
    }
    @objc func toggleHidden() {
        let show = !left.showHidden
        left.showHidden = show
        right.showHidden = show
        hiddenButton.state = show ? .on : .off
        UserDefaults.standard.set(show, forKey: "showHidden")
        refresh()
    }
    @objc func revealInFinder() {
        let urls = active.selectedFiles.isEmpty ? [active.directory] : active.selectedFiles
        let local = urls.map { ArchiveFileSystem.location(for: $0)?.archiveURL ?? $0 }
        NSWorkspace.shared.activateFileViewerSelecting(Array(Set(local)))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard menuIsTracking?() != true, !favoritesMenus.contains(where: \.isTracking) else { return false }
        if event.keyCode == 125 && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option {
            active.showFavorites(); return true
        }
        if let action = AppKeyBinding.saved.first(where: { $0.value.matches(event) })?.key {
            performHotkey(action)
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 48: activate(other)
        case 36, 76: openSelection()
        case 51, 117: goUp()
        case 49: previewSelection()
        default: return false
        }
        return true
    }
    func performHotkey(_ action: String) {
        switch action {
        case "help": showHelp()
        case "userMenu": workflow.userMenu()
        case "preview": previewSelection()
        case "edit": editSelection()
        case "copy": copySelection()
        case "move": moveSelection()
        case "mkdir": makeDirectory()
        case "trash": trashSelection()
        case "menu": showMenu()
        case "exit": exitOrCancelDialog()
        default: break
        }
    }
    func hotkeysChanged() {
        let names = [("preview", "Vorschau"), ("edit", "Bearbeiten"), ("copy", "Kopieren"),
                     ("move", "Verschieben"), ("mkdir", "Neuer Ordner"), ("trash", "Papierkorb")]
        for (button, action) in zip(actions, names) {
            button.title = "\(AppKeyBinding.saved[action.0]?.label ?? "")  \(action.1)"
        }
        onKeyBindingsChanged?()
    }

    @objc func showMenu() {
        guard canUseMenus else { return }
        onShowMenu?()
    }
    func exitOrCancelDialog() {
        guard !busy else { return }
        if let window = view.window, let sheet = window.attachedSheet {
            if let panel = sheet as? TransferPanel { panel.cancelOperation(nil) }
            else { window.endSheet(sheet, returnCode: .cancel) }
        } else {
            NSApp.terminate(nil)
        }
    }
    func selectGroup(select: Bool) {
        guard canUseMenus, let window = view.window else { return }
        let pane = active!
        let alert = NSAlert()
        alert.messageText = select ? "Gruppe auswählen" : "Gruppe abwählen"
        let pattern = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 30))
        AppStyle.configureField(pattern)
        pattern.stringValue = "*"
        pattern.setAccessibilityLabel("Dateimaske")
        pattern.toolTip = "Shell-Muster, z. B. *.txt oder Bild?.png"
        alert.accessoryView = pattern
        alert.addButton(withTitle: select ? "Auswählen" : "Abwählen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = pattern
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { pane.selectMatching(pattern.stringValue, select: select) }
            self?.activate(pane)
        }
    }
    func choosePreviewFile() {
        guard canUseMenus, let window = view.window else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Datei anzeigen"
        chooser.prompt = "Anzeigen"
        chooser.directoryURL = ArchiveFileSystem.location(for: active.directory)?.archiveURL.deletingLastPathComponent() ?? active.directory
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = chooser.url else { return }
            self.previewFiles([url])
        }
    }
    func saveSetup() {
        saveDirectories()
        UserDefaults.standard.set(left.showHidden, forKey: "showHidden")
        view.window?.saveFrame(usingName: "PaneRook.MainWindow")
        preferences.savePanels()
    }

    @objc func previewSelection() {
        previewFiles(active.selectedFiles)
    }
    func previewFiles(_ urls: [URL]) {
        withReadableFiles(urls) { [weak self] files in
            self?.workflow.recordFiles(urls)
            self?.showPreviewFiles(files)
        }
    }
    private func withReadableFiles(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        guard !busy, !urls.isEmpty else { NSSound.beep(); return }
        guard urls.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) else {
            completion(urls)
            return
        }
        busy = true
        actions.forEach { $0.isEnabled = false }
        status.stringValue = "Archivvorschau vorbereiten …"
        statusBar.isHidden = false
        progress.startAnimation(nil)
        operationQueue.async { [weak self] in
            let result = Result { try urls.map { try ArchivePreviewStore.shared.readableURL(for: $0) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.actions.forEach { $0.isEnabled = true }
                self.updateDirectoryActionAvailability()
                self.progress.stopAnimation(nil)
                self.statusBar.isHidden = true
                switch result {
                case .success(let files): completion(files)
                case .failure(let error): self.showError(error)
                }
            }
        }
    }
    private func showPreviewFiles(_ urls: [URL]) {
        previewURLs = urls
        guard !previewURLs.isEmpty else { NSSound.beep(); return }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }

    @objc func editSelection() {
        guard canUseNativeSelection else {
            if active.isArchiveDirectory {
                showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zum Bearbeiten die Datei zuerst in einen lokalen Ordner kopieren."]),
                          detail: "Dateien aus Archiven werden als temporäre Lesekopien geöffnet. Änderungen werden nicht automatisch ins Archiv zurückgeschrieben.")
            }
            return
        }
        let files = active.selectedEntries.filter { !$0.isParent && !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else { NSSound.beep(); return }
        workflow.recordFiles(files)
        let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error) } }
        }
    }
    @objc func copySelection() { transfer(.copy) }
    @objc func moveSelection() { transfer(.move) }
    private func transfer(_ kind: TransferKind) {
        guard canUseSelection, let window = view.window else { return }
        let sources = active.selectedFiles
        guard !sources.isEmpty else { NSSound.beep(); return }
        let destination = other.directory
        let verb = kind == .copy ? "Kopieren" : "Verschieben"
        let sourcePane = active!
        let dialog = TransferDialog(sources: sources, sourceDirectory: sourcePane.directory,
            destinationDirectory: destination, kind: kind) { [weak self] plan in
            guard let self else { return }
            self.transferDialog = nil
            self.activate(sourcePane)
            guard let plan else { return }
            self.runOperation("\(verb) …") {
                try plan.execute()
            }
        }
        transferDialog = dialog
        dialog.begin(on: window)
    }
    @objc func makeDirectory() {
        guard canUseLocalDirectory else { return }
        let directory = active.directory
        let pane = active!
        let alert = NSAlert()
        alert.messageText = "Neuer Ordner"
        alert.informativeText = "In: \(directory.path)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        input.placeholderString = "Ordnername"
        alert.accessoryView = input
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = input.stringValue
            self?.runOperation("Ordner anlegen …", completion: {
                pane.refresh(select: directory.appendingPathComponent(name))
            }) { try FileActions.createDirectory(named: name, in: directory) }
        }
    }
    func createSparseFile() {
        guard canUseNativeDirectory, let window = view.window else { return }
        let pane = active!
        let directory = pane.directory
        let dialog = SparseFileDialog(directory: directory) { [weak self] request in
            guard let self else { return }
            self.sparseFileDialog = nil
            self.activate(pane)
            guard let request else { return }
            self.runOperation("Sparse-Datei erstellen …", completion: {
                pane.setMode(.listing)
                if !pane.filterPattern.isEmpty && !LocalInspection.matches(request.name, pattern: pane.filterPattern) {
                    pane.setFilter("")
                }
                pane.refresh(select: directory.appendingPathComponent(request.name))
            }, errorDetail: "") {
                try SparseFile.create(named: request.name, in: directory, logicalSize: request.logicalSize)
            }
        }
        sparseFileDialog = dialog
        dialog.begin(on: window)
    }
    @objc func trashSelection() {
        guard canUseSelection else { return }
        let sources = active.selectedFiles
        guard !sources.isEmpty else { NSSound.beep(); return }
        if sources.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(sources.count) Einträge endgültig aus dem Archiv löschen?"
            alert.informativeText = sources.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
                + "\n\nArchiv-Inhalte werden nicht in den Papierkorb gelegt. Diese Aktion lässt sich nicht widerrufen."
            alert.addButton(withTitle: "Aus Archiv löschen")
            alert.addButton(withTitle: "Abbrechen")
            alert.configureKeyboardShortcuts()
            alert.beginSheetModal(for: view.window!) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.runOperation("Aus Archiv löschen …", errorDetail: "Das Archiv wird erst nach erfolgreichem Schreiben ersetzt.") {
                    try ArchiveFileSystem.remove(sources)
                }
            }
            return
        }
        if UserDefaults.standard.object(forKey: "confirmTrash") as? Bool == false {
            runOperation("In den Papierkorb legen …") {
                for source in sources { try FileManager.default.trashItem(at: source, resultingItemURL: nil) }
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(sources.count) Einträge in den Papierkorb legen?"
        alert.informativeText = sources.prefix(5).map(\.lastPathComponent).joined(separator: "\n") + "\n\nDu kannst sie im Finder aus dem Papierkorb zurückholen."
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.runOperation("In den Papierkorb legen …") {
                for source in sources { try FileManager.default.trashItem(at: source, resultingItemURL: nil) }
            }
        }
    }
    func runOperation(_ title: String, completion: (() -> Void)? = nil,
                      errorDetail: String = "Bei mehreren Einträgen können vorherige Schritte bereits abgeschlossen sein. Bitte beide Panels prüfen.",
                      work: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        actions.forEach { $0.isEnabled = false }
        status.stringValue = title
        statusBar.isHidden = false
        progress.startAnimation(nil)
        operationQueue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.actions.forEach { $0.isEnabled = true }
                self.updateDirectoryActionAvailability()
                self.progress.stopAnimation(nil)
                self.refresh()
                switch result {
                case .success:
                    self.status.stringValue = ""
                    self.statusBar.isHidden = true
                    completion?()
                case .failure(let error):
                    self.status.stringValue = error.localizedDescription
                    self.showError(error, detail: errorDetail)
                }
            }
        }
    }
    func showError(_ error: Error, detail: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        alert.informativeText = detail
        alert.configureKeyboardShortcuts()
        if let window = view.window, window.attachedSheet == nil { alert.beginSheetModal(for: window) }
        else {
            status.stringValue = error.localizedDescription
            statusBar.isHidden = false
        }
    }
    private func saveDirectories() {
        UserDefaults.standard.set(left.directory.path, forKey: "leftDirectory")
        UserDefaults.standard.set(right.directory.path, forKey: "rightDirectory")
    }
    @objc func showHelp() {
        guard view.window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Tastenkürzel"
        alert.informativeText = "Tab: Panel wechseln\nEnter: öffnen · Rücktaste: übergeordneter Ordner\nLeertaste / F3: Quick Look\nF2: Benutzermenü · F4: TextEdit\nF5 / F6: Kopieren / Verschieben\nF7: Ordner anlegen · F8: Papierkorb\nF9: Menü · F10: Verlassen\nEsc / F10 / Ctrl-G: Dialog oder Menü abbrechen\n⌘L: Pfad · ⌘R: aktualisieren · ⌘U: Panels tauschen\nCtrl-O: Panels an/aus\n\nEigene Belegung: Optionen → Tasten lernen.\nAuf Apple-Tastaturen ggf. zusätzlich fn drücken."
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: view.window!)
    }
}
