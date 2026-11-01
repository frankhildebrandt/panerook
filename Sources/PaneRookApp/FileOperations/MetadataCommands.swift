import AppKit

extension FileMetadataTools {
    func registerCommands(in registry: CommandRegistry) {
        let nativeSelected = { self.owner.canUseNativeSelection }
        registry.add(.file, "Chmod", id: "metadata.chmod", order: 60, group: 0, enabled: nativeSelected) {
            self.chmod()
        }
        registry.add(.file, "Link", id: "metadata.hardLink", order: 70, group: 0, enabled: nativeSelected) {
            self.createHardLink()
        }
        registry.add(
            .file, "Symbolischer Link", id: "metadata.symbolicLink", order: 80, group: 0, enabled: nativeSelected
        ) { self.createSymbolicLink(relative: false) }
        registry.add(
            .file, "Relativer symbolischer Link", id: "metadata.relativeLink", order: 90, group: 0,
            enabled: nativeSelected
        ) { self.createSymbolicLink(relative: true) }
        registry.add(
            .file, "Symbolischen Link bearbeiten", id: "metadata.editLink", order: 100, group: 0,
            enabled: {
                nativeSelected() && self.owner.activePane.selectedEntries.count == 1
                    && self.owner.activePane.selectedEntries.first?.isSymbolicLink == true
            }
        ) { self.editSymbolicLink() }
        registry.add(.file, "Chown", id: "metadata.chown", order: 110, group: 0, enabled: nativeSelected) {
            self.chown(advanced: false)
        }
        registry.add(
            .file, "Erweitertes chown", id: "metadata.advancedChown", order: 120, group: 0, enabled: nativeSelected
        ) { self.chown(advanced: true) }
    }
}
