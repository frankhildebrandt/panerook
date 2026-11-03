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
        commander.appUpdater = updater
        super.init()
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func install() {
        let main = NSMenu()
        let app = makeMenu("PaneRook")
        native(app, "app.about", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        if let updater {
            native(app, "app.updates", #selector(AppUpdater.checkForUpdates(_:)), target: updater)
            app.items.last?.toolTip = updater.unavailableReason
        }
        app.addItem(.separator())
        native(app, "preferences.configuration", #selector(performCommand(_:)), target: self)
        app.addItem(.separator())
        native(app, "app.hide", #selector(NSApplication.hide(_:)), target: NSApp)
        app.addItem(.separator())
        native(app, "app.quit", #selector(NSApplication.terminate(_:)), target: NSApp)
        attach(app, to: main)
        for menu in makeCommanderMenus() { attach(menu, to: main) }

        // Target nil preserves native text editing and validation via the responder chain.
        let edit = makeMenu("Bearbeiten")
        native(edit, "editing.undo", Selector(("undo:")))
        native(edit, "editing.redo", Selector(("redo:")))
        native(edit, "editing.cut", #selector(NSText.cut(_:)))
        native(edit, "editing.copy", #selector(NSText.copy(_:)))
        native(edit, "editing.paste", #selector(NSText.paste(_:)))
        native(edit, "editing.selectAll", #selector(NSText.selectAll(_:)))
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
            guard let self, !KeyboardCaptureState.isRecording else { return event }
            if self.popupIsTracking || !self.trackingMenus.isEmpty {
                if ContextCommands.isCancellation(event) {
                    for menu in self.allMenus { menu.cancelTrackingWithoutAnimation() }
                    return nil
                }
                return event
            }
            if self.commander.commandPalette.isPresented {
                return self.commander.commandPalette.handleKey(event) ? nil : event
            }
            if self.handleTextEditingKey(event) { return nil }
            return self.commander.handleGlobalKey(event) ? nil : event
        }
    }

    /// Physical remappings also work in field editors and auxiliary windows.
    private func handleTextEditingKey(_ event: NSEvent) -> Bool {
        if event.window === commander.view.window, commander.active.hasTerminalKeyboardFocus,
           !event.modifierFlags.contains(.command) { return false }
        guard let window = event.window, window.isKeyWindow,
              let command = commander.commandRegistry.matching(event, scope: .textEditing),
              let binding = commander.commandRegistry.bindings[command.id] else { return false }
        if binding.isTextInput {
            guard let text = window.firstResponder as? NSTextView, text.isEditable || text.isSelectable else { return false }
        }
        return command.perform()
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
    private func native(_ menu: NSMenu, _ id: String, _ action: Selector, target: AnyObject? = nil) {
        guard let command = commander.commandRegistry[id] else { return }
        let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
        item.identifier = .init(id)
        item.representedObject = command
        item.target = target
        updateKey(item)
        menu.addItem(item)
    }
    private func commandMenu(_ location: CommandMenu, title: String) -> NSMenu {
        let menu = makeMenu(title)
        var submenus: [String: NSMenu] = [:]
        var previousGroup: Int?
        for command in commander.commandRegistry.commands(in: location) where command.visibleInMenu {
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
        guard let id = item.identifier?.rawValue, let command = commander.commandRegistry[id] else { return }
        // Always clear the old equivalent when a mapping is removed or becomes table-only.
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
        guard command.scope != .panel, let binding = commander.commandRegistry.bindings[id],
              !binding.isTextInput else { return }
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: binding.modifiers)
    }
    @objc private func performCommand(_ sender: NSMenuItem) {
        commander.commandPalette.dismiss()
        guard let command = sender.representedObject as? AppCommand, command.enabled() else { return }
        command.perform()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.representedObject as? AppCommand else { return false }
        updateKey(menuItem)
        menuItem.title = command.menuTitle?() ?? command.title
        menuItem.state = command.checked() ? .on : .off
        return command.enabled()
    }
    func menuWillOpen(_ menu: NSMenu) { trackingMenus.insert(ObjectIdentifier(menu)) }
    func menuDidClose(_ menu: NSMenu) { trackingMenus.remove(ObjectIdentifier(menu)) }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.target === self && item.representedObject is AppCommand { item.isEnabled = validateMenuItem(item) }
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
