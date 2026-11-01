import AppKit

extension WorkflowTools {
    func registerCommands(in registry: CommandRegistry) {
        let nativeSelected = { self.owner.canUseNativeSelection }
        registry.add(
            .file, "Gefilterte Ansicht", id: "workflow.filteredView", order: 30, group: 0, enabled: nativeSelected
        ) { self.filteredView() }
        registry.add(
            .command, "Benutzermenü", id: "userMenu", order: 10, group: 0, function: 2,
            enabled: { self.owner.canUseNativeDirectory }
        ) { self.userMenu() }
        registry.add(
            .command, "Externes Anordnen", id: "workflow.panelize", order: 80, group: 0,
            enabled: { self.owner.canUseNativeDirectory }
        ) { self.panelize() }
        registry.add(
            .command, "Befehlschronik", id: "workflow.commandHistory", order: 100, group: 1,
            enabled: { self.owner.canUseMenus }
        ) { self.commandHistory() }
        registry.add(
            .command, "Chronik der angezeigten/bearbeiteten Dateien", id: "workflow.fileHistory", order: 110, group: 1,
            enabled: { self.owner.canUseMenus }
        ) { self.showFileHistory() }
        registry.add(
            .command, "Verzeichnis-Hotlist", id: "workflow.hotlist", order: 120, group: 1, key: "d",
            modifiers: .control, enabled: { self.owner.canUseMenus }
        ) { self.hotlist() }
        registry.add(
            .command, "Hintergrundaufgaben", id: "tasks.showQueue", order: 150, group: 1,
            enabled: { self.owner.presentationWindow?.attachedSheet == nil }
        ) { self.backgroundJobs() }
        registry.add(
            .command, "Bildschirmliste", id: "workflow.windows", order: 160, group: 1,
            enabled: { self.owner.canUseMenus }
        ) { self.screenList() }
        registry.add(
            .command, "Erweiterungsdatei bearbeiten", id: "workflow.editExtensions", order: 170, group: 2,
            enabled: { self.owner.canUseMenus }
        ) { self.editConfiguration("extensions") }
        registry.add(
            .command, "Menüdatei bearbeiten", id: "workflow.editMenu", order: 180, group: 2,
            enabled: { self.owner.canUseMenus }
        ) { self.editConfiguration("menu") }
        registry.add(
            .command, "Hervorgehobene Gruppendatei bearbeiten", id: "workflow.editHighlights", order: 190, group: 2,
            enabled: { self.owner.canUseMenus }
        ) { self.editConfiguration("highlight") }
        registry.add(
            .command, "Hotlist bearbeiten …", id: "workflow.editHotlist", order: 200, group: 2,
            enabled: { self.owner.canUseMenus }
        ) { self.manageHotlist() }
        registry.add(
            .command, "Befehl ausführen …", id: "workflow.runCommand", order: 210, group: 2,
            enabled: { self.owner.canUseNativeDirectory }
        ) { self.commandPrompt() }
    }
}

extension WorkflowTools {
    func registerPanelCommands(in registry: CommandRegistry, menu: CommandMenu, pane: any PanelAccess) {
        registry.add(
            menu, "Anordnen", id: "\(menu.rawValue).panelize", order: 70, group: 2,
            enabled: { self.owner.canUseMenus && !pane.isArchiveDirectory }
        ) { self.panelize(external: false, pane: pane) }
    }
}
