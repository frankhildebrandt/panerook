import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var commander: CommanderController!
    private var menus: CommanderMenus!
    private var dialogKeys: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        var iconURL = Bundle.main.url(forResource: "PaneRook", withExtension: "icns")
        #if DEBUG
        // Xcode/SwiftPM can launch the bare executable instead of the app bundle.
        // Use the same checked-in artwork for that development launch as well.
        if iconURL == nil && Bundle.main.bundleURL.pathExtension != "app" {
            iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/PaneRook.icns")
        }
        #endif
        if let iconURL, let icon = NSImage(contentsOf: iconURL), icon.isValid {
            // Set the process/Dock icon before showing a window. This also
            // bypasses a stale generic executable icon from LaunchServices.
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        menus = CommanderMenus(commander: commander)
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
    }
    func applicationWillTerminate(_ notification: Notification) {
        commander.saveSetup()
        commander.workflow.cancelAll()
        commander.localTools.closeAll()
        commander.remote.closeAll()
        if let dialogKeys { NSEvent.removeMonitor(dialogKeys) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

}
