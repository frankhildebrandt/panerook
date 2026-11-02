import AppKit
import PaneRookPanels

final class PreferencesTools {
    unowned let owner: any PreferencesHost
    private let defaults: UserDefaults
    init(owner: any PreferencesHost, defaults: UserDefaults = .standard) {
        self.owner = owner
        self.defaults = defaults
    }
    private func bool(_ key: String, fallback: Bool = true) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private var settingsDialog: SettingsDialog?
    var makeUpdateSettingsView: (() -> NSView)?
    static let encodings: [(String, String.Encoding)] = [
        ("Unicode (UTF-8)", .utf8), ("Unicode (UTF-16)", .utf16),
        ("Westeuropäisch (ISO Latin 1)", .isoLatin1), ("Westeuropäisch (Windows)", .windowsCP1252),
        ("Mac OS Roman", .macOSRoman)
    ]

    func showSettings(section: SettingsSection = .general) {
        if let settingsDialog {
            settingsDialog.show(section)
            settingsDialog.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let pane = owner.activePane
        let dialog = SettingsDialog(preferences: self, section: section, defaults: defaults, updaterView: { [weak self] in
            self?.makeUpdateSettingsView?() ?? NSTextField(wrappingLabelWithString: "Die Update-Funktion ist in diesem Startmodus nicht verfügbar.")
        }) { [weak self, weak pane] in
            guard let self else { return }
            self.settingsDialog = nil
            if let pane { self.owner.activate(pane) }
        }
        settingsDialog = dialog
        dialog.begin(on: window)
    }
    func encoding(pane: (any PanelAccess)? = nil) {
        showSettings(section: .encoding)
    }
    func filter(pane: any PanelAccess) {
        ToolUI.prompt(owner: owner, title: "Filter", label: "Dateimaske · leer zeigt alle Dateien", value: pane.filterPattern, accept: "Anwenden") { value in pane.setFilter(value) }
    }
    /// Color changes must not reload file cells/icons or reread highlight rules.
    func applyAppearance() {
        ThemeManager.apply(defaults: defaults)
    }
    func apply() {
        applyAppearance()
        let heights: [CGFloat] = [23, 29, 35]
        let index = defaults.object(forKey: "rowDensity") as? Int ?? 1
        for pane in [owner.leftPane, owner.rightPane] {
            pane.applyDisplayOptions(rowHeight: heights[max(0, min(2, index))], showIcons: bool("showIcons"), showSummary: bool("showSummary"))
        }
        owner.applyLayout(vertical: bool("verticalPanels"), functionBar: bool("showFunctionBar"), toolbar: bool("showToolbar"))
        owner.refreshHighlights()
        owner.hotkeysChanged()
    }
    func savePanels() {
        for (key, pane) in [("left", owner.leftPane), ("right", owner.rightPane)] {
            defaults.set(pane.sortKey, forKey: key + "Sort")
            defaults.set(pane.sortAscending, forKey: key + "Ascending")
            defaults.set(pane.isBriefListing, forKey: key + "Brief")
            defaults.set(pane.filterPattern, forKey: key + "Filter")
            defaults.set(pane.gitFilter.rawValue, forKey: key + "GitFilter")
            defaults.set(Int(pane.textEncoding.rawValue), forKey: key + "Encoding")
        }
    }
    func restorePanels() {
        guard bool("restorePanels") else { return }
        for (key, pane) in [("left", owner.leftPane), ("right", owner.rightPane)] {
            pane.setSort(key: defaults.string(forKey: key + "Sort") ?? "name", ascending: bool(key + "Ascending"))
            pane.setBriefListing(defaults.bool(forKey: key + "Brief"))
            pane.setFilter(defaults.string(forKey: key + "Filter") ?? "")
            pane.setGitFilter(GitFileFilter(rawValue: defaults.string(forKey: key + "GitFilter") ?? "") ?? .all)
            if let raw = defaults.object(forKey: key + "Encoding") as? UInt { pane.textEncoding = String.Encoding(rawValue: raw) }
        }
    }
}

protocol PreferencesHost: PanelPresenting, PanelPairProviding, ErrorPresenting {
    func applyLayout(vertical: Bool, functionBar: Bool, toolbar: Bool)
    func hotkeysChanged()
    func refreshHighlights()
    func setHiddenFilesVisible(_ visible: Bool)
    func remoteSettingsChanged()
    var commandRegistry: CommandRegistry { get }
}
