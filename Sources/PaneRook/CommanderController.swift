import AppKit
import Quartz
import PaneRookCore

final class CommanderController: NSViewController, QLPreviewPanelDataSource {
    let left: PaneController
    let right: PaneController
    private(set) var active: PaneController!
    private let status = NSTextField(labelWithString: "Bereit")
    private let progress = NSProgressIndicator()
    private let hiddenButton = NSButton()
    private let operationQueue = DispatchQueue(label: "app.panerook.file-operations", qos: .userInitiated)
    private var busy = false
    private var transferDialog: TransferDialog?
    private var previewURLs: [URL] = []
    private var actions: [NSButton] = []

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func restored(_ key: String, fallback: URL) -> URL {
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
    private var other: PaneController { active === left ? right : left }

    override func loadView() {
        view = NSView()
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: view.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor), root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor)])

        let toolbar = NSStackView()
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        toolbar.addArrangedSubview(button("Benutzerordner", symbol: "house", action: #selector(goHome)))
        toolbar.addArrangedSubview(button("Aktualisieren", symbol: "arrow.clockwise", action: #selector(refresh)))
        toolbar.addArrangedSubview(button("Panels tauschen", symbol: "arrow.left.arrow.right", action: #selector(swapPanels)))
        toolbar.addArrangedSubview(NSView())
        hiddenButton.title = "Versteckte Dateien"
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        hiddenButton.imagePosition = .imageLeading
        hiddenButton.bezelStyle = .texturedRounded
        hiddenButton.setButtonType(.pushOnPushOff)
        hiddenButton.target = self
        hiddenButton.action = #selector(toggleHidden)
        hiddenButton.state = UserDefaults.standard.bool(forKey: "showHidden") ? .on : .off
        toolbar.addArrangedSubview(hiddenButton)
        toolbar.addArrangedSubview(button("Hilfe", symbol: "questionmark.circle", action: #selector(showHelp)))
        root.addArrangedSubview(toolbar)
        toolbar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let split = NSSplitViewController()
        for pane in [left, right] {
            pane.showHidden = hiddenButton.state == .on
            pane.onActivate = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.active = pane
                self.left.isActive = pane === self.left
                self.right.isActive = pane === self.right
            }
            pane.onKey = { [weak self] in self?.handleKey($0) ?? false }
            pane.onError = { [weak self] in self?.showError($0) }
            pane.onDirectoryChanged = { [weak self] in self?.saveDirectories() }
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

        let functionBar = NSStackView()
        functionBar.spacing = 8
        functionBar.distribution = .fillEqually
        functionBar.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 10, right: 14)
        for (title, action) in [
            ("F3  Vorschau", #selector(previewSelection)),
            ("F4  Bearbeiten", #selector(editSelection)),
            ("F5  Kopieren", #selector(copySelection)),
            ("F6  Verschieben", #selector(moveSelection)),
            ("F7  Neuer Ordner", #selector(makeDirectory)),
            ("F8  Papierkorb", #selector(trashSelection))
        ] {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            control.font = .systemFont(ofSize: 12, weight: .medium)
            functionBar.addArrangedSubview(control)
            actions.append(control)
        }
        root.addArrangedSubview(functionBar)
        functionBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let statusBar = NSStackView()
        statusBar.spacing = 8
        statusBar.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 12, right: 16)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusBar.addArrangedSubview(progress)
        statusBar.addArrangedSubview(status)
        statusBar.addArrangedSubview(NSView())
        let hint = NSTextField(labelWithString: "Tab  Panel wechseln    ↵  Öffnen    ⌘L  Pfad")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        statusBar.addArrangedSubview(hint)
        root.addArrangedSubview(statusBar)
        statusBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        left.isActive = true
    }

    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.toolTip = title
        return button
    }

    func activate(_ pane: PaneController) {
        active = pane
        left.isActive = pane === left
        right.isActive = pane === right
        view.window?.makeFirstResponder(pane.table)
    }
    @objc func openSelection() { active.openSelection() }
    @objc func goUp() { active.goUp() }
    @objc func goHome() { active.navigate(to: FileManager.default.homeDirectoryForCurrentUser) }
    @objc func focusPath() {
        view.window?.makeFirstResponder(active.pathField)
        active.pathField.selectText(nil)
    }
    @objc func refresh() { left.refresh(); right.refresh() }
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
        NSWorkspace.shared.activateFileViewerSelecting(active.selectedFiles.isEmpty ? [active.directory] : active.selectedFiles)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 48: activate(other)
        case 36, 76: openSelection()
        case 51, 117: goUp()
        case 49: previewSelection()
        case 99: previewSelection() // F3
        case 120: showHelp() // F2
        case 122: showHelp() // F1
        case 118: editSelection() // F4
        case 96: copySelection() // F5
        case 97: moveSelection() // F6
        case 98: makeDirectory() // F7
        case 100: trashSelection() // F8
        default: return false
        }
        return true
    }

    @objc func previewSelection() {
        previewURLs = active.selectedFiles
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
        let files = active.selectedEntries.filter { !$0.isParent && !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else { NSSound.beep(); return }
        let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.showError(error) } }
        }
    }
    @objc func copySelection() { transfer(.copy) }
    @objc func moveSelection() { transfer(.move) }
    private func transfer(_ kind: TransferKind) {
        guard !busy, let window = view.window, window.attachedSheet == nil else { return }
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
        guard !busy, view.window?.attachedSheet == nil else { return }
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
    @objc func trashSelection() {
        guard !busy, view.window?.attachedSheet == nil else { return }
        let sources = active.selectedFiles
        guard !sources.isEmpty else { NSSound.beep(); return }
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
    private func runOperation(_ title: String, completion: (() -> Void)? = nil, work: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        actions.forEach { $0.isEnabled = false }
        status.stringValue = title
        progress.startAnimation(nil)
        operationQueue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.actions.forEach { $0.isEnabled = true }
                self.progress.stopAnimation(nil)
                self.refresh()
                switch result {
                case .success:
                    self.status.stringValue = "Fertig"
                    completion?()
                case .failure(let error):
                    self.status.stringValue = "Vorgang angehalten · Panels aktualisiert"
                    self.showError(error, detail: "Bei mehreren Einträgen können vorherige Schritte bereits abgeschlossen sein. Bitte beide Panels prüfen.")
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
        else { status.stringValue = error.localizedDescription }
    }
    private func saveDirectories() {
        UserDefaults.standard.set(left.directory.path, forKey: "leftDirectory")
        UserDefaults.standard.set(right.directory.path, forKey: "rightDirectory")
    }
    @objc func showHelp() {
        guard view.window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "PaneRook · Die ersten Schritte"
        alert.informativeText = "Tab: aktives Panel wechseln\nPfeiltasten: auswählen · ⇧/⌘-Klick: Mehrfachauswahl\nEnter / Doppelklick: öffnen\nRücktaste / ⌘↑: übergeordneter Ordner\nLeertaste / F3: Quick Look\nF4: mit TextEdit bearbeiten\nF5 / F6: in das andere Panel kopieren / verschieben\nF7: Ordner anlegen · F8: Papierkorb\n⌘L: Pfad eingeben · ⌘R: aktualisieren\n⌘⇧.: versteckte Dateien · ⌘U: Panels tauschen\n\nAuf Apple-Tastaturen ggf. fn zusammen mit F1–F8 drücken.\n\nLokale Dateien sind die Grundlage. Terminal, Archive und Remote-Verbindungen folgen in weiteren Schritten."
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: view.window!)
    }
}
