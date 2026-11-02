import AppKit

extension PreviewTools {
    func registerCommands(in registry: CommandRegistry) {
        let selected = {
            self.owner.canUseMenus && (self.owner.activePane.remoteContent?.canPreview ?? self.owner.canUseSelection)
        }
        registry.add(
            .file, "Ansicht", id: "preview", order: 10, group: 0, function: 3, dockTitle: { "Vorschau" },
            enabled: selected
        ) { self.previewSelection() }
        registry.add(
            .file, "Datei anzeigen …", id: "preview.chooseFile", order: 20, group: 0,
            enabled: { self.owner.canUseMenus }
        ) { self.choosePreviewFile() }
        registry.add(
            .file, "Bearbeiten", id: "edit", order: 40, group: 0, function: 4, dockTitle: { "Bearbeiten" },
            enabled: {
                self.owner.canUseNativeSelection
                    && self.owner.activePane.selectedEntries.contains { !$0.isParent && !$0.isDirectory }
            }
        ) { self.editSelection() }
        registry.add(
            .command, "Öffnen", id: "preview.open", order: 220, group: 3, key: "o", enabled: { self.owner.canUseMenus }
        ) { self.openSelection() }
        registry.alias(
            "preview", in: .command, title: "Vorschau", id: "preview.shortcut", order: 230, group: 3, key: "y")
    }
}
