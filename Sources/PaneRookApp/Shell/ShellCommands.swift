import AppKit
import PaneRookPanels

extension CommanderController {
    func registerCommands(in registry: CommandRegistry) {
        registerNativeCommands(in: registry)
        registerKeyboardCommands(in: registry)
        registry.add(
            .file, "Schnelles cd", id: "navigation.focusPath", order: 170, group: 0, key: "l",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.focusPath() }
        registry.add(
            .file, "Gruppe auswählen …", id: "selection.selectGroup", order: 180, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.selectGroup(select: true) }
        registry.add(
            .file, "Gruppe abwählen …", id: "selection.deselectGroup", order: 190, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.selectGroup(select: false) }
        registry.add(
            .file, "Auswahl umkehren", id: "selection.invert", order: 200, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.active.invertSelection() }
        registry.add(
            .file, "Verlassen", id: "exit", order: 210, group: 2, function: 10,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.exitOrCancelDialog() }
        registry.add(
            .command, "Panels vertauschen", id: "panels.swap", order: 40, group: 0, key: "u",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.swapPanels() }
        registry.add(
            .command, "Panels an/aus", id: "panels.toggle", order: 50, group: 0, key: "o", modifiers: .control,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            },
            checked: { [weak self] in
                guard let self else { return false }
                return self.arePanelsHidden
            }
        ) { [weak self] in self?.togglePanels() }
        registry.add(
            .command, "Übergeordneter Ordner", id: "navigation.parent", order: 240, group: 3,
            key: functionKey(NSUpArrowFunctionKey),
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.goUp() }
        registry.add(
            .command, "Benutzerordner", id: "navigation.home", order: 250, group: 3, key: "h",
            modifiers: [.command, .shift],
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.goHome() }
        registry.add(
            .command, "Im Finder zeigen", id: "navigation.reveal", order: 260, group: 3, key: "r",
            modifiers: [.command, .shift],
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.revealInFinder() }
        registry.add(
            .command, "Aktualisieren", id: "panels.refresh", order: 270, group: 3, key: "r",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.refresh() }
        registry.add(
            .options, "Einstellungen speichern", id: "preferences.save", order: 90, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.saveSetup() }
        registry.add(
            .options, "Versteckte Dateien", id: "panels.showHidden", order: 100, group: 2, key: ".",
            modifiers: [.command, .shift],
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            },
            checked: { [weak self] in
                guard let self else { return false }
                return self.left.showHidden
            }
        ) { [weak self] in self?.toggleHidden() }
    }
}

extension CommanderController {
    func registerHelpCommands(in registry: CommandRegistry) {
        registry.add(
            .help, "Tastenkürzel", id: "help.shortcuts", order: 0, key: "?",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.showHelp() }
        registry.add(
            .help, "Menüs", id: "menu", order: 1, function: 9,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.showMenu() }
        registry.add(
            .help, "Hilfe", id: "help", order: 2, function: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { [weak self] in self?.showHelp() }
    }
}


extension CommanderController {
    /// Native commands keep their selectors so AppKit still resolves the current text responder.
    private func registerNativeCommands(in registry: CommandRegistry) {
        for (id, title, order, key, selector) in [
            ("app.about", "Über PaneRook", 0, "", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            ("app.hide", "PaneRook ausblenden", 30, "h", #selector(NSApplication.hide(_:))),
            ("app.quit", "PaneRook beenden", 40, "q", #selector(NSApplication.terminate(_:)))
        ] {
            registry.add(.application, title, id: id, order: order, key: key,
                enabled: { true }
            ) { NSApp.sendAction(selector, to: NSApp, from: nil) }
        }
        registry.add(.application, "Nach Updates suchen …", id: "app.updates", order: 10,
            enabled: { [weak self] in
                guard let updater = self?.appUpdater else { return false }
                return updater.validateMenuItem(NSMenuItem(title: "", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: ""))
            }
        ) { [weak self] in self?.appUpdater?.checkForUpdates(nil) }
        registry.add(.application, "Update-Einstellungen …", id: "app.updateSettings", order: 20,
            enabled: { [weak self] in self?.canUseMenus == true }
        ) { [weak self] in self?.preferences.showSettings(section: .updates) }
        for (index, action) in [
            ("editing.undo", "Widerrufen", "z", Selector(("undo:"))),
            ("editing.redo", "Wiederholen", "z", Selector(("redo:"))),
            ("editing.cut", "Ausschneiden", "x", #selector(NSText.cut(_:))),
            ("editing.copy", "Kopieren", "c", #selector(NSText.copy(_:))),
            ("editing.paste", "Einsetzen", "v", #selector(NSText.paste(_:))),
            ("editing.selectAll", "Alles auswählen", "a", #selector(NSText.selectAll(_:)))
        ].enumerated() {
            let (id, title, key, selector) = action
            registry.add(.edit, title, id: id, order: index, key: key,
                modifiers: id == "editing.redo" ? [.command, .shift] : .command, scope: .textEditing,
                enabled: { nativeActionIsEnabled(selector) }
            ) { NSApp.sendAction(selector, to: nil, from: nil) }
        }
    }

    private func registerKeyboardCommands(in registry: CommandRegistry) {
        let panelAvailable: () -> Bool = { [weak self] in self?.canUseMenus == true && self?.panelsHidden == false }
        let actions: [(String, String, AppKeyBinding?, () -> Void)] = [
            ("panels.switch", "Panel wechseln", .physical(48, characters: "\t"), { [weak self] in guard let self else { return }; self.activate(self.other) }),
            ("panels.switch.reverse", "Panel wechseln (rückwärts)", .physical(48, characters: "\t", modifiers: .shift), { [weak self] in guard let self else { return }; self.activate(self.other) }),
            ("navigation.open", "Auswahl öffnen", .physical(36, characters: "\r"), { [weak self] in self?.openSelection() }),
            ("navigation.open.keypad", "Auswahl öffnen (Ziffernblock)", .physical(76, characters: "\u{3}"), { [weak self] in self?.openSelection() }),
            ("navigation.parent.backspace", "Übergeordneter Ordner (Rücktaste)", .physical(51, characters: "\u{8}"), { [weak self] in self?.goUp() }),
            ("navigation.parent.delete", "Übergeordneter Ordner (Entfernen)", .physical(117, characters: functionKey(NSDeleteFunctionKey)), { [weak self] in self?.goUp() }),
            ("preview.space", "Quick Look (Leertaste)", .physical(49, characters: " "), { [weak self] in self?.previewSelection() }),
            ("navigation.favorites", "Favoriten des aktiven Panels", .physical(125, characters: functionKey(NSDownArrowFunctionKey), modifiers: .option), { [weak self] in self?.active.showFavorites() }),
            ("navigation.back", "Zurück im aktiven Panel", nil, { [weak self] in self?.active.goBack() }),
            ("panels.network", "Netzwerk im aktiven Panel", nil, { [weak self] in self?.active.setMode(.network) }),
            ("panels.git.watch", "Git: Auswahl als Watched umschalten", nil, { [weak self] in self?.active.toggleWatched() })
        ]
        for (index, action) in actions.enumerated() {
            let (id, title, binding, run) = action
            registry.add(.command, title, id: id, order: 300 + index, group: 4,
                scope: .panel, visibleInMenu: false, binding: binding, enabled: panelAvailable, run: run)
        }
        registry.add(.command, "Konsolenbefehl ausführen", id: "console.run", order: 320, group: 4,
            scope: .console, visibleInMenu: false, binding: .physical(36, characters: "\r"),
            enabled: { [weak self] in self?.canUseMenus == true && self?.panelsHidden == true }
        ) { [weak self] in self?.runConsoleCommand() }
        registry.alias("console.run", in: .command, title: "Konsolenbefehl ausführen (Ziffernblock)", id: "console.run.keypad", order: 321, group: 4,
            visibleInMenu: false, binding: .physical(76, characters: "\u{3}"))
        for (index, filter) in GitFileFilter.allCases.enumerated() {
            registry.add(.command, "Git-Filter im aktiven Panel: " + filter.title, id: "panels.git.filter.\(filter.rawValue)", order: 330 + index, group: 4,
                scope: .panel, visibleInMenu: false,
                enabled: { [weak self] in self?.canUseMenus == true && self?.active.canUseGitFilter == true }
            ) { [weak self] in self?.active.setGitFilter(filter) }
        }
    }
}

private func nativeActionIsEnabled(_ selector: Selector) -> Bool {
    guard let target = NSApp.target(forAction: selector) else { return false }
    let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
    if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
    if let validator = target as? NSUserInterfaceValidations { return validator.validateUserInterfaceItem(item) }
    return true
}
