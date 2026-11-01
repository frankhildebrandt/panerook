import AppKit

extension LocalTools {
    func registerCommands(in registry: CommandRegistry) {
        guard let owner else { return }
        registry.add(
            .command, "Verzeichnisbaum", id: "inspection.tree", order: 20, group: 0,
            enabled: { [weak owner] in
                guard let owner else { return false }
                return owner.canUseNativeDirectory
            }
        ) { self.directoryTree() }
        registry.add(
            .command, "Datei suchen", id: "inspection.search", order: 30, group: 0, key: "f",
            modifiers: [.command, .shift],
            enabled: { [weak owner] in
                guard let owner else { return false }
                return owner.canUseNativeDirectory
            }
        ) { self.findFiles() }
        registry.add(
            .command, "Verzeichnisse vergleichen", id: "inspection.compareDirectories", order: 60, group: 0,
            enabled: { [weak owner] in
                guard let owner else { return false }
                return owner.canUseMenus && !owner.leftPane.isArchiveDirectory && !owner.rightPane.isArchiveDirectory
            }
        ) { self.compareDirectories() }
        registry.add(
            .command, "Dateien vergleichen", id: "inspection.compareFiles", order: 70, group: 0,
            enabled: { [weak owner] in
                guard let owner else { return false }
                return owner.canUseMenus && !owner.leftPane.isArchiveDirectory && !owner.rightPane.isArchiveDirectory
            }
        ) { self.compareFiles() }
        registry.add(
            .command, "Verzeichnisgrößen anzeigen", id: "inspection.directorySizes", order: 90, group: 0,
            enabled: { [weak owner] in
                guard let owner else { return false }
                return owner.canUseNativeDirectory
            }
        ) { self.directorySizes() }
    }
}
