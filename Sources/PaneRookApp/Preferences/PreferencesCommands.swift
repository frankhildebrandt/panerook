import AppKit

extension PreferencesTools {
    func registerCommands(in registry: CommandRegistry) {
        registry.add(
            .options, "Konfiguration …", id: "preferences.configuration", order: 10, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.configuration() }
        registry.add(
            .options, "Layout …", id: "preferences.layout", order: 20, group: 0, enabled: { self.owner.canUseMenus }
        ) { self.layout() }
        registry.add(
            .options, "Paneloptionen …", id: "preferences.panels", order: 30, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.panelOptions() }
        registry.add(
            .options, "Nachfragen …", id: "preferences.confirmations", order: 40, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.confirmations() }
        registry.add(
            .options, "Aussehen …", id: "preferences.appearance", order: 50, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.appearance() }
        registry.add(
            .options, "Darstellungsbits …", id: "preferences.encoding", order: 60, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.encoding() }
        registry.add(
            .options, "Tasten lernen …", id: "preferences.keyBindings", order: 70, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.learnKeys() }
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
