import AppKit
import PaneRookCore
import PaneRookPanels

protocol GitHost: PanelPresenting, PanelPairProviding, ErrorPresenting {
    func refreshAfterTask()
}

/// Repository windows own their selection and captured repository, independent of panel navigation.
final class GitTools {
    unowned let owner: any GitHost
    private var workspaces: [String: GitWorkspace] = [:]
    private var opening = false

    init(owner: any GitHost) { self.owner = owner }

    func open(pane: any PanelAccess) {
        guard !opening, pane.remoteContent == nil, !pane.isArchiveDirectory else { return }
        let directory = pane.directory
        let selected = pane.selectedFiles.count == 1 ? pane.selectedFiles.first : nil
        opening = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try GitRepository(directory: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.opening = false
                switch result {
                case .success(let repository):
                    let key = repository.root.path
                    if let workspace = self.workspaces[key] { workspace.present(); workspace.reload(); return }
                    let workspace = GitWorkspace(repository: repository, selectedFile: selected)
                    workspace.onDidChange = { [weak self] in self?.owner.refreshAfterTask() }
                    workspace.onClose = { [weak self] in self?.workspaces.removeValue(forKey: key) }
                    self.workspaces[key] = workspace
                    workspace.present()
                    workspace.reload()
                case .failure(let error): self.owner.showError(error)
                }
            }
        }
    }

    func initialize() {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let directory = owner.activePane.directory
        guard owner.activePane.remoteContent == nil, !owner.activePane.isArchiveDirectory else { return }
        let alert = NSAlert()
        alert.messageText = "Git-Repository anlegen?"
        alert.informativeText = directory.path
        alert.addButton(withTitle: "Repository anlegen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try GitRepository.initialize(in: directory) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let repository):
                        self.owner.refreshAfterTask()
                        let workspace = GitWorkspace(repository: repository, selectedFile: nil)
                        let key = repository.root.path
                        workspace.onDidChange = { [weak self] in self?.owner.refreshAfterTask() }
                        workspace.onClose = { [weak self] in self?.workspaces.removeValue(forKey: key) }
                        self.workspaces[key] = workspace
                        workspace.present(); workspace.reload()
                    case .failure(let error): self.owner.showError(error)
                    }
                }
            }
        }
    }

    func registerCommands(in registry: CommandRegistry) {
        registry.add(.command, "Git-Diff und Verlauf im Panel", id: "git.pane", order: 219, group: 3,
            submenu: "Git", key: "g", modifiers: [.command, .option],
            enabled: { self.owner.canUseMenus && self.owner.activePane.remoteContent == nil },
            checked: { self.owner.activePane.mode == .gitHistory }
        ) { self.owner.activePane.setMode(.gitHistory) }
        registry.add(.command, "Repository, Status und Versionen …", id: "git.workspace", order: 220, group: 3,
            submenu: "Git", key: "g", modifiers: [.command, .shift],
            enabled: { self.owner.canUseMenus && self.owner.activePane.remoteContent == nil && !self.owner.activePane.isArchiveDirectory && self.owner.activePane.mode != .network }
        ) { self.open(pane: self.owner.activePane) }
        registry.add(.command, "Repository im aktuellen Ordner anlegen …", id: "git.initialize", order: 221, group: 3,
            submenu: "Git", enabled: { self.owner.canUseMenus && self.owner.activePane.remoteContent == nil && !self.owner.activePane.isArchiveDirectory && self.owner.activePane.mode != .network }
        ) { self.initialize() }
    }
}
