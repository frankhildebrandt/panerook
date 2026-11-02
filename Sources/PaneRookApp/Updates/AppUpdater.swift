import AppKit
import Sparkle

/// Owns Sparkle for the application's lifetime. Development executables without
/// a release signing key must never try to replace themselves with a release.
final class AppUpdater: NSObject, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private let presentationWindow: () -> NSWindow?
    private(set) var unavailableReason: String?

    init(bundle: Bundle = .main, presentationWindow: @escaping () -> NSWindow?) {
        self.presentationWindow = presentationWindow
        super.init()
        guard Self.isConfigured(bundleURL: bundle.bundleURL, info: bundle.infoDictionary ?? [:]) else {
            unavailableReason = "Updates sind nur in einer mit Update-Schlüssel konfigurierten PaneRook.app verfügbar."
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    static func isConfigured(bundleURL: URL, info: [String: Any]) -> Bool {
        guard bundleURL.pathExtension == "app",
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32,
              let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let version = info["CFBundleVersion"] as? String, !version.isEmpty else { return false }
        return true
    }

    func start() {
        guard let controller else { return }
        do {
            try controller.updater.start()
        } catch {
            unavailableReason = "Die Update-Funktion konnte nicht gestartet werden: \(error.localizedDescription)"
            self.controller = nil
            NSLog("%@", unavailableReason!)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        guard let updater = controller?.updater, let window = presentationWindow(), window.attachedSheet == nil else { return }
        let checks = NSButton(checkboxWithTitle: "Automatisch nach Updates suchen", target: self, action: #selector(checksChanged(_:)))
        checks.state = updater.automaticallyChecksForUpdates ? .on : .off
        let downloads = NSButton(checkboxWithTitle: "Updates automatisch laden und beim Beenden installieren", target: nil, action: nil)
        downloads.state = updater.automaticallyDownloadsUpdates ? .on : .off
        downloads.isEnabled = checks.state == .on
        let content = NSStackView(views: [checks, downloads])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.frame = NSRect(x: 0, y: 0, width: 500, height: 64)
        let alert = NSAlert()
        alert.messageText = "Update-Einstellungen"
        alert.informativeText = "PaneRook prüft täglich GitHub Releases auf neue Versionen. Downloads werden vor dem Entpacken auf ihre Signatur geprüft."
        if let lastCheck = updater.lastUpdateCheckDate {
            alert.informativeText += "\nLetzte Prüfung: " + DateFormatter.localizedString(from: lastCheck, dateStyle: .medium, timeStyle: .short)
        }
        alert.accessoryView = content
        alert.addButton(withTitle: "Übernehmen")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            // Sparkle persists these settings itself. Set them only in response
            // to a user's choice, so launch never overwrites their preferences.
            Self.applySettings(to: updater, checks: checks.state == .on, downloads: downloads.state == .on)
        }
    }

    static func applySettings(to updater: SPUUpdater, checks: Bool, downloads: Bool) {
        // Sparkle ignores the download preference while automatic checks are
        // disabled. Enable checks first; preserve the download choice when off.
        updater.automaticallyChecksForUpdates = checks
        if checks { updater.automaticallyDownloadsUpdates = downloads }
    }

    @objc private func checksChanged(_ sender: NSButton) {
        guard let content = sender.superview as? NSStackView,
              let downloads = content.views.last as? NSButton else { return }
        downloads.isEnabled = sender.state == .on
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return controller?.updater.canCheckForUpdates ?? false
        }
        if menuItem.action == #selector(showSettings(_:)) {
            guard controller != nil, let window = presentationWindow() else { return false }
            return window.attachedSheet == nil
        }
        return false
    }
}
