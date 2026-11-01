import AppKit

/// MC 4.8.33's menu order, backed by native AppKit menus and real app capabilities.
final class CommanderMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private final class Command {
        let run: () -> Void
        let enabled: () -> Bool
        let checked: () -> Bool
        init(run: @escaping () -> Void, enabled: @escaping () -> Bool, checked: @escaping () -> Bool) {
            self.run = run; self.enabled = enabled; self.checked = checked
        }
    }
    private unowned let commander: CommanderController
    private var allMenus: [NSMenu] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var popup: NSMenu!
    private var popupIsTracking = false
    private var keyMonitor: Any?
    init(commander: CommanderController) {
        self.commander = commander
        super.init()
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func install() {
        let main = NSMenu()
        let app = NSMenu(title: "PaneRook")
        native(app, "Über PaneRook", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        native(app, "PaneRook ausblenden", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        app.addItem(.separator())
        native(app, "PaneRook beenden", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        attach(app, to: main)
        for menu in makeCommanderMenus() { attach(menu, to: main) }

        // Preserve macOS text editing and its responder-chain shortcuts.
        let edit = NSMenu(title: "Bearbeiten")
        native(edit, "Widerrufen", Selector(("undo:")), key: "z")
        native(edit, "Ausschneiden", #selector(NSText.cut(_:)), key: "x")
        native(edit, "Kopieren", #selector(NSText.copy(_:)), key: "c")
        native(edit, "Einsetzen", #selector(NSText.paste(_:)), key: "v")
        native(edit, "Alles auswählen", #selector(NSText.selectAll(_:)), key: "a")
        attach(edit, to: main)
        let help = makeMenu("Hilfe")
        add(help, "Tastenkürzel", key: "?", enabled: { self.commander.canUseMenus }) { self.commander.showHelp() }
        add(help, "Menüs", key: functionKey(NSF9FunctionKey), modifiers: []) { self.commander.showMenu() }
        add(help, "Hilfe", key: functionKey(NSF1FunctionKey), modifiers: [], enabled: { self.commander.canUseMenus }) { self.commander.showHelp() }
        attach(help, to: main)
        NSApp.mainMenu = main
        NSApp.helpMenu = help

        popup = makeMenu("Menüs")
        // Menus cannot have two parents. Both copies share the same action/state providers.
        for menu in makeCommanderMenus() { attach(menu, to: popup) }
        commander.onShowMenu = { [weak self] in self?.showPopup() }
        commander.menuIsTracking = { [weak self] in
            guard let self else { return false }
            return self.popupIsTracking || !self.trackingMenus.isEmpty
        }
        commander.onKeyBindingsChanged = { [weak self] in
            guard let self else { return }
            for menu in self.allMenus { for item in menu.items { self.updateKey(item) } }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popupIsTracking || !self.trackingMenus.isEmpty else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if ((event.keyCode == 109 || event.keyCode == 53) && modifiers.isEmpty)
                || (event.keyCode == 5 && modifiers == .control) {
                for menu in self.allMenus { menu.cancelTrackingWithoutAnimation() }
                return nil
            }
            return event
        }
    }

    private func makeCommanderMenus() -> [NSMenu] {
        [panelMenu("Links", pane: commander.left), fileMenu(), commandMenu(), optionsMenu(), panelMenu("Rechts", pane: commander.right)]
    }
    private func makeMenu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        allMenus.append(menu)
        return menu
    }
    private func attach(_ child: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: child.title, action: nil, keyEquivalent: "")
        item.submenu = child
        parent.addItem(item)
    }
    private func native(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
    }
    private func functionKey(_ key: Int) -> String { String(UnicodeScalar(key)!) }
    @discardableResult private func add(_ menu: NSMenu, _ title: String, key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command], enabled: (() -> Bool)? = nil,
        checked: @escaping () -> Bool = { false }, run: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        if modifiers.isEmpty, let name = AppKeyBinding.defaults.first(where: { $0.value.characters == key })?.key {
            item.identifier = .init(name)
            updateKey(item)
        }
        item.representedObject = Command(run: run, enabled: enabled ?? { self.commander.canUseMenus }, checked: checked)
        menu.addItem(item)
        return item
    }
    private func updateKey(_ item: NSMenuItem) {
        guard let id = item.identifier?.rawValue, let binding = AppKeyBinding.saved[id] else { return }
        item.keyEquivalent = binding.characters
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: binding.modifiers)
    }
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? Command, command.enabled() else { return }
        command.run()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.representedObject as? Command else { return false }
        updateKey(menuItem)
        menuItem.state = command.checked() ? .on : .off
        return command.enabled()
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenus.insert(ObjectIdentifier(menu)) }
    func menuDidClose(_ menu: NSMenu) { trackingMenus.remove(ObjectIdentifier(menu)) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.representedObject is Command { item.isEnabled = validateMenuItem(item) }
    }

    private func panelMenu(_ title: String, pane: PaneController) -> NSMenu {
        let menu = makeMenu(title)
        for (title, mode) in [("Dateiliste", PanelMode.listing), ("Schnellansicht", .quickView), ("Info", .info), ("Baum", .tree)] {
            add(menu, title, enabled: { self.commander.canUseMenus && (mode != .tree || !pane.isArchiveDirectory) }, checked: { pane.mode == mode }) {
                pane.setMode(mode)
                pane.showInspection(of: (pane === self.commander.left ? self.commander.right : self.commander.left).selectedFiles.first)
                self.commander.activate(pane)
            }
        }
        menu.addItem(.separator())
        let listing = makeMenu("Listenformat")
        add(listing, "Vollständig", checked: { !pane.isBriefListing }) { pane.setBriefListing(false) }
        add(listing, "Kompakt", checked: { pane.isBriefListing }) { pane.setBriefListing(true) }
        attach(listing, to: menu)
        let sort = makeMenu("Sortierreihenfolge")
        for (label, key) in [("Name", "name"), ("Größe", "size"), ("Änderungsdatum", "modified")] {
            add(sort, label, checked: { pane.sortKey == key }) { pane.setSort(key: key, ascending: pane.sortAscending) }
        }
        sort.addItem(.separator())
        add(sort, "Umgekehrt", checked: { !pane.sortAscending }) { pane.setSort(key: pane.sortKey, ascending: !pane.sortAscending) }
        attach(sort, to: menu)
        add(menu, "Filter …", checked: { !pane.filterPattern.isEmpty }) { self.commander.preferences.filter(pane: pane) }
        add(menu, "Codierung …") { self.commander.preferences.encoding(pane: pane) }
        menu.addItem(.separator())
        add(menu, "FTP-Verbindung …") { self.commander.remote.connect(.ftp, pane: pane) }
        add(menu, "Shell-Verbindung …") { self.commander.remote.connect(.shell, pane: pane) }
        add(menu, "SFTP-Verbindung …") { self.commander.remote.connect(.sftp, pane: pane) }
        add(menu, "Verbindungsarchiv …") { self.commander.remote.showArchive(pane: pane) }
        add(menu, "Anordnen", enabled: { self.commander.canUseMenus && !pane.isArchiveDirectory }) { self.commander.workflow.panelize(external: false, pane: pane) }
        menu.addItem(.separator())
        add(menu, "Neu einlesen") { pane.refresh() }
        return menu
    }
    private func fileMenu() -> NSMenu {
        let menu = makeMenu("Datei")
        let selected = { self.commander.canUseSelection }
        let nativeSelected = { self.commander.canUseNativeSelection }
        add(menu, "Ansicht", key: functionKey(NSF3FunctionKey), modifiers: [], enabled: selected) { self.commander.previewSelection() }
        add(menu, "Datei anzeigen …") { self.commander.choosePreviewFile() }
        add(menu, "Gefilterte Ansicht", enabled: nativeSelected) { self.commander.workflow.filteredView() }
        add(menu, "Bearbeiten", key: functionKey(NSF4FunctionKey), modifiers: [], enabled: {
            self.commander.canUseNativeSelection && self.commander.active.selectedEntries.contains { !$0.isParent && !$0.isDirectory }
        }) { self.commander.editSelection() }
        add(menu, "Kopieren …", key: functionKey(NSF5FunctionKey), modifiers: [], enabled: selected) { self.commander.copySelection() }
        add(menu, "Chmod", enabled: nativeSelected) { self.commander.metadata.chmod() }
        add(menu, "Link", enabled: nativeSelected) { self.commander.metadata.createHardLink() }
        add(menu, "Symbolischer Link", enabled: nativeSelected) { self.commander.metadata.createSymbolicLink(relative: false) }
        add(menu, "Relativer symbolischer Link", enabled: nativeSelected) { self.commander.metadata.createSymbolicLink(relative: true) }
        add(menu, "Symbolischen Link bearbeiten", enabled: { nativeSelected() && self.commander.active.selectedEntries.count == 1 && self.commander.active.selectedEntries.first?.isSymbolicLink == true }) { self.commander.metadata.editSymbolicLink() }
        add(menu, "Chown", enabled: nativeSelected) { self.commander.metadata.chown(advanced: false) }
        add(menu, "Erweitertes chown", enabled: nativeSelected) { self.commander.metadata.chown(advanced: true) }
        add(menu, "Umbenennen/Verschieben …", key: functionKey(NSF6FunctionKey), modifiers: [], enabled: selected) { self.commander.moveSelection() }
        add(menu, "Neues Verzeichnis erstellen …", key: functionKey(NSF7FunctionKey), modifiers: [], enabled: { self.commander.canUseLocalDirectory }) { self.commander.makeDirectory() }
        add(menu, "Sparse-Datei erstellen …", key: "n", modifiers: [.command, .option], enabled: { self.commander.canUseNativeDirectory }) { self.commander.createSparseFile() }
        let delete = add(menu, "Löschen / Papierkorb …", key: functionKey(NSF8FunctionKey), modifiers: [], enabled: selected) { self.commander.trashSelection() }
        delete.toolTip = "Lokale Dateien kommen in den Papierkorb. Archiveinträge werden nach Rückfrage endgültig gelöscht."
        add(menu, "Schnelles cd", key: "l") { self.commander.focusPath() }
        menu.addItem(.separator())
        add(menu, "Gruppe auswählen …") { self.commander.selectGroup(select: true) }
        add(menu, "Gruppe abwählen …") { self.commander.selectGroup(select: false) }
        add(menu, "Auswahl umkehren") { self.commander.active.invertSelection() }
        menu.addItem(.separator())
        // F10 is contextual: menu tracking cancels; FileTable handles exit outside menus.
        let exit = add(menu, "Verlassen", enabled: { !self.commander.isPerformingOperation }) { self.commander.exitOrCancelDialog() }
        exit.toolTip = "F10 außerhalb eines Menüs"
        return menu
    }
    private func commandMenu() -> NSMenu {
        let menu = makeMenu("Befehl")
        add(menu, "Benutzermenü", key: functionKey(NSF2FunctionKey), modifiers: [], enabled: { self.commander.canUseNativeDirectory }) { self.commander.workflow.userMenu() }.identifier = .init("userMenu")
        add(menu, "Verzeichnisbaum", enabled: { self.commander.canUseNativeDirectory }) { self.commander.localTools.directoryTree() }
        add(menu, "Datei suchen", key: "f", modifiers: [.command, .shift], enabled: { self.commander.canUseNativeDirectory }) { self.commander.localTools.findFiles() }
        add(menu, "Panels vertauschen", key: "u") { self.commander.swapPanels() }
        add(menu, "Panels an/aus", key: "o", modifiers: .control, checked: { self.commander.arePanelsHidden }) { self.commander.togglePanels() }
        add(menu, "Verzeichnisse vergleichen", enabled: { self.commander.canUseMenus && !self.commander.left.isArchiveDirectory && !self.commander.right.isArchiveDirectory }) { self.commander.localTools.compareDirectories() }
        add(menu, "Dateien vergleichen", enabled: { self.commander.canUseMenus && !self.commander.left.isArchiveDirectory && !self.commander.right.isArchiveDirectory }) { self.commander.localTools.compareFiles() }
        add(menu, "Externes Anordnen", enabled: { self.commander.canUseNativeDirectory }) { self.commander.workflow.panelize() }
        add(menu, "Verzeichnisgrößen anzeigen", enabled: { self.commander.canUseNativeDirectory }) { self.commander.localTools.directorySizes() }
        menu.addItem(.separator())
        add(menu, "Befehlschronik") { self.commander.workflow.commandHistory() }
        add(menu, "Chronik der angezeigten/bearbeiteten Dateien") { self.commander.workflow.showFileHistory() }
        add(menu, "Verzeichnis-Hotlist", key: "d", modifiers: .control) { self.commander.workflow.hotlist() }
        add(menu, "Aktive VFS-Liste") { self.commander.remote.showConnections() }
        add(menu, "Verbindungsarchiv …", key: "k") { self.commander.remote.showArchive(pane: self.commander.active) }
        add(menu, "Hintergrundaufgaben", enabled: { self.commander.view.window?.attachedSheet == nil }) { self.commander.workflow.backgroundJobs() }
        add(menu, "Bildschirmliste") { self.commander.workflow.screenList() }
        menu.addItem(.separator())
        add(menu, "Erweiterungsdatei bearbeiten") { self.commander.workflow.editConfiguration("extensions") }
        add(menu, "Menüdatei bearbeiten") { self.commander.workflow.editConfiguration("menu") }
        add(menu, "Hervorgehobene Gruppendatei bearbeiten") { self.commander.workflow.editConfiguration("highlight") }
        add(menu, "Hotlist bearbeiten …") { self.commander.workflow.manageHotlist() }
        add(menu, "Befehl ausführen …", enabled: { self.commander.canUseNativeDirectory }) { self.commander.workflow.commandPrompt() }
        // Native companions retain PaneRook's established shortcuts.
        menu.addItem(.separator())
        add(menu, "Öffnen", key: "o") { self.commander.openSelection() }
        add(menu, "Vorschau", key: "y", enabled: { self.commander.canUseMenus && !self.commander.active.selectedFiles.isEmpty }) { self.commander.previewSelection() }
        add(menu, "Übergeordneter Ordner", key: functionKey(NSUpArrowFunctionKey)) { self.commander.goUp() }
        add(menu, "Benutzerordner", key: "h", modifiers: [.command, .shift]) { self.commander.goHome() }
        add(menu, "Im Finder zeigen", key: "r", modifiers: [.command, .shift]) { self.commander.revealInFinder() }
        add(menu, "Aktualisieren", key: "r") { self.commander.refresh() }
        add(menu, "Neuer Ordner …", key: "n", modifiers: [.command, .shift], enabled: { self.commander.canUseLocalDirectory }) { self.commander.makeDirectory() }
        add(menu, "Löschen / Papierkorb …", key: "\u{8}", enabled: { self.commander.canUseMenus && !self.commander.active.selectedFiles.isEmpty }) { self.commander.trashSelection() }
        return menu
    }
    private func optionsMenu() -> NSMenu {
        let menu = makeMenu("Optionen")
        add(menu, "Konfiguration …") { self.commander.preferences.configuration() }
        add(menu, "Layout …") { self.commander.preferences.layout() }
        add(menu, "Paneloptionen …") { self.commander.preferences.panelOptions() }
        add(menu, "Nachfragen …") { self.commander.preferences.confirmations() }
        add(menu, "Aussehen …") { self.commander.preferences.appearance() }
        add(menu, "Darstellungsbits …") { self.commander.preferences.encoding() }
        add(menu, "Tasten lernen …") { self.commander.preferences.learnKeys() }
        add(menu, "Virtuelles Dateisystem …") { self.commander.remote.configure() }
        menu.addItem(.separator())
        add(menu, "Einstellungen speichern") { self.commander.saveSetup() }
        menu.addItem(.separator())
        add(menu, "Versteckte Dateien", key: ".", modifiers: [.command, .shift], checked: { self.commander.left.showHidden }) { self.commander.toggleHidden() }
        return menu
    }

    private func showPopup() {
        guard commander.canUseMenus, let window = commander.view.window else { return }
        let previous = window.firstResponder
        let selected = popup.items[commander.active === commander.left ? 0 : 4]
        popupIsTracking = true
        let choseAction = popup.popUp(positioning: selected, at: NSPoint(x: 12, y: commander.view.bounds.maxY - 8), in: commander.view)
        popupIsTracking = false
        if !choseAction, window.attachedSheet == nil, let previous { window.makeFirstResponder(previous) }
    }
}
