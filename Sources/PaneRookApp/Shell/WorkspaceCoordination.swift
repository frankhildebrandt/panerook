import AppKit
import PaneRookRemote

final class LiveWorkspace {
    let id: UUID
    var name: String
    let left: PanelTabGroupController
    let right: PanelTabGroupController
    var activeRight = false
    init(id: UUID = UUID(), name: String, left: PanelTabGroupController, right: PanelTabGroupController) {
        self.id = id; self.name = name; self.left = left; self.right = right
    }
    var panes: [PaneController] { left.panes + right.panes }
    func snapshot() -> ProjectWorkspace {
        ProjectWorkspace(id: id, name: name,
            left: WorkspacePanelGroup(tabs: left.panes.map { $0.workspaceSnapshot() }, activeTab: left.selected.tabID),
            right: WorkspacePanelGroup(tabs: right.panes.map { $0.workspaceSnapshot() }, activeTab: right.selected.tabID),
            activeRight: activeRight)
    }
}

extension CommanderController {
    var allTabPanes: [PaneController] {
        ([workspaceSession] + Array(liveWorkspaces.values)).flatMap(\.panes).reduce(into: []) { result, pane in
            if !result.contains(where: { $0 === pane }) { result.append(pane) }
        } + retiredTabPanes
    }
    func group(containing pane: PaneController) -> PanelTabGroupController? {
        for workspace in [workspaceSession] + Array(liveWorkspaces.values) {
            if workspace.left.panes.contains(where: { $0 === pane }) { return workspace.left }
            if workspace.right.panes.contains(where: { $0 === pane }) { return workspace.right }
        }
        return nil
    }
    func configureWorkspace(_ workspace: LiveWorkspace) {
        for group in [workspace.left, workspace.right] {
            group.onSelect = { [weak self, weak workspace] pane in
                guard let self, let workspace, self.workspaceSession === workspace else { return }
                self.activate(pane)
                self.synchronizeTabObservationVisibility()
                self.updateTransferPeers()
                self.persistWorkspaces()
            }
            group.onNew = { [weak self, weak group] in
                guard let self, let group, self.canUseMenus else { return }
                self.newTab(in: group)
            }
            group.onClose = { [weak self, weak group] in
                guard let self, let group, self.canUseMenus else { return }
                self.activate(group.selected); self.closeActiveTab()
            }
            for pane in group.panes { configureTab(pane) }
        }
    }
    func configureTab(_ pane: PaneController) {
        pane.setLocalObservationVisible(false)
        pane.installFileExchange(fileExchange)
        favoritesMenus.append(PanelFavoritesController(owner: self, pane: pane, cache: favoriteDestinations))
        pane.onActivate = { [weak self, weak pane] in
            guard let self, let pane else { return }; self.activate(pane, focus: false)
        }
        pane.onWorkspaceReconnectRequested = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.activate(pane); self.reconnectWorkspaceTab()
        }
        pane.onKey = { [weak self] in self?.handleKey($0) ?? false }
        pane.onError = { [weak self] in self?.showError($0) }
        pane.onOpenSelection = { [weak self, weak pane] in
            guard let self, let pane else { return }; self.activate(pane); self.openSelection()
        }
        pane.onDirectoryChanged = { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.group(containing: pane)?.updateTitles()
            self.saveDirectories()
        }
        pane.onRepositoryVisited = { GitRepositoryCatalog.shared.record($0) }
        pane.onOpenGit = { [weak self, weak pane] in
            guard let self, let pane else { return }; self.git.open(pane: pane)
        }
        pane.onGitHistoryRequested = { [weak self, weak pane] in
            guard let self, let pane, let other = self.oppositePane(for: pane) as? PaneController else { return }
            pane.showGitHistory(from: other)
        }
        pane.onSelectionChanged = { [weak self, weak pane] url in
            guard let self, let pane else { return }
            self.group(containing: pane)?.updateTitles()
            // Background tabs must never replace the visible peer's inspection.
            guard pane === self.left || pane === self.right else { return }
            let other = pane === self.left ? self.right : self.left
            other.showInspection(of: url); other.showGitHistory(from: pane)
            self.updateDirectoryActionAvailability()
        }
    }
    func installWorkspaceGroups() {
        for item in splitController.splitViewItems { splitController.removeSplitViewItem(item) }
        for group in [workspaceSession.left, workspaceSession.right] {
            let item = NSSplitViewItem(viewController: group)
            item.minimumThickness = splitController.splitView.isVertical ? 320 : 140
            splitController.addSplitViewItem(item)
        }
        active = workspaceSession.activeRight ? right : left
        activate(active)
        synchronizeTabObservationVisibility()
        updateTransferPeers()
        preferences.apply()
    }
    func synchronizeTabObservationVisibility() {
        for pane in allTabPanes {
            pane.setLocalObservationVisible(!panelsHidden && (pane === left || pane === right))
        }
    }
    func updateTransferPeers() {
        for pane in allTabPanes {
            (pane.remoteContent as? RemoteBrowser)?.peer = oppositePane(for: pane)
        }
        left.showInspection(of: right.selectedFiles.first); right.showInspection(of: left.selectedFiles.first)
        left.showGitHistory(from: right); right.showGitHistory(from: left)
    }
    func newTab(in group: PanelTabGroupController? = nil) {
        let group = group ?? self.group(containing: active)!
        // Duplicate the restorable configuration, never a shell or authenticated connection.
        var snapshot = group.selected.workspaceSnapshot()
        snapshot.id = UUID()
        let pane = PaneController(label: group === workspaceSession.left ? "Links" : "Rechts", directory: snapshot.directory, tabID: snapshot.id)
        configureTab(pane)
        pane.restoreWorkspaceTab(snapshot)
        group.append(pane)
        preferences.apply()
    }
    func closeActiveTab() {
        guard let group = group(containing: active), group.panes.count > 1 else { return }
        let pane = group.selected
        guard pane.remoteContent?.isBusy != true else {
            showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "In diesem Tab läuft ein Remote-Vorgang. Bitte zuerst abschließen oder in der Aufgabenliste abbrechen."]))
            return
        }
        let close = { [weak self, weak group, weak pane] in
            guard let self, let group, let pane, group.selected === pane else { return }
            // Retain closed panels for late local task completions, but close a shell only explicitly.
            pane.setLocalObservationVisible(false)
            pane.closeTabContent()
            self.retiredTabPanes.append(pane)
            _ = group.removeSelected()
            self.persistWorkspaces()
        }
        if pane.hasLiveTerminal, let window = presentationWindow {
            let alert = NSAlert(); alert.messageText = "Tab und Shell-Sitzung schließen?"
            alert.informativeText = "Die Shell in diesem Tab wird beendet. Ein Tabwechsel lässt sie weiterlaufen."
            alert.addButton(withTitle: "Abbrechen"); alert.addButton(withTitle: "Tab schließen")
            alert.configureKeyboardShortcuts()
            alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { close() } }
        } else { close() }
    }
    func reconnectWorkspaceTab() {
        guard let bookmark = active.pendingWorkspaceConnection, (active.remoteContent == nil || active.remoteContent?.awaitsWorkspaceAuthentication == true) else { return }
        remote.openSavedBookmark(bookmark, pane: active)
    }
    func restoreWorkspaceSession() {
        do {
            workspaceArchive = try workspaceStore.load()
            guard workspaceDefaults.object(forKey: "restorePanels") as? Bool != false,
                  let saved = workspaceArchive.session else { return }
            workspaceSession = makeLiveWorkspace(saved)
            if workspaceArchive.workspaces.contains(where: { $0.id == saved.id }) { liveWorkspaces[saved.id] = workspaceSession }
            installWorkspaceGroups()
        } catch { showError(error) }
    }
    func makeLiveWorkspace(_ snapshot: ProjectWorkspace) -> LiveWorkspace {
        func group(_ saved: WorkspacePanelGroup, label: String) -> PanelTabGroupController {
            let panes = saved.tabs.map { PaneController(label: label, directory: $0.directory, tabID: $0.id) }
            let group = PanelTabGroupController(panes: panes, selected: panes.first { $0.tabID == saved.activeTab })
            return group
        }
        let workspace = LiveWorkspace(id: snapshot.id, name: snapshot.name,
            left: group(snapshot.left, label: "Links"), right: group(snapshot.right, label: "Rechts"))
        workspace.activeRight = snapshot.activeRight
        configureWorkspace(workspace)
        for (pane, tab) in zip(workspace.left.panes + workspace.right.panes, snapshot.left.tabs + snapshot.right.tabs) {
            pane.restoreWorkspaceTab(tab)
        }
        return workspace
    }
    func persistWorkspaces() {
        guard !isRestoringWorkspaces else { return }
        workspaceArchive.session = workspaceSession.snapshot()
        for (index, saved) in workspaceArchive.workspaces.enumerated() {
            if let live = liveWorkspaces[saved.id] { workspaceArchive.workspaces[index] = live.snapshot() }
        }
        do { try workspaceStore.save(workspaceArchive) }
        catch { if !reportedWorkspaceError { reportedWorkspaceError = true; showError(error) } }
    }
}

extension CommanderController: WorkspaceHost {
    var workspaceNames: [(UUID, String)] {
        let saved = workspaceArchive.workspaces.map { ($0.id, $0.name) }
        let sessions = liveWorkspaces.values.filter { live in !saved.contains(where: { $0.0 == live.id }) }
            .sorted { $0.id.uuidString < $1.id.uuidString }.map { ($0.id, $0.name + " (Sitzung)") }
        return saved + sessions
    }
    var currentWorkspaceName: String { workspaceSession.name }
    func saveWorkspace(named name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !workspaceArchive.workspaces.contains(where: { $0.id != workspaceSession.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw WorkspaceError.invalidName }
        var archive = workspaceArchive
        var snapshot = workspaceSession.snapshot()
        snapshot.name = name
        if let index = archive.workspaces.firstIndex(where: { $0.id == snapshot.id }) {
            archive.workspaces[index] = snapshot
        } else { archive.workspaces.append(snapshot) }
        archive.session = snapshot
        try workspaceStore.save(archive)
        workspaceSession.name = name
        view.window?.subtitle = name
        liveWorkspaces[workspaceSession.id] = workspaceSession
        workspaceArchive = archive
    }
    func loadWorkspace(id: UUID) {
        guard liveWorkspaces[id] != nil || workspaceArchive.workspaces.contains(where: { $0.id == id }) else { return }
        let saved = workspaceArchive.workspaces.first(where: { $0.id == id })
        persistWorkspaces()
        // Keep the unnamed session too: switching never releases running shells or transfers.
        liveWorkspaces[workspaceSession.id] = workspaceSession
        isRestoringWorkspaces = true
        workspaceSession = liveWorkspaces[id] ?? makeLiveWorkspace(saved!)
        liveWorkspaces[id] = workspaceSession
        installWorkspaceGroups()
        isRestoringWorkspaces = false
        persistWorkspaces()
    }
    func removeWorkspace(id: UUID) {
        workspaceArchive.workspaces.removeAll { $0.id == id }
        // A deleted workspace remains alive until the window closes; its tasks and shells are untouched.
        persistWorkspaces()
    }
    func createWorkspace() {
        persistWorkspaces()
        liveWorkspaces[workspaceSession.id] = workspaceSession
        let home = FileManager.default.homeDirectoryForCurrentUser
        workspaceSession = LiveWorkspace(name: "Unbenannt", left: PanelTabGroupController(panes: [PaneController(label: "Links", directory: home)]),
            right: PanelTabGroupController(panes: [PaneController(label: "Rechts", directory: home)]))
        configureWorkspace(workspaceSession)
        installWorkspaceGroups()
        persistWorkspaces()
    }
    func createPanelTab() { newTab() }
    func closePanelTab() { closeActiveTab() }
    func cyclePanelTab(_ offset: Int) { group(containing: active)?.cycle(offset) }
    var canClosePanelTab: Bool { (group(containing: active)?.panes.count ?? 0) > 1 && active.remoteContent?.isBusy != true }
    var canReconnectWorkspaceTab: Bool { active.pendingWorkspaceConnection != nil && (active.remoteContent == nil || active.remoteContent?.awaitsWorkspaceAuthentication == true) }
}
