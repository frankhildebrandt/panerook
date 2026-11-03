import PaneRookTasks
import AppKit
import Quartz
import PaneRookCore

final class CommanderController: NSViewController, NSToolbarDelegate {
    let left: PaneController
    let right: PaneController
    private(set) var active: PaneController!
    private let status = NSTextField(labelWithString: "")
    private let statusBar = NSStackView()
    private let progress = NSProgressIndicator()
    private let hiddenButton = NSButton()
    private var availabilityObservers: [NSObjectProtocol] = []
    private var actions: [(NSButton, AppCommand)] = []
    lazy var commandRegistry = makeCommandRegistry()
    private var splitController: NSSplitViewController!
    private var actionDock: NSView!
    private var console: NSStackView!
    private let commandInput = NSTextField()
    private(set) var panelsHidden = false
    var arePanelsHidden: Bool { panelsHidden }
    lazy var tasks = TaskCenter(parentWindow: { [weak self] in self?.view.window },
                                restoreFocus: { [weak self] in guard let self else { return }; self.activate(self.active) },
                                transferStore: RecoverableTransfers.applicationStore,
                                restoredTransferCompletion: { [weak self] in self?.refreshAfterTask() })
    lazy var operations = OperationRunner(tasks: tasks, refresh: { [weak self] in self?.refreshAfterTask() })
    lazy var preview = PreviewTools(owner: self)
    lazy var fileOperations = FileOperations(owner: self)
    lazy var workflow = WorkflowTools(owner: self)
    lazy var preferences = PreferencesTools(owner: self)
    lazy var localTools = LocalTools(owner: self)
    lazy var metadata = FileMetadataTools(owner: self)
    lazy var remote = RemoteTools(owner: self)
    lazy var git = GitTools(owner: self)
    private let favoriteDestinations = FavoriteDestinationCache()
    private var favoritesMenus: [PanelFavoritesController] = []
    weak var appUpdater: AppUpdater?
    var onShowMenu: (() -> Void)?
    var menuIsTracking: (() -> Bool)?
    var onKeyBindingsChanged: (() -> Void)?
    var canUseMenus: Bool { view.window?.attachedSheet == nil && view.window?.isKeyWindow == true }
    var canUseSelection: Bool { canUseMenus && !panelsHidden && active.remoteContent == nil && active.mode != .terminal && !active.selectedFiles.isEmpty }
    var canUseLocalDirectory: Bool { canUseMenus && !panelsHidden && active.remoteContent == nil && active.mode != .network && active.mode != .gitHistory }
    var canUseNativeDirectory: Bool { canUseLocalDirectory && !active.isArchiveDirectory }
    var canUseNativeSelection: Bool {
        canUseSelection && !active.selectedFiles.contains {
            ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false
        }
    }
    var isPerformingOperation: Bool { view.window?.attachedSheet != nil }

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
    deinit { availabilityObservers.forEach { NotificationCenter.default.removeObserver($0) } }
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
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2)
        ])

        hiddenButton.title = ""
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hiddenButton.imagePosition = .imageOnly
        hiddenButton.setAccessibilityLabel("Versteckte Dateien")
        hiddenButton.toolTip = "Versteckte Dateien"
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
            pane.onRepositoryVisited = { GitRepositoryCatalog.shared.record($0) }
            pane.onOpenGit = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.git.open(pane: pane)
            }
            pane.onGitHistoryRequested = { [weak self, weak pane] in
                guard let self, let pane else { return }
                pane.showGitHistory(from: pane === self.left ? self.right : self.left)
            }
            pane.onSelectionChanged = { [weak self, weak pane] url in
                guard let self, let pane else { return }
                let other = pane === self.left ? self.right : self.left
                other.showInspection(of: url)
                other.showGitHistory(from: pane)
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
        for command in commandRegistry.dockCommands {
            let control = NSButton(title: command.title, target: self, action: #selector(performDockCommand(_:)))
            control.identifier = .init(command.id)
            AppStyle.configureButton(control)
            control.isBordered = false
            control.contentTintColor = .labelColor
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11, weight: .regular)
            control.heightAnchor.constraint(equalToConstant: 22).isActive = true
            functionBar.addArrangedSubview(control)
            actions.append((control, command))
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
        tasks.onChange = { [weak self] in self?.updateTaskStatus() }
        root.addArrangedSubview(statusBar)
        statusBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        updateTaskStatus()
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            availabilityObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateDirectoryActionAvailability()
            })
        }
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
    @objc func runConsoleCommand() {
        guard active.remoteContent == nil, !active.isArchiveDirectory, active.mode != .network else { return }
        let command = commandInput.stringValue
        commandInput.stringValue = ""
        workflow.runCommand(command)
    }

    private enum ToolbarID {
        static let home = NSToolbarItem.Identifier("PaneRook.Home")
        static let refresh = NSToolbarItem.Identifier("PaneRook.Refresh")
        static let swap = NSToolbarItem.Identifier("PaneRook.Swap")
        static let hidden = NSToolbarItem.Identifier("PaneRook.Hidden")
        static let tasks = NSToolbarItem.Identifier("PaneRook.Tasks")
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
        [ToolbarID.home, ToolbarID.refresh, ToolbarID.swap, ToolbarID.menu, .flexibleSpace, ToolbarID.hidden, ToolbarID.tasks, ToolbarID.help]
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
        case ToolbarID.tasks: (title, symbol, action) = ("Aufgaben", "list.bullet.rectangle", #selector(showTaskQueue))
        case ToolbarID.help: (title, symbol, action) = ("Hilfe", "questionmark.circle", #selector(showHelp))
        case ToolbarID.menu: (title, symbol, action) = ("Menü", "line.3.horizontal", #selector(showMenu))
        default: return nil
        }
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = action
        item.isBordered = true
        item.isNavigational = id != ToolbarID.help && id != ToolbarID.menu && id != ToolbarID.tasks
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
        let bindings = commandRegistry.bindings
        hiddenButton.toolTip = commandHint("panels.showHidden", title: "Versteckte Dateien", bindings: bindings)
        let toolbarCommands = [ToolbarID.home: "navigation.home", ToolbarID.refresh: "panels.refresh", ToolbarID.swap: "panels.swap", ToolbarID.help: "help", ToolbarID.menu: "menu", ToolbarID.tasks: "tasks.showQueue"]
        for item in view.window?.toolbar?.items ?? [] {
            if let id = toolbarCommands[item.itemIdentifier] { item.toolTip = commandHint(id, title: item.label, bindings: bindings) }
        }
        for (button, command) in actions {
            button.isEnabled = command.enabled()
            button.title = "\(bindings[command.id]?.label ?? "")  \(command.dockTitle?() ?? command.title)"
        }
    }
    @objc private func performDockCommand(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        commandRegistry[id]?.perform()
    }
    @objc func goUp() { active.goUp() }
    @objc func goHome() { active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func focusPath() {
        if active.mode == .gitHistory || active.mode == .terminal { active.setMode(.listing) }
        if let remote = active.remoteContent { remote.focusPath(); return }
        view.window?.makeFirstResponder(active.pathField)
        active.pathField.selectText(nil)
    }
    @objc func refresh() { left.refresh(); right.refresh(); workflow.applyHighlights() }
    func refreshAfterTask() { left.refreshAfterTask(); right.refreshAfterTask(); workflow.applyHighlights() }
    @objc func swapPanels() {
        guard left.remoteContent == nil, right.remoteContent == nil else { return }
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
        if left.remoteContent == nil { left.refresh() }
        if right.remoteContent == nil { right.refresh() }
        workflow.applyHighlights()
    }
    @objc func revealInFinder() {
        guard active.remoteContent == nil else { return }
        let urls = active.selectedFiles.isEmpty ? [active.directory] : active.selectedFiles
        let local = urls.map { ArchiveFileSystem.location(for: $0)?.archiveURL ?? $0 }
        NSWorkspace.shared.activateFileViewerSelecting(Array(Set(local)))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard canHandleMainKeys else { return false }
        if let remote = active.remoteContent as? RemoteBrowser, remote.handleContextKey(event) { return true }
        if let action = commandRegistry.matching(event, scope: .panel)
            ?? commandRegistry.matching(event, scope: .application) {
            action.perform()
            return true
        }
        return false
    }
    var canHandleMainKeys: Bool {
        canUseMenus && !KeyboardCaptureState.isRecording && menuIsTracking?() != true
            && !favoritesMenus.contains(where: \.isTracking)
    }
    /// Called before AppKit's key-equivalent pass, so physical custom keys work on any layout.
    func handleGlobalKey(_ event: NSEvent) -> Bool {
        guard canHandleMainKeys, event.window === view.window else { return false }
        if !panelsHidden, active.hasTerminalKeyboardFocus {
            if commandRegistry.bindings["panels.switch.terminal"]?.matches(event) == true {
                return commandRegistry["panels.switch.terminal"]?.perform() == true
            }
            // Send shell keys before AppKit tries menu equivalents: Ctrl-O,
            // function keys and remapped Ctrl/Option shortcuts belong to Ghostty.
            if !event.modifierFlags.contains(.command) {
                view.window?.firstResponder?.keyDown(with: event)
                return true
            }
        }
        if !panelsHidden, let remote = active.remoteContent as? RemoteBrowser, remote.handleContextKey(event) { return true }
        if panelsHidden, let action = commandRegistry.matching(event, scope: .console) {
            action.perform(); return true
        }
        if active.hasPanelKeyboardFocus,
           let action = commandRegistry.matching(event, scope: .panel) {
            action.perform(); return true
        }
        guard let command = commandRegistry.matching(event, scope: .application),
              let binding = commandRegistry.bindings[command.id], !binding.isTextInput else { return false }
        command.perform()
        return true
    }
    private func commandHint(_ id: String, title: String, bindings: [String: AppKeyBinding]) -> String {
        bindings[id].map { title + " · " + $0.label } ?? title
    }
    func hotkeysChanged() {
        updateDirectoryActionAvailability()
        onKeyBindingsChanged?()
    }

    @objc func showMenu() {
        guard canUseMenus else { return }
        onShowMenu?()
    }
    func exitOrCancelDialog() {
        if let window = view.window, let sheet = window.attachedSheet {
            if let panel = sheet as? TransferPanel { panel.cancelOperation(nil) }
            else if let panel = sheet as? ToolPanel { panel.cancelOperation(nil) }
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
    func saveSetup() {
        saveDirectories()
        UserDefaults.standard.set(left.showHidden, forKey: "showHidden")
        view.window?.saveFrame(usingName: "PaneRook.MainWindow")
        preferences.savePanels()
    }

    @objc func openSelection() {
        if let remote = active.remoteContent { remote.openSelection(); return }
        preview.openSelection()
    }
    @objc func previewSelection() { preview.previewSelection() }
    func previewFiles(_ urls: [URL]) { preview.previewFiles(urls) }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = preview }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    @objc private func showTaskQueue() { tasks.showQueue() }
    private func updateTaskStatus() {
        let hasActiveTasks = tasks.hasActiveTasks
        status.stringValue = tasks.summary
        statusBar.isHidden = !hasActiveTasks
        if hasActiveTasks { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
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
        let bindings = commandRegistry.bindings
        let ids = ["panels.switch", "navigation.open", "navigation.parent.backspace", "preview.space", "preview", "userMenu", "edit", "copy", "move", "mkdir", "trash", "menu", "exit", "dialog.cancel", "dialog.cancel.function", "dialog.cancel.control", "navigation.focusPath", "panels.refresh", "panels.swap", "panels.toggle"]
        alert.informativeText = ids.compactMap { id -> String? in
            guard let command = commandRegistry[id], let binding = bindings[id] else { return nil }
            return binding.label + ": " + command.title
        }.joined(separator: "\n") + "\n\nAlle Aktionen und eigene Belegung: Einstellungen → Tastatur → Belegung bearbeiten.\nAuf Apple-Tastaturen ggf. zusätzlich fn drücken."
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: view.window!)
    }
}
