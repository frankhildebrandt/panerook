import AppKit
import PaneRookCore

final class CommandPaletteTools {
    unowned let owner: any CommandPaletteHost
    let favorites: PanelFavoriteStore
    let repositories: GitRepositoryCatalog
    private(set) var controller: CommandPaletteController?
    var isPresented: Bool { controller != nil }

    init(owner: any CommandPaletteHost, favorites: PanelFavoriteStore = PanelFavoriteStore(),
         repositories: GitRepositoryCatalog = .shared) {
        self.owner = owner; self.favorites = favorites; self.repositories = repositories
    }

    func show() {
        guard !isPresented, owner.canPresentCommandPalette, let window = owner.presentationWindow,
              window.attachedSheet == nil, window.isKeyWindow, !KeyboardCaptureState.isRecording else { return }
        let model = CommandPaletteModel()
        model.load(sources(pane: owner.activePane, scopes: owner.paletteCommandScopes))
        let controller = CommandPaletteController(model: model, registry: owner.commandRegistry, window: window)
        self.controller = controller
        controller.onDismiss = { [weak self] in self?.controller = nil }
        controller.present()
    }

    func handleKey(_ event: NSEvent) -> Bool { controller?.handleKey(event) ?? false }
    func dismiss() { controller?.dismiss() }
}
