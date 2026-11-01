import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var commander: CommanderController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        commander = CommanderController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PaneRook"
        window.minSize = NSSize(width: 850, height: 460)
        window.contentViewController = commander
        if !window.setFrameUsingName("PaneRook.MainWindow") { window.center() }
        window.setFrameAutosaveName("PaneRook.MainWindow")
        makeMenu()
        window.makeKeyAndOrderFront(nil)
        commander.activate(commander.left)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let child = NSMenu(title: title)
            item.submenu = child
            main.addItem(item)
            return child
        }
        func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        let app = menu("PaneRook")
        add(app, "Über PaneRook", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "PaneRook ausblenden", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        app.addItem(.separator())
        add(app, "PaneRook beenden", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("Datei")
        add(file, "Öffnen", #selector(CommanderController.openSelection), "o", target: commander)
        add(file, "Vorschau", #selector(CommanderController.previewSelection), "y", target: commander)
        add(file, "In TextEdit öffnen", #selector(CommanderController.editSelection), String(UnicodeScalar(NSF4FunctionKey)!), [], target: commander)
        file.addItem(.separator())
        add(file, "Kopieren …", #selector(CommanderController.copySelection), String(UnicodeScalar(NSF5FunctionKey)!), [], target: commander)
        add(file, "Verschieben / Umbenennen …", #selector(CommanderController.moveSelection), String(UnicodeScalar(NSF6FunctionKey)!), [], target: commander)
        add(file, "Neuer Ordner …", #selector(CommanderController.makeDirectory), "n", [.command, .shift], target: commander)
        add(file, "In den Papierkorb …", #selector(CommanderController.trashSelection), "\u{8}", target: commander)
        let edit = menu("Bearbeiten")
        add(edit, "Widerrufen", Selector(("undo:")), "z")
        add(edit, "Ausschneiden", #selector(NSText.cut(_:)), "x")
        add(edit, "Kopieren", #selector(NSText.copy(_:)), "c")
        add(edit, "Einsetzen", #selector(NSText.paste(_:)), "v")
        add(edit, "Alles auswählen", #selector(NSText.selectAll(_:)), "a")
        let view = menu("Ansicht")
        add(view, "Panels tauschen", #selector(CommanderController.swapPanels), "u", target: commander)
        add(view, "Versteckte Dateien umschalten", #selector(CommanderController.toggleHidden), ".", [.command, .shift], target: commander)
        add(view, "Aktualisieren", #selector(CommanderController.refresh), "r", target: commander)
        let go = menu("Gehe zu")
        add(go, "Pfad eingeben", #selector(CommanderController.focusPath), "l", target: commander)
        add(go, "Übergeordneter Ordner", #selector(CommanderController.goUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command], target: commander)
        add(go, "Benutzerordner", #selector(CommanderController.goHome), "h", [.command, .shift], target: commander)
        add(go, "Im Finder zeigen", #selector(CommanderController.revealInFinder), "r", [.command, .shift], target: commander)
        let help = menu("Hilfe")
        add(help, "Bedienung & Tastenkürzel", #selector(CommanderController.showHelp), "?", target: commander)
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}
