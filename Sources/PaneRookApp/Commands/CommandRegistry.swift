import AppKit

func functionKey(_ key: Int) -> String { String(UnicodeScalar(key)!) }

enum CommandMenu: String, CaseIterable {
    case application, left, file, command, options, right, edit, help
    var title: String {
        switch self {
        case .application: return "PaneRook"
        case .left: return "Links"
        case .file: return "Datei"
        case .command: return "Befehl"
        case .options: return "Optionen"
        case .right: return "Rechts"
        case .edit: return "Bearbeiten"
        case .help: return "Hilfe"
        }
    }
}

enum CommandScope: String, CaseIterable {
    case application, panel, textEditing, dialog, remote, remoteEdit, connections, git, tasks, favorites, results, network, console, table
    var title: String {
        switch self {
        case .application: return "Hauptfenster"
        case .panel: return "Dateipanels"
        case .textEditing: return "Textbearbeitung"
        case .dialog: return "Dialoge"
        case .remote: return "Remote-Panels"
        case .remoteEdit: return "Remote-Arbeitskopien"
        case .connections: return "Verbindungsarchiv"
        case .git: return "Git-Workspace"
        case .tasks: return "Aufgaben"
        case .favorites: return "Favoriten und Menüs"
        case .results: return "Suchergebnisse"
        case .network: return "Netzwerk"
        case .console: return "Konsole"
        case .table: return "Listen-Navigation"
        }
    }
    var label: String { title }
    var isTextEditing: Bool { self == .textEditing }
    /// Main-window actions are suspended while another feature window or a sheet is active.
    func overlaps(_ other: CommandScope) -> Bool {
        if self == other { return true }
        if self == .textEditing || other == .textEditing { return true }
        if self == .table || other == .table { return self != .dialog && other != .dialog && self != .console && other != .console }
        if self == .remote || other == .remote {
            let primary: Set<CommandScope> = [.application, .panel, .favorites]
            return primary.contains(self) || primary.contains(other)
        }
        let primary: Set<CommandScope> = [.application, .panel, .network, .console, .favorites]
        return primary.contains(self) && primary.contains(other)
            && (self == .application || other == .application || self == .favorites || other == .favorites)
    }
}

/// One action definition is consumed by menus, the dock and keyboard preferences.
final class AppCommand {
    let id: String
    let title: String
    let menu: CommandMenu
    let order: Int
    let group: Int
    let submenu: String?
    let scope: CommandScope
    let visibleInMenu: Bool
    let defaultBinding: AppKeyBinding?
    let dockTitle: (() -> String)?
    let enabled: () -> Bool
    let checked: () -> Bool
    private let run: () -> Void
    var toolTip: String?
    var customizable: Bool { true }
    var categoryTitle: String {
        let path = [menu.title, submenu].compactMap { $0 }.joined(separator: " › ")
        if scope == .panel { return scope.title + " › " + path }
        return scope == .application || scope == .textEditing ? path : scope.title
    }
    var qualifiedTitle: String { categoryTitle + " › " + title }

    init(
        id: String, title: String, menu: CommandMenu, order: Int, group: Int, submenu: String?,
        key: String, modifiers: NSEvent.ModifierFlags, function: Int?, dockTitle: (() -> String)?,
        scope: CommandScope, visibleInMenu: Bool, binding: AppKeyBinding?,
        enabled: @escaping () -> Bool, checked: @escaping () -> Bool, run: @escaping () -> Void
    ) {
        self.id = id; self.title = title; self.menu = menu; self.order = order
        self.group = group; self.submenu = submenu; self.scope = scope; self.visibleInMenu = visibleInMenu
        defaultBinding = binding ?? function.map(AppKeyBinding.function)
            ?? (key.isEmpty ? nil : AppKeyBinding.character(key, modifiers: modifiers))
        self.dockTitle = dockTitle; self.enabled = enabled; self.checked = checked; self.run = run
    }
    @discardableResult func perform() -> Bool {
        guard enabled() else { return false }
        run()
        return true
    }
}

enum KeyBindingError: LocalizedError {
    case unknownCommand(String)
    case conflict(String)
    var errorDescription: String? {
        switch self {
        case .unknownCommand(let id): return "Unbekannte Aktion: \(id)"
        case .conflict(let title): return "Diese Tastenkombination ist bereits mit „\(title)“ belegt. Entferne zuerst die bestehende Belegung."
        }
    }
}

final class CommandRegistry {
    private(set) var commands: [AppCommand] = []
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult func add(
        _ menu: CommandMenu, _ title: String, id: String, order: Int, group: Int = 0,
        submenu: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
        function: Int? = nil, dockTitle: (() -> String)? = nil,
        scope: CommandScope = .application, visibleInMenu: Bool = true, binding: AppKeyBinding? = nil,
        enabled: @escaping () -> Bool, checked: @escaping () -> Bool = { false }, run: @escaping () -> Void
    ) -> AppCommand {
        precondition(!commands.contains { $0.id == id }, "Duplicate command ID: \(id)")
        let command = AppCommand(
            id: id, title: title, menu: menu, order: order, group: group, submenu: submenu,
            key: key, modifiers: modifiers, function: function, dockTitle: dockTitle,
            scope: scope, visibleInMenu: visibleInMenu, binding: binding,
            enabled: enabled, checked: checked, run: run)
        commands.append(command)
        return command
    }
    /// A second placement/shortcut shares the action's policy and implementation.
    @discardableResult func alias(
        _ sourceID: String, in menu: CommandMenu, title: String, id: String,
        order: Int, group: Int, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
        scope: CommandScope? = nil, visibleInMenu: Bool = true, binding: AppKeyBinding? = nil
    ) -> AppCommand {
        guard let source = self[sourceID] else { preconditionFailure("Unknown command: \(sourceID)") }
        return add(menu, title, id: id, order: order, group: group, key: key, modifiers: modifiers,
                   scope: scope ?? source.scope, visibleInMenu: visibleInMenu, binding: binding,
                   enabled: source.enabled, checked: source.checked) { source.perform() }
    }
    var defaultsByID: [String: AppKeyBinding] {
        Dictionary(uniqueKeysWithValues: commands.compactMap { command in command.defaultBinding.map { (command.id, $0) } })
    }
    private var overrides: [String: AppKeyBinding] {
        guard let data = defaults.data(forKey: "keyBindings"),
              let saved = try? JSONDecoder().decode([String: AppKeyBinding].self, from: data) else { return [:] }
        return saved
    }
    var bindings: [String: AppKeyBinding] {
        defaultsByID.merging(overrides) { _, saved in saved }.filter { self[$0.key] != nil && $0.value.isAssigned }
    }
    var customizableCommands: [AppCommand] {
        commands.sorted {
            let left = $0.categoryTitle + "\t" + $0.title + "\t" + $0.id
            let right = $1.categoryTitle + "\t" + $1.title + "\t" + $1.id
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }
    var dockCommands: [AppCommand] { commands.filter { $0.dockTitle != nil }.sorted { $0.order < $1.order } }
    subscript(id: String) -> AppCommand? { commands.first { $0.id == id } }
    func commands(in menu: CommandMenu) -> [AppCommand] {
        commands.filter { $0.menu == menu && $0.visibleInMenu }
            .sorted { $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group }
    }
    func matching(_ event: NSEvent, scope: CommandScope = .application) -> AppCommand? {
        let saved = bindings
        return commands.first { $0.scope == scope && saved[$0.id]?.matches(event) == true }
    }
    func conflicts(for binding: AppKeyBinding, assigningTo id: String) -> AppCommand? {
        guard let command = self[id] else { return nil }
        let saved = bindings
        return commands.first { other in
            guard other.id != id, let assigned = saved[other.id], assigned.conflicts(with: binding) else { return false }
            // Archive undo/removal only run with the list focused; native text editing owns text fields.
            let listOnly: Set<String> = ["connections.undo", "connections.remove"]
            if (command.scope == .textEditing && listOnly.contains(other.id))
                || (other.scope == .textEditing && listOnly.contains(command.id)) { return false }
            var overlap = command.scope.overlaps(other.scope)
            if command.id.hasPrefix("app.") || other.id.hasPrefix("app.") { overlap = true }
            let dialog = command.scope == .dialog ? command : other.scope == .dialog ? other : nil
            let context = command.scope == .dialog ? other.scope : command.scope
            if let dialog, dialog.id.hasPrefix("dialog.cancel"),
               ![CommandScope.application, .panel, .console].contains(context) { overlap = true }
            // F10 disconnects an active remote pane; outside it, F10 retains the main Exit action.
            if Set([command.id, other.id]) == Set(["remote.close", "exit"]),
               command.defaultBinding?.conflicts(with: binding) == true,
               other.defaultBinding?.conflicts(with: assigned) == true { return false }
            // F10 closes an idle remote browser and cancels its current task, sharing dialog cancellation.
            let remoteCancelPair: Set<String> = ["remote.close", "dialog.cancel.function"]
            if Set([command.id, other.id]) == remoteCancelPair,
               command.defaultBinding?.conflicts(with: binding) == true,
               other.defaultBinding?.conflicts(with: assigned) == true { return false }
            return overlap
        }
    }
    func setBinding(_ binding: AppKeyBinding?, for id: String) throws {
        guard self[id] != nil else { throw KeyBindingError.unknownCommand(id) }
        if let binding, let duplicate = conflicts(for: binding, assigningTo: id) {
            throw KeyBindingError.conflict(duplicate.qualifiedTitle)
        }
        var saved = overrides
        saved[id] = binding ?? .unassigned
        defaults.set(try JSONEncoder().encode(saved), forKey: "keyBindings")
    }
    func resetBinding(for id: String) {
        var saved = overrides
        saved.removeValue(forKey: id)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: "keyBindings") }
    }
    func resetBindings() { defaults.removeObject(forKey: "keyBindings") }
    func addContextDefinitions() {
        for definition in ContextCommands.definitions {
            add(.command, definition.title, id: definition.id, order: commands.count,
                scope: definition.scope, visibleInMenu: false, binding: definition.defaultBinding,
                enabled: { false }) {}
        }
    }
}
