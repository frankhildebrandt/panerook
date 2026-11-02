import AppKit
import PaneRookRemote

extension RemoteTools {
    func registerCommands(in registry: CommandRegistry) {
        registry.add(
            .command, "Aktive VFS-Liste", id: "remote.connections", order: 130, group: 1,
            enabled: { self.owner.canUseMenus }
        ) { self.showConnections() }
        registry.add(
            .command, "Verbindungsarchiv …", id: "remote.bookmarks", order: 140, group: 1, key: "k",
            enabled: { self.owner.canUseMenus }
        ) { self.showArchive(pane: self.owner.activePane) }
    }
}

extension RemoteTools {
    func registerPanelCommands(in registry: CommandRegistry, menu: CommandMenu, pane: any PanelAccess) {
        for (index, kind) in RemoteProtocol.available.sorted(by: { $0.provider.menuOrder < $1.provider.menuOrder })
            .enumerated()
        {
            registry.add(
                menu, kind.provider.menuTitle, id: "\(menu.rawValue).remote.\(kind.rawValue)", order: 50 + index,
                group: 2, enabled: { self.owner.canUseMenus }
            ) { self.connect(kind, pane: pane) }
        }
        registry.add(
            menu, "Verbindungsarchiv …", id: "\(menu.rawValue).connections", order: 60, group: 2,
            enabled: { self.owner.canUseMenus }
        ) { self.showArchive(pane: pane) }
    }
}
