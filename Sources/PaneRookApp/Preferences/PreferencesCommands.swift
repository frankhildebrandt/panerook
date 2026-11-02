import AppKit

extension PreferencesTools {
    func registerCommands(in registry: CommandRegistry) {
        registry.add(
            .options, "Einstellungen …", id: "preferences.configuration", order: 10, group: 0, key: ",",
            enabled: { self.owner.canUseMenus }
        ) { self.showSettings() }
    }
}

extension PreferencesTools {
    func registerPanelCommands(in registry: CommandRegistry, menu: CommandMenu, pane: any PanelAccess) {
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
