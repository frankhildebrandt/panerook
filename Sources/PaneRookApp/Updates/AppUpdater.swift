import AppKit
import Sparkle

/// Owns Sparkle for the application's lifetime. Development executables without
/// a release signing key must never try to replace themselves with a release.
final class AppUpdater: NSObject, NSMenuItemValidation {
    private var controller: SPUStandardUpdaterController?
    private(set) var unavailableReason: String?

    init(bundle: Bundle = .main, presentationWindow: @escaping () -> NSWindow?) {
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

    func makeSettingsView() -> NSView {
        UpdateSettingsView(updater: controller?.updater, unavailableReason: unavailableReason) { [weak self] in
            self?.checkForUpdates(nil)
        }
    }

    static func applySettings(to updater: SPUUpdater, checks: Bool, downloads: Bool) {
        // Sparkle ignores the download preference while automatic checks are
        // disabled. Enable checks first; preserve the download choice when off.
        updater.automaticallyChecksForUpdates = checks
        if checks { updater.automaticallyDownloadsUpdates = downloads }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) {
            return controller?.updater.canCheckForUpdates ?? false
        }
        return false
    }
}

/// The settings dialog owns this view, including its controls and observations.
/// Sparkle remains the sole owner of the persisted update preferences.
private final class UpdateSettingsView: NSStackView {
    private let updater: SPUUpdater?
    private let checkForUpdates: () -> Void
    private let checks = SettingsToggle()
    private let downloads = SettingsToggle()
    private let lastCheck = NSTextField(labelWithString: "")
    private let manualCheck = NSButton(title: "Jetzt prüfen", target: nil, action: nil)
    private var observations: [NSKeyValueObservation] = []

    init(updater: SPUUpdater?, unavailableReason: String?, checkForUpdates: @escaping () -> Void) {
        self.updater = updater
        self.checkForUpdates = checkForUpdates
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 32

        checks.identifier = .init("updates.automaticChecks")
        checks.setAccessibilityLabel("Automatisch nach Updates suchen")
        checks.controlSize = .small
        checks.target = self
        checks.action = #selector(preferencesChanged(_:))
        downloads.identifier = .init("updates.automaticDownloads")
        downloads.setAccessibilityLabel("Updates automatisch laden und beim Beenden installieren")
        downloads.controlSize = .small
        downloads.target = self
        downloads.action = #selector(preferencesChanged(_:))
        append(SettingsStyle.section("Automatische Updates", rows: [
            SettingsStyle.row("Automatisch nach Updates suchen",
                              detail: "PaneRook prüft täglich auf neue Versionen auf GitHub Releases.", control: checks),
            SettingsStyle.row("Updates automatisch laden",
                              detail: "Signierte Updates laden und beim Beenden der App installieren.", control: downloads)
        ]))

        lastCheck.identifier = .init("updates.lastCheck")
        lastCheck.font = .systemFont(ofSize: 12)
        lastCheck.textColor = SettingsStyle.secondaryTextColor
        if let updater {
            manualCheck.target = self
            manualCheck.action = #selector(checkNow(_:))
            manualCheck.bezelStyle = .rounded
            manualCheck.controlSize = .small
            manualCheck.font = .systemFont(ofSize: 13)
            append(SettingsStyle.section("Manuell prüfen", rows: [
                SettingsStyle.row("Nach Updates suchen",
                                  detail: "Nach einer neuen Version suchen. Downloads werden vor der Installation geprüft.", control: manualCheck)
            ]))
            setCustomSpacing(12, after: arrangedSubviews.last!)
            append(inset(lastCheck))
            observations = [
                updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in self?.refreshOnMainThread() },
                updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in self?.refreshOnMainThread() },
                updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in self?.refreshOnMainThread() },
                updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in self?.refreshOnMainThread() }
            ]
        } else {
            checks.isEnabled = false
            downloads.isEnabled = false
            let reason = NSTextField(wrappingLabelWithString: unavailableReason ?? "Die Update-Funktion ist derzeit nicht verfügbar.")
            reason.identifier = .init("updates.unavailableReason")
            reason.font = .systemFont(ofSize: 12)
            reason.textColor = SettingsStyle.secondaryTextColor
            append(inset(reason))
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func append(_ view: NSView) {
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    private func inset(_ field: NSTextField) -> NSView {
        let container = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    private func refreshOnMainThread() {
        if Thread.isMainThread { refresh() }
        else { DispatchQueue.main.async { [weak self] in self?.refresh() } }
    }

    private func refresh() {
        guard let updater else { return }
        checks.state = updater.automaticallyChecksForUpdates ? .on : .off
        downloads.state = updater.automaticallyDownloadsUpdates ? .on : .off
        downloads.isEnabled = updater.automaticallyChecksForUpdates
        manualCheck.isEnabled = updater.canCheckForUpdates
        lastCheck.stringValue = updater.lastUpdateCheckDate.map {
            "Letzte Prüfung: " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? "Bisher wurde noch nicht nach Updates gesucht."
    }

    @objc private func preferencesChanged(_ sender: SettingsToggle) {
        guard let updater else { return }
        // Observations can fire synchronously while Sparkle writes either value.
        let wantsChecks = checks.state == .on
        let wantsDownloads = downloads.state == .on
        AppUpdater.applySettings(to: updater, checks: wantsChecks, downloads: wantsDownloads)
        refresh()
    }

    @objc private func checkNow(_ sender: Any?) { checkForUpdates() }
}
