import AppKit
import PaneRookRemote

extension CommanderController: InspectionHost, RemoteHost, MetadataHost, WorkflowHost, PreferencesHost, FavoritesHost,
    FileOperationsHost, PreviewHost, GitHost, NativeFileExchangeHost
{
    var presentationWindow: NSWindow? { view.window }
    var activePane: any PanelAccess { active }
    var leftPane: any PanelAccess { left }
    var rightPane: any PanelAccess { right }
    var otherPane: any PanelAccess { other }
    func activate(_ pane: any PanelAccess) {
        if pane === left { activate(left) } else if pane === right { activate(right) }
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
        registerHelpCommands(in: registry)
        fileOperations.registerCommands(in: registry)
        fileExchange.registerCommands(in: registry)
        preview.registerCommands(in: registry)
        metadata.registerCommands(in: registry)
        workflow.registerCommands(in: registry)
        localTools.registerCommands(in: registry)
        remote.registerCommands(in: registry)
        git.registerCommands(in: registry)
        preferences.registerCommands(in: registry)
        for (menu, pane) in [(CommandMenu.left, left), (.right, right)] {
            registerPanelCommands(in: registry, menu: menu, pane: pane)
            remote.registerPanelCommands(in: registry, menu: menu, pane: pane)
            preferences.registerPanelCommands(in: registry, menu: menu, pane: pane)
            workflow.registerPanelCommands(in: registry, menu: menu, pane: pane)
        }
        registry.addContextDefinitions()
        return registry
    }
}
