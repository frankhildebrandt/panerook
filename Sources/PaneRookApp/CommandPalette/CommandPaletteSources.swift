import AppKit
import PaneRookCore
import PaneRookRemote

protocol CommandPaletteHost: PanelPresenting, PanelPairProviding {
    var commandRegistry: CommandRegistry { get }
    var canPresentCommandPalette: Bool { get }
    var paletteCommandScopes: Set<CommandScope> { get }
    func savedBookmarks() throws -> [ConnectionBookmark]
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess)
}

extension CommandPaletteTools {
    func registerCommands(in registry: CommandRegistry) {
        registry.add(.command, "Befehlspalette …", id: "commands.palette", order: 5, group: 0,
            key: "p", modifiers: [.command, .shift],
            enabled: { [weak self] in self?.owner.canPresentCommandPalette == true }
        ) { [weak self] in self?.show() }
    }

    /// Each source can be extended or replaced independently, e.g. by a workspace source.
    /// Reading saved destinations never starts Git, probes mounts or connects to a server.
    func sources(pane: any PanelAccess, scopes: Set<CommandScope>) -> [any CommandPaletteSource] {
        let registry = owner.commandRegistry
        let available: () -> Bool = { [weak self, weak pane] in
            guard let self, let pane else { return false }
            return self.owner.canUseMenus && self.owner.activePane === pane
        }
        func location(_ url: URL, category: String, extra: String = "",
                      policy: @escaping () -> Bool = { true }) -> CommandPaletteEntry {
            let path = url.standardizedFileURL.path
            return CommandPaletteEntry(id: "location:" + path,
                title: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,
                detail: category + (extra.isEmpty ? "" : " · " + extra) + " · " + path, keywords: extra,
                enabled: { available() && policy() }, run: { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    pane.setMode(.listing)
                    pane.navigate(to: url)
                    self.owner.activate(pane)
                })
        }
        return [
            ClosureCommandPaletteSource(title: "Aktionen") {
                let bindings = registry.bindings
                return registry.customizableCommands.filter {
                    $0.id != "commands.palette" && scopes.contains($0.scope)
                }.map { command in
                    // Capture before the search field takes focus. Policies such as
                    // file undo and clipboard exchange require the original responder.
                    // After dismissal, use that same live policy before dispatching.
                    let enabledAtOrigin = command.enabled()
                    return CommandPaletteEntry(id: "command:" + command.id, title: command.menuTitle?() ?? command.title,
                        detail: "Aktion · " + command.categoryTitle, keywords: command.id,
                        shortcut: bindings[command.id]?.label ?? "",
                        enabled: { [weak self] in
                            available() && (self?.isPresented == true ? enabledAtOrigin : command.enabled())
                        }, run: { command.perform() })
                }
            },
            ClosureCommandPaletteSource(title: "Favoriten") { [favorites] in
                try favorites.folders().map { location($0, category: "Favorit") }
            },
            ClosureCommandPaletteSource(title: "Verbindungen") { [weak self, weak pane] in
                guard let self, let pane else { return [] }
                return try self.owner.savedBookmarks().sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }.map { bookmark in
                    CommandPaletteEntry(id: "connection:" + bookmark.id.uuidString, title: bookmark.name,
                        detail: "Verbindung · \(bookmark.kind.provider.title) · \(bookmark.user)@\(bookmark.host):\(bookmark.port)\(bookmark.path)",
                        enabled: available, run: { [weak self, weak pane] in
                            guard let self, let pane else { return }
                            self.owner.openSavedBookmark(bookmark, pane: pane)
                        })
                }
            },
            ClosureCommandPaletteSource(title: "Git-Repositories") { [repositories] in
                let saved = repositories.repositories()
                if let error = repositories.errorMessage {
                    throw NSError(domain: "CommandPalette", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: error])
                }
                return saved.flatMap { repository in
                    repository.worktrees.filter { !$0.isBare && !$0.isPrunable }.map { worktree in
                        location(worktree.url, category: "Git-Worktree",
                                 extra: worktree.branch ?? "Detached HEAD",
                                 policy: { !worktree.isPrunable && !worktree.isBare })
                    }
                }
            },
            ClosureCommandPaletteSource(title: "Besuchte Orte") { [weak self, weak pane] in
                guard let self, let pane else { return [] }
                let other = pane === self.owner.leftPane ? self.owner.rightPane : self.owner.leftPane
                return (pane.visitedDirectories + other.visitedDirectories).map { location($0, category: "Besuchter Ort") }
            }
        ]
    }
}
