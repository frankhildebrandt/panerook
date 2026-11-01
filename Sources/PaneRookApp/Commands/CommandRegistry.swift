import AppKit

func functionKey(_ key: Int) -> String { String(UnicodeScalar(key)!) }

enum CommandMenu: String { case left, file, command, options, right, help }

/// One action definition is consumed by menus, the dock and keyboard preferences.
final class AppCommand {
    let id: String
    let title: String
    let menu: CommandMenu
    let order: Int
    let group: Int
    let submenu: String?
    let defaultBinding: AppKeyBinding?
    let customizable: Bool
    let dockTitle: (() -> String)?
    let enabled: () -> Bool
    let checked: () -> Bool
    private let run: () -> Void
    var toolTip: String?

    init(
        id: String, title: String, menu: CommandMenu, order: Int, group: Int, submenu: String?,
        key: String, modifiers: NSEvent.ModifierFlags, function: Int?, dockTitle: (() -> String)?,
        enabled: @escaping () -> Bool, checked: @escaping () -> Bool, run: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.order = order
        self.group = group
        self.submenu = submenu
        defaultBinding =
            function.map(AppKeyBinding.function)
            ?? (key.isEmpty ? nil : AppKeyBinding(keyCode: 0, modifiers: modifiers.rawValue, characters: key))
        customizable = function != nil
        self.dockTitle = dockTitle
        self.enabled = enabled
        self.checked = checked
        self.run = run
    }
    @discardableResult func perform() -> Bool {
        guard enabled() else { return false }
        run()
        return true
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
        enabled: @escaping () -> Bool, checked: @escaping () -> Bool = { false }, run: @escaping () -> Void
    ) -> AppCommand {
        precondition(!commands.contains { $0.id == id }, "Duplicate command ID: \(id)")
        let command = AppCommand(
            id: id, title: title, menu: menu, order: order, group: group, submenu: submenu,
            key: key, modifiers: modifiers, function: function, dockTitle: dockTitle,
            enabled: enabled, checked: checked, run: run)
        commands.append(command)
        return command
    }
    /// A second menu placement reuses the action's policy and implementation.
    @discardableResult func alias(
        _ sourceID: String, in menu: CommandMenu, title: String, id: String,
        order: Int, group: Int, key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> AppCommand {
        guard let source = self[sourceID] else { preconditionFailure("Unknown command: \(sourceID)") }
        return add(
            menu, title, id: id, order: order, group: group, key: key, modifiers: modifiers,
            enabled: source.enabled, checked: source.checked
        ) { source.perform() }
    }
    var defaultsByID: [String: AppKeyBinding] {
        Dictionary(
            uniqueKeysWithValues: commands.compactMap { command in command.defaultBinding.map { (command.id, $0) } })
    }
    var bindings: [String: AppKeyBinding] {
        guard let data = defaults.data(forKey: "keyBindings"),
            let saved = try? JSONDecoder().decode([String: AppKeyBinding].self, from: data)
        else { return defaultsByID }
        return defaultsByID.merging(saved) { _, saved in saved }
    }
    var customizableCommands: [AppCommand] {
        commands.filter(\.customizable).sorted {
            ($0.defaultBinding?.characters ?? "") < ($1.defaultBinding?.characters ?? "")
        }
    }
    var dockCommands: [AppCommand] { commands.filter { $0.dockTitle != nil }.sorted { $0.order < $1.order } }
    subscript(id: String) -> AppCommand? { commands.first { $0.id == id } }
    func commands(in menu: CommandMenu) -> [AppCommand] {
        commands.filter { $0.menu == menu }.sorted { $0.group == $1.group ? $0.order < $1.order : $0.group < $1.group }
    }
    /// Only customizable function actions use the file-table handler. Native shortcuts
    /// continue through AppKit's responder chain, preserving text editing.
    func matching(_ event: NSEvent) -> AppCommand? {
        let saved = bindings
        return commands.first { $0.customizable && saved[$0.id]?.matches(event) == true }
    }
}
