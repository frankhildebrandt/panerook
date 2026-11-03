import AppKit

protocol WorkspaceHost: PanelPresenting, ErrorPresenting {
    var workspaceNames: [(UUID, String)] { get }
    var currentWorkspaceName: String { get }
    var canClosePanelTab: Bool { get }
    var canReconnectWorkspaceTab: Bool { get }
    func createPanelTab()
    func closePanelTab()
    func cyclePanelTab(_ offset: Int)
    func reconnectWorkspaceTab()
    func saveWorkspace(named name: String) throws
    func loadWorkspace(id: UUID)
    func removeWorkspace(id: UUID)
    func createWorkspace()
}

final class WorkspaceTools {
    unowned let owner: any WorkspaceHost
    init(owner: any WorkspaceHost) { self.owner = owner }
    func registerCommands(in registry: CommandRegistry) {
        let enabled = { self.owner.canUseMenus }
        registry.add(.command, "Neuer Tab", id: "tabs.new", order: 300, group: 4, submenu: "Tabs", key: "t", enabled: enabled) { self.owner.createPanelTab() }
        registry.add(.command, "Tab schließen", id: "tabs.close", order: 301, group: 4, submenu: "Tabs", key: "w", modifiers: [.command, .shift],
            enabled: { enabled() && self.owner.canClosePanelTab }) { self.owner.closePanelTab() }
        registry.add(.command, "Nächster Tab", id: "tabs.next", order: 302, group: 4, submenu: "Tabs", key: "]", modifiers: [.command, .shift], enabled: enabled) { self.owner.cyclePanelTab(1) }
        registry.add(.command, "Vorheriger Tab", id: "tabs.previous", order: 303, group: 4, submenu: "Tabs", key: "[", modifiers: [.command, .shift], enabled: enabled) { self.owner.cyclePanelTab(-1) }
        registry.add(.command, "Neuer Arbeitsbereich", id: "workspaces.new", order: 310, group: 4, submenu: "Arbeitsbereiche", enabled: enabled) { self.owner.createWorkspace() }
        registry.add(.command, "Arbeitsbereich benennen / speichern …", id: "workspaces.save", order: 311, group: 4, submenu: "Arbeitsbereiche", enabled: enabled) { self.save() }
        registry.add(.command, "Arbeitsbereiche öffnen / verwalten …", id: "workspaces.manage", order: 312, group: 4, submenu: "Arbeitsbereiche", enabled: enabled) { self.manage() }
        registry.add(.command, "Remote-Tab wieder verbinden …", id: "workspaces.reconnect", order: 313, group: 4, submenu: "Arbeitsbereiche",
            enabled: { enabled() && self.owner.canReconnectWorkspaceTab }) { self.owner.reconnectWorkspaceTab() }
    }
    private func save() {
        ToolUI.prompt(owner: owner, title: "Arbeitsbereich speichern", label: "Name für beide Panelgruppen · z. B. Website",
            value: owner.currentWorkspaceName, accept: "Speichern") { [weak self] name in
            do { try self?.owner.saveWorkspace(named: name) }
            catch { DispatchQueue.main.async { self?.owner.showError(error) } }
        }
    }
    private func manage() {
        guard let window = owner.presentationWindow else { return }
        let entries = owner.workspaceNames
        let alert = NSAlert(); alert.messageText = "Benannte Arbeitsbereiche"
        alert.informativeText = entries.isEmpty ? "Noch keine Arbeitsbereiche gespeichert. Benenne den aktuellen Arbeitsbereich über das Menü Befehl → Arbeitsbereiche." : "Öffnen stellt beide Panelgruppen wieder her. Änderungen werden automatisch gespeichert. Entfernen löscht nur den gespeicherten Namen; laufende Sitzungen und Aufgaben bleiben erhalten."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        popup.addItems(withTitles: entries.map { $0.1 })
        if !entries.isEmpty {
            alert.accessoryView = popup
            alert.addButton(withTitle: "Öffnen"); alert.addButton(withTitle: "Entfernen")
        }
        alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, entries.indices.contains(popup.indexOfSelectedItem) else { return }
            let id = entries[popup.indexOfSelectedItem].0
            DispatchQueue.main.async {
                if response == .alertFirstButtonReturn { self.owner.loadWorkspace(id: id) }
                if response == .alertSecondButtonReturn { self.owner.removeWorkspace(id: id) }
            }
        }
    }
}
