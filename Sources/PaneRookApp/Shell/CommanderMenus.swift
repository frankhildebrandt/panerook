import PaneRookPanels
import AppKit

/// MC 4.8.33's menu order, backed by native AppKit menus and real app capabilities.
final class CommanderMenus: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let commander: CommanderController
    private let updater: AppUpdater?
    private var allMenus: [NSMenu] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var popup: NSMenu!
    private var popupIsTracking = false
    private var keyMonitor: Any?
    init(commander: CommanderController, updater: AppUpdater? = nil) {
        self.commander = commander
        self.updater = updater
        super.init()
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func install() {
        let main = NSMenu()
        let app = NSMenu(title: "PaneRook")
        native(app, "Über PaneRook", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        if let updater {
            native(app, "Nach Updates suchen …", #selector(AppUpdater.checkForUpdates(_:)), target: updater)
            native(app, "Update-Einstellungen …", #selector(AppUpdater.showSettings(_:)), target: updater)
            for item in app.items.suffix(2) { item.toolTip = updater.unavailableReason }
        }
        app.addItem(.separator())
        native(app, "PaneRook ausblenden", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        app.addItem(.separator())
        native(app, "PaneRook beenden", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        attach(app, to: main)
        for menu in makeCommanderMenus() { attach(menu, to: main) }

        // Preserve macOS text editing and its responder-chain shortcuts.
        let edit = NSMenu(title: "Bearbeiten")
        native(edit, "Widerrufen", Selector(("undo:")), key: "z")
        native(edit, "Ausschneiden", #selector(NSText.cut(_:)), key: "x")
        native(edit, "Kopieren", #selector(NSText.copy(_:)), key: "c")
        native(edit, "Einsetzen", #selector(NSText.paste(_:)), key: "v")
        native(edit, "Alles auswählen", #selector(NSText.selectAll(_:)), key: "a")
        attach(edit, to: main)
        let help = commandMenu(.help, title: "Hilfe")
        attach(help, to: main)
        NSApp.mainMenu = main
        NSApp.helpMenu = help

        popup = makeMenu("Menüs")
        // Menus cannot have two parents. Both copies share the same action/state providers.
        for menu in makeCommanderMenus() { attach(menu, to: popup) }
        commander.onShowMenu = { [weak self] in self?.showPopup() }
        commander.menuIsTracking = { [weak self] in
            guard let self else { return false }
            return self.popupIsTracking || !self.trackingMenus.isEmpty
        }
        commander.onKeyBindingsChanged = { [weak self] in
            guard let self else { return }
            for menu in self.allMenus { for item in menu.items { self.updateKey(item) } }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popupIsTracking || !self.trackingMenus.isEmpty else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if ((event.keyCode == 109 || event.keyCode == 53) && modifiers.isEmpty)
                || (event.keyCode == 5 && modifiers == .control) {
                for menu in self.allMenus { menu.cancelTrackingWithoutAnimation() }
                return nil
            }
            return event
        }
    }

    private func makeCommanderMenus() -> [NSMenu] {
        [commandMenu(.left, title: "Links"), commandMenu(.file, title: "Datei"), commandMenu(.command, title: "Befehl"), commandMenu(.options, title: "Optionen"), commandMenu(.right, title: "Rechts")]
    }
    private func makeMenu(_ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        allMenus.append(menu)
        return menu
    }
    private func attach(_ child: NSMenu, to parent: NSMenu) {
        let item = NSMenuItem(title: child.title, action: nil, keyEquivalent: "")
        item.submenu = child
        parent.addItem(item)
    }
    private func native(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        menu.addItem(item)
    }
    private func commandMenu(_ location: CommandMenu, title: String) -> NSMenu {
        let menu = makeMenu(title)
        var submenus: [String: NSMenu] = [:]
        var previousGroup: Int?
        for command in commander.commandRegistry.commands(in: location) {
            if let previousGroup, previousGroup != command.group { menu.addItem(.separator()) }
            previousGroup = command.group
            let target: NSMenu
            if let name = command.submenu {
                if let existing = submenus[name] { target = existing }
                else { target = makeMenu(name); submenus[name] = target; attach(target, to: menu) }
            } else { target = menu }
            let item = NSMenuItem(title: command.title, action: #selector(performCommand(_:)), keyEquivalent: "")
            item.identifier = .init(command.id); item.target = self
            item.representedObject = command; item.toolTip = command.toolTip
            updateKey(item)
            target.addItem(item)
        }
        return menu
    }
    private func updateKey(_ item: NSMenuItem) {
        guard let id = item.identifier?.rawValue, id != "exit", let binding = commander.commandRegistry.bindings[id] else { return }
        item.keyEquivalent = binding.characters
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: binding.modifiers)
    }
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? AppCommand, command.enabled() else { return }
        command.perform()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.representedObject as? AppCommand else { return false }
        updateKey(menuItem)
        menuItem.state = command.checked() ? .on : .off
        return command.enabled()
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenus.insert(ObjectIdentifier(menu)) }
    func menuDidClose(_ menu: NSMenu) { trackingMenus.remove(ObjectIdentifier(menu)) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.representedObject is AppCommand { item.isEnabled = validateMenuItem(item) }
    }

    private func showPopup() {
        guard commander.canUseMenus, let window = commander.view.window else { return }
        let previous = window.firstResponder
        let selected = popup.items[commander.active === commander.left ? 0 : 4]
        popupIsTracking = true
        let choseAction = popup.popUp(positioning: selected, at: NSPoint(x: 12, y: commander.view.bounds.maxY - 8), in: commander.view)
        popupIsTracking = false
        if !choseAction, window.attachedSheet == nil, let previous { window.makeFirstResponder(previous) }
    }
}
