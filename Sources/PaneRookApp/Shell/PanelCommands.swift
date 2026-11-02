import AppKit
import PaneRookPanels

extension CommanderController {
    func registerPanelCommands(in registry: CommandRegistry, menu: CommandMenu, pane: PaneController) {
        for (index, pair) in [
            ("Dateiliste", PanelMode.listing), ("Schnellansicht", .quickView), ("Info", .info), ("Baum", .tree), ("Netzwerk", .network),
        ].enumerated() {
            let (title, mode) = pair
            registry.add(
                menu, title, id: "\(menu.rawValue).mode.\(index)", order: index,
                enabled: { [weak self] in
                    guard let self else { return false }
                    return self.canUseMenus && (pane.remoteContent == nil || mode == .listing)
                        && (mode != .tree || pane.remoteContent != nil || !pane.isArchiveDirectory)
                }, checked: { pane.remoteContent != nil ? mode == .listing : pane.mode == mode }
            ) { [weak self] in
                guard let self else { return }
                pane.setMode(mode)
                pane.showInspection(of: (pane === self.left ? self.right : self.left).selectedFiles.first)
                self.activate(pane)
            }
        }
        for (index, title) in ["Vollständig", "Kompakt"].enumerated() {
            registry.add(
                menu, title, id: "\(menu.rawValue).listing.\(index)", order: 10 + index, group: 1,
                submenu: "Listenformat",
                enabled: { [weak self] in
                    guard let self else { return false }
                    return self.canUseMenus
                }, checked: { pane.isBriefListing == (index == 1) }
            ) { pane.setBriefListing(index == 1) }
        }
        for (index, pair) in [("Name", "name"), ("Größe", "size"), ("Änderungsdatum", "modified")].enumerated() {
            let (title, key) = pair
            registry.add(
                menu, title, id: "\(menu.rawValue).sort.\(key)", order: 20 + index, group: 1,
                submenu: "Sortierreihenfolge",
                enabled: { [weak self] in
                    guard let self else { return false }
                    return self.canUseMenus
                }, checked: { pane.sortKey == key }
            ) { pane.setSort(key: key, ascending: pane.sortAscending) }
        }
        registry.add(
            menu, "Umgekehrt", id: "\(menu.rawValue).sort.reverse", order: 24, group: 1, submenu: "Sortierreihenfolge",
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }, checked: { !pane.sortAscending }
        ) { pane.setSort(key: pane.sortKey, ascending: !pane.sortAscending) }
        registry.add(menu, "Zurück", id: "\(menu.rawValue).back", order: 90, group: 3,
            enabled: { [weak self] in self?.canUseMenus == true }
        ) { pane.goBack() }
        registry.add(menu, "Favoriten", id: "\(menu.rawValue).favorites", order: 91, group: 3,
            enabled: { [weak self] in self?.canUseMenus == true }
        ) { [weak self] in self?.activate(pane); pane.showFavorites() }
        registry.add(menu, "Repository, Status und Versionen …", id: "\(menu.rawValue).git.workspace", order: 91, group: 3,
            submenu: "Git", enabled: { [weak self] in self?.canUseMenus == true && pane.remoteContent == nil && !pane.isArchiveDirectory && pane.mode != .network }
        ) { [weak self] in self?.git.open(pane: pane) }
        registry.add(menu, "Git: Watched umschalten", id: "\(menu.rawValue).git.watch", order: 92, group: 3,
            submenu: "Git", enabled: { [weak self] in self?.canUseMenus == true && pane.canUseGitFilter && !pane.selectedFiles.isEmpty }
        ) { pane.toggleWatched() }
        for (index, filter) in GitFileFilter.allCases.enumerated() {
            registry.add(menu, filter.title, id: "\(menu.rawValue).git.filter.\(filter.rawValue)", order: 93 + index, group: 3,
                submenu: "Git-Filter", enabled: { [weak self] in self?.canUseMenus == true && pane.canUseGitFilter },
                checked: { pane.gitFilter == filter }
            ) { pane.setGitFilter(filter) }
        }
        registry.add(
            menu, "Neu einlesen", id: "\(menu.rawValue).refresh", order: 100, group: 3,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.canUseMenus
            }
        ) { pane.refresh() }
    }
}
