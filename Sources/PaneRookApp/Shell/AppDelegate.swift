import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var commander: CommanderController!
    private var menus: CommanderMenus!
    private var updater: AppUpdater!
    private var dialogKeys: Any?

    public func applicationWillFinishLaunching(_ notification: Notification) {
        var iconURL = Bundle.main.url(forResource: "PaneRook", withExtension: "icns")
        #if DEBUG
        // Xcode/SwiftPM can launch the bare executable instead of the app bundle.
        // Use the same checked-in artwork for that development launch as well.
        if iconURL == nil && Bundle.main.bundleURL.pathExtension != "app" {
            iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/PaneRook.icns")
        }
        #endif
        if let iconURL, let icon = NSImage(contentsOf: iconURL), icon.isValid {
            // Set the process/Dock icon before showing a window. This also
            // bypasses a stale generic executable icon from LaunchServices.
            NSApp.applicationIconImage = icon
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        commander = CommanderController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "PaneRook"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 850, height: 460)
        window.contentViewController = commander
        window.toolbar = commander.makeToolbar()
        if !window.setFrameUsingName("PaneRook.MainWindow") { window.center() }
        window.setFrameAutosaveName("PaneRook.MainWindow")
        updater = AppUpdater(presentationWindow: { [weak self] in self?.window })
        commander.preferences.makeUpdateSettingsView = { [weak self] in
            self?.updater.makeSettingsView() ?? NSView()
        }
        menus = CommanderMenus(commander: commander, updater: updater)
        menus.install()
        dialogKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard (event.keyCode == 109 && flags.isEmpty) || (event.keyCode == 5 && flags == .control),
                  let sheet = NSApp.keyWindow, let parent = sheet.sheetParent else { return event }
            if let transfer = sheet as? TransferPanel { transfer.cancelOperation(nil) }
            else if let tool = sheet as? ToolPanel { tool.cancelOperation(nil) }
            else { parent.endSheet(sheet, returnCode: .cancel) }
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        commander.activate(commander.left)
        NSApp.activate(ignoringOtherApps: true)
        updater.start()
    }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard commander.tasks.hasActiveTasks else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Es laufen noch Aufgaben."
        alert.informativeText = "Beim Beenden werden laufende und wartende Aufgaben abgebrochen. Bereits abgeschlossene Einträge bleiben erhalten."
        alert.addButton(withTitle: "Weiterarbeiten")
        alert.addButton(withTitle: "Aufgaben abbrechen und beenden")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        commander.tasks.cancelAll {
            // Let the worker finish cleanup before ending the process.
            DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        commander.saveSetup()
        commander.tasks.cancelAll()
        commander.workflow.cancelAll()
        commander.localTools.closeAll()
        commander.remote.closeAll()
        ArchivePreviewStore.shared.cleanUp()
        if let dialogKeys { NSEvent.removeMonitor(dialogKeys) }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

}
