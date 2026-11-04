import AppKit
import PaneRookRemote

extension CommanderController: InspectionHost, RemoteHost, MetadataHost, WorkflowHost, PreferencesHost, FavoritesHost,
    FileOperationsHost, PreviewHost, GitHost, NativeFileExchangeHost, CommandPaletteHost
{
    var allPanes: [any PanelAccess] { allTabPanes }
    func oppositePane(for pane: any PanelAccess) -> any PanelAccess {
        for workspace in [workspaceSession] + Array(liveWorkspaces.values) {
            if workspace.left.panes.contains(where: { $0 === pane }) { return workspace.right.selected }
            if workspace.right.panes.contains(where: { $0 === pane }) { return workspace.left.selected }
        }
        return other
    }
    var presentationWindow: NSWindow? { view.window }
    var activePane: any PanelAccess { active }
    var leftPane: any PanelAccess { left }
    var rightPane: any PanelAccess { right }
    var otherPane: any PanelAccess { other }
    var canPresentCommandPalette: Bool {
        canUseMenus && !commandPalette.isPresented && !KeyboardCaptureState.isRecording
    }
    var paletteCommandScopes: Set<CommandScope> {
        var scopes: Set<CommandScope> = [.application]
        if panelsHidden { scopes.insert(.console) }
        else if active.hasPanelKeyboardFocus && !active.hasTerminalKeyboardFocus { scopes.insert(.panel) }
        return scopes
    }
    func activate(_ pane: any PanelAccess) {
        if let pane = pane as? PaneController { activate(pane) }
    }
    func recordFiles(_ urls: [URL]) { workflow.recordFiles(urls) }
    func openUsingExtension(_ urls: [URL]) -> Bool { workflow.openUsingExtension(urls) }
    func refreshHighlights() { workflow.applyHighlights() }
    func setHiddenFilesVisible(_ visible: Bool) {
        if left.showHidden != visible { toggleHidden() }
    }
    func remoteSettingsChanged() { remote.settingsChanged() }
    func showConnectionArchive(pane: any PanelAccess) { remote.showArchive(pane: pane) }
    func savedBookmarks() throws -> [ConnectionBookmark] { try remote.savedBookmarks() }
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess) {
        remote.openSavedBookmark(bookmark, pane: pane)
    }
}

extension CommanderController {
    func makeCommandRegistry(defaults: UserDefaults = .standard) -> CommandRegistry {
        let registry = CommandRegistry(defaults: defaults)
        registerCommands(in: registry)
        workspaceTools.registerCommands(in: registry)
        registerHelpCommands(in: registry)
        fileOperations.registerCommands(in: registry)
        fileExchange.registerCommands(in: registry)
        fileContextActions.registerCommands(in: registry)
        preview.registerCommands(in: registry)
        metadata.registerCommands(in: registry)
        workflow.registerCommands(in: registry)
        localTools.registerCommands(in: registry)
        remote.registerCommands(in: registry)
        git.registerCommands(in: registry)
        preferences.registerCommands(in: registry)
        commandPalette.registerCommands(in: registry)
        for (menu, pane) in [(CommandMenu.left, left), (.right, right)] {
            let resolve = { [unowned self] in menu == .left ? self.left : self.right }
            registerPanelCommands(in: registry, menu: menu, pane: pane, resolvePane: resolve)
            remote.registerPanelCommands(in: registry, menu: menu, pane: pane, resolvePane: resolve)
            preferences.registerPanelCommands(in: registry, menu: menu, pane: pane, resolvePane: resolve)
            workflow.registerPanelCommands(in: registry, menu: menu, pane: pane, resolvePane: resolve)
        }
        registry.addContextDefinitions()
        return registry
    }
}
