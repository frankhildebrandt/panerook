import AppKit

extension FileOperations {
    func registerCommands(in registry: CommandRegistry) {
        let movable = { self.owner.canUseSelection && self.owner.otherPane.remoteContent == nil }
        registry.add(
            .file, "Kopieren …", id: "copy", order: 50, group: 0, function: 5, dockTitle: {
                if self.owner.activePane.remoteContent != nil { return "Laden" }
                if self.owner.otherPane.remoteContent != nil { return "Hochladen" }
                return "Kopieren"
            },
            enabled: { self.canCopySelection }
        ) { self.copySelection() }
        registry.add(
            .file, "Umbenennen/Verschieben …", id: "move", order: 130, group: 0, function: 6,
            dockTitle: { "Verschieben" }, enabled: movable
        ) { self.moveSelection() }
        registry.add(
            .file, "Neues Verzeichnis erstellen …", id: "mkdir", order: 140, group: 0, function: 7,
            dockTitle: { "Neuer Ordner" }, enabled: { self.canMakeDirectory }
        ) { self.makeDirectory() }
        registry.add(
            .file, "Sparse-Datei erstellen …", id: "files.createSparse", order: 150, group: 0, key: "n",
            modifiers: [.command, .option], enabled: { self.owner.canUseNativeDirectory }
        ) { self.createSparseFile() }
        let delete = registry.add(
            .file, "Löschen / Papierkorb …", id: "trash", order: 160, group: 0, function: 8,
            dockTitle: { self.owner.activePane.remoteContent != nil || self.owner.activePane.isArchiveDirectory ? "Löschen" : "Papierkorb" },
            enabled: { self.canTrashSelection }
        ) { self.trashSelection() }
        delete.toolTip =
            "Lokale Dateien kommen in den Papierkorb. Remote- und Archiveinträge werden nach Rückfrage endgültig gelöscht."
        registry.alias(
            "mkdir", in: .command, title: "Neuer Ordner …", id: "files.mkdirShortcut", order: 280, group: 3, key: "n",
            modifiers: [.command, .shift])
        registry.alias(
            "trash", in: .command, title: "Löschen / Papierkorb …", id: "files.trashShortcut", order: 290, group: 3,
            key: "\u{8}")
    }
}
