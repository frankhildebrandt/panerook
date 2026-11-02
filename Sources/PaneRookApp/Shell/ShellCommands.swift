import AppKit

extension CommanderController {
    func registerCommands(in registry: CommandRegistry) {
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
                return self.canUseMenus && self.active.remoteContent == nil
            }
        ) { [weak self] in self?.selectGroup(select: true) }
        registry.add(
            .file, "Gruppe abwählen …", id: "selection.deselectGroup", order: 190, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus && self.active.remoteContent == nil
            }
        ) { [weak self] in self?.selectGroup(select: false) }
        registry.add(
            .file, "Auswahl umkehren", id: "selection.invert", order: 200, group: 1,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus && self.active.remoteContent == nil
            }
        ) { [weak self] in self?.active.invertSelection() }
        let exit = registry.add(
            .file, "Verlassen", id: "exit", order: 210, group: 2, function: 10,
            enabled: { [weak self] in
                guard let self else { return false }
                return !self.isPerformingOperation
            }
        ) { [weak self] in self?.exitOrCancelDialog() }
        exit.toolTip = "F10 außerhalb eines Menüs"
        registry.add(
            .command, "Panels vertauschen", id: "panels.swap", order: 40, group: 0, key: "u",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus && self.left.remoteContent == nil && self.right.remoteContent == nil
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
                return self.canUseMenus && self.active.remoteContent == nil
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
