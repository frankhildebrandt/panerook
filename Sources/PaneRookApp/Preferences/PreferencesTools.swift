import AppKit

private final class KeyCapture: NSTextField {
    var binding: AppKeyBinding?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func keyDown(with event: NSEvent) { capture(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 { return false }
        capture(event); return true
    }
    private func capture(_ event: NSEvent) {
        guard event.keyCode != 53, event.keyCode != 36, event.keyCode != 76 else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !(event.keyCode == 5 && flags == .control), !(event.charactersIgnoringModifiers ?? "").isEmpty else { return }
        binding = AppKeyBinding(keyCode: event.keyCode, modifiers: flags.rawValue, characters: event.charactersIgnoringModifiers ?? "")
        stringValue = binding!.label
    }
}

final class PreferencesTools {
    unowned let owner: any PreferencesHost
    private let defaults = UserDefaults.standard
    init(owner: any PreferencesHost) { self.owner = owner }
    private func bool(_ key: String, fallback: Bool = true) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private func check(_ title: String, key: String, fallback: Bool = true) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = bool(key, fallback: fallback) ? .on : .off
        return box
    }
    private func sheet(_ title: String, rows: [(String, NSView)], save: @escaping () -> Void) {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let alert = NSAlert(); alert.messageText = title
        alert.accessoryView = ToolUI.form(rows)
        alert.addButton(withTitle: "Übernehmen"); alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        let pane = owner.activePane
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { save(); self.apply() }
            self.owner.activate(pane)
        }
    }
    func configuration() {
        let history = check("Befehlschronik speichern", key: "rememberCommands")
        let restore = check("Panelzustand beim Start wiederherstellen", key: "restorePanels")
        sheet("Konfiguration", rows: [("", history), ("", restore)]) {
            self.defaults.set(history.state == .on, forKey: "rememberCommands")
            self.defaults.set(restore.state == .on, forKey: "restorePanels")
            if history.state == .off { self.defaults.removeObject(forKey: "commandHistory") }
        }
    }
    func layout() {
        let vertical = check("Panels nebeneinander", key: "verticalPanels")
        let bar = check("Funktionstastenleiste anzeigen", key: "showFunctionBar")
        let toolbar = check("Symbolleiste anzeigen", key: "showToolbar")
        sheet("Layout", rows: [("", vertical), ("", bar), ("", toolbar)]) {
            self.defaults.set(vertical.state == .on, forKey: "verticalPanels")
            self.defaults.set(bar.state == .on, forKey: "showFunctionBar")
            self.defaults.set(toolbar.state == .on, forKey: "showToolbar")
        }
    }
    func panelOptions() {
        let icons = check("Dateisymbole anzeigen", key: "showIcons")
        let summary = check("Auswahlstatus anzeigen", key: "showSummary")
        let density = NSPopUpButton()
        density.addItems(withTitles: ["Kompakt", "Standard", "Groß"])
        density.selectItem(at: defaults.object(forKey: "rowDensity") as? Int ?? 1)
        sheet("Paneloptionen", rows: [("Zeilenhöhe", density), ("", icons), ("", summary)]) {
            self.defaults.set(icons.state == .on, forKey: "showIcons")
            self.defaults.set(summary.state == .on, forKey: "showSummary")
            self.defaults.set(density.indexOfSelectedItem, forKey: "rowDensity")
        }
    }
    func confirmations() {
        let trash = check("Vor dem Papierkorb nachfragen", key: "confirmTrash")
        sheet("Nachfragen", rows: [("", trash)]) { self.defaults.set(trash.state == .on, forKey: "confirmTrash") }
    }
    func appearance() {
        let appearance = NSPopUpButton()
        appearance.addItems(withTitles: ["System", "Hell", "Dunkel"])
        appearance.selectItem(at: defaults.integer(forKey: "appearance"))
        sheet("Aussehen", rows: [("Darstellung", appearance)]) { self.defaults.set(appearance.indexOfSelectedItem, forKey: "appearance") }
    }
    func encoding(pane: (any PanelAccess)? = nil) {
        let pane = pane ?? owner.activePane
        let encodings: [(String, String.Encoding)] = [("Unicode (UTF-8)", .utf8), ("Unicode (UTF-16)", .utf16),
            ("Westeuropäisch (ISO Latin 1)", .isoLatin1), ("Westeuropäisch (Windows)", .windowsCP1252), ("Mac OS Roman", .macOSRoman)]
        let popup = NSPopUpButton()
        popup.addItems(withTitles: encodings.map(\.0))
        popup.selectItem(at: encodings.firstIndex { $0.1 == pane.textEncoding } ?? 0)
        sheet("Codierung", rows: [("Textvorschau und Inhaltsansicht", popup)]) { pane.textEncoding = encodings[popup.indexOfSelectedItem].1 }
    }
    func learnKeys() {
        let actions = owner.commandRegistry.customizableCommands.map { ($0.id, $0.title) }
        ToolUI.choose(owner: owner, title: "Tasten lernen", labels: actions.map { $0.1 + " · " + (owner.commandRegistry.bindings[$0.0]?.label ?? "") }, accept: "Belegen …", extra: "Zurücksetzen") { [weak self] index, reset in
            guard let self else { return }
            if reset { self.defaults.removeObject(forKey: "keyBindings"); self.owner.hotkeysChanged(); return }
            guard actions.indices.contains(index), let window = self.owner.presentationWindow else { return }
            let action = actions[index]
            let capture = KeyCapture(frame: NSRect(x: 0, y: 0, width: 440, height: 30))
            capture.placeholderString = "Tastenkombination drücken"
            capture.isEditable = false
            AppStyle.configureField(capture)
            let alert = NSAlert(); alert.messageText = action.1
            alert.accessoryView = capture
            alert.addButton(withTitle: "Speichern"); alert.addButton(withTitle: "Abbrechen")
            alert.configureKeyboardShortcuts(); alert.window.initialFirstResponder = capture
            alert.beginSheetModal(for: window) { [weak self] result in
                guard let self else { return }
                self.owner.activate(self.owner.activePane)
                guard result == .alertFirstButtonReturn, let binding = capture.binding else { return }
                var bindings = self.owner.commandRegistry.bindings
                if let duplicate = bindings.first(where: { $0.key != action.0 && $0.value.keyCode == binding.keyCode && $0.value.modifiers == binding.modifiers }) {
                    self.owner.showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Diese Taste ist bereits mit \(actions.first { $0.0 == duplicate.key }?.1 ?? duplicate.key) belegt."]))
                    return
                }
                bindings[action.0] = binding
                if let data = try? JSONEncoder().encode(bindings) { self.defaults.set(data, forKey: "keyBindings") }
                self.owner.hotkeysChanged()
            }
        }
    }
    func filter(pane: any PanelAccess) {
        ToolUI.prompt(owner: owner, title: "Filter", label: "Dateimaske · leer zeigt alle Dateien", value: pane.filterPattern, accept: "Anwenden") { value in pane.setFilter(value) }
    }
    func apply() {
        switch defaults.integer(forKey: "appearance") {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
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
            defaults.set(Int(pane.textEncoding.rawValue), forKey: key + "Encoding")
        }
    }
    func restorePanels() {
        guard bool("restorePanels") else { return }
        for (key, pane) in [("left", owner.leftPane), ("right", owner.rightPane)] {
            pane.setSort(key: defaults.string(forKey: key + "Sort") ?? "name", ascending: bool(key + "Ascending"))
            pane.setBriefListing(defaults.bool(forKey: key + "Brief"))
            pane.setFilter(defaults.string(forKey: key + "Filter") ?? "")
            if let raw = defaults.object(forKey: key + "Encoding") as? UInt { pane.textEncoding = String.Encoding(rawValue: raw) }
        }
    }
}

protocol PreferencesHost: PanelPresenting, PanelPairProviding, ErrorPresenting {
    func applyLayout(vertical: Bool, functionBar: Bool, toolbar: Bool)
    func hotkeysChanged()
    func refreshHighlights()
    var commandRegistry: CommandRegistry { get }
}
