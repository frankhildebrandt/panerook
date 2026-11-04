import AppKit

extension PreferencesTools {
    func registerCommands(in registry: CommandRegistry) {
        registry.add(
            .options, "Einstellungen …", id: "preferences.configuration", order: 10, group: 0, key: ",",
            enabled: { self.canShowSettings }
        ) { self.showSettings() }
        // Preserve existing action IDs while all pages now live in the settings window.
        for (id, title, section) in [
            ("preferences.layout", "Layout …", SettingsSection.layout),
            ("preferences.panels", "Paneloptionen …", .panels),
            ("preferences.confirmations", "Nachfragen …", .confirmations),
            ("preferences.appearance", "Aussehen …", .appearance),
            ("preferences.encoding", "Darstellungsbits …", .encoding),
            ("preferences.connections", "Verbindungseinstellungen …", .connections),
            ("remote.preferences", "VFS-Einstellungen …", .connections)
        ] {
            registry.add(.options, title, id: id, order: 20, visibleInMenu: false,
                enabled: { self.owner.canUseMenus }
            ) { self.showSettings(section: section) }
        }
        registry.add(.options, "Tastaturbelegung …", id: "preferences.keyBindings", order: 70,
            visibleInMenu: false, enabled: { self.owner.canUseMenus }
        ) { self.learnKeys() }
    }
}

extension PreferencesTools {
    func registerPanelCommands(in registry: CommandRegistry, menu: CommandMenu, pane initialPane: any PanelAccess, resolvePane: (() -> any PanelAccess)? = nil) {
        var pane: any PanelAccess { resolvePane?() ?? initialPane }
        registry.add(
            menu, "Filter …", id: "\(menu.rawValue).filter", order: 30, group: 1, enabled: { self.owner.canUseMenus },
            checked: { !pane.filterPattern.isEmpty }
        ) { self.filter(pane: pane) }
        registry.add(
            menu, "Codierung …", id: "\(menu.rawValue).encoding", order: 40, group: 1,
            enabled: { self.owner.canUseMenus }
        ) { self.encoding(pane: pane) }
    }
}
