import AppKit

/// The categories also provide search terms for settings whose labels are on another page.
enum SettingsSection: String, CaseIterable {
    case general, appearance, layout, panels, confirmations, encoding, keyboard, connections, updates

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .appearance: return "Aussehen"
        case .layout: return "Layout"
        case .panels: return "Panels"
        case .confirmations: return "Nachfragen"
        case .encoding: return "Codierung"
        case .keyboard: return "Tastatur"
        case .connections: return "Verbindungen"
        case .updates: return "Updates"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .appearance: return "paintpalette"
        case .layout: return "rectangle.split.2x1"
        case .panels: return "list.bullet.rectangle"
        case .confirmations: return "checkmark.shield"
        case .encoding: return "textformat.abc"
        case .keyboard: return "keyboard"
        case .connections: return "network"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
    private var keywords: String {
        switch self {
        case .general: return "Konfiguration Befehlschronik speichern Panelzustand Start wiederherstellen"
        case .appearance: return "Darstellung Farbschema System Hell Dunkel Theme Design Farben PaneRook Rose Grove Ocean Ember Iris"
        case .layout: return "Panels nebeneinander untereinander Funktionstastenleiste Symbolleiste"
        case .panels: return "Paneloptionen Zeilenhöhe Kompakt Standard Groß Dateisymbole Icons Auswahlstatus versteckte Dateien"
        case .confirmations: return "Sicherheit Löschen Papierkorb bestätigen Rückfragen"
        case .encoding: return "Darstellungsbits Textvorschau Inhaltsansicht Unicode UTF-8 UTF-16 Westeuropäisch Mac OS Roman Links Rechts"
        case .keyboard: return "Tasten lernen Tastaturbelegung Tastenkombinationen Funktionstasten F1 F2 F3 F4 F5 F6 F7 F8 F9 F10 Aktionen suchen belegen entfernen Konflikte Standard zurücksetzen"
        case .connections: return "Virtuelles Dateisystem VFS Remote Timeout Zeitlimit FTP SFTP SSH Nextcloud"
        case .updates: return "Automatisch Aktualisierung Version Sparkle herunterladen installieren prüfen"
        }
    }
    func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { (title + " " + keywords).localizedStandardContains(String($0)) }
    }
}

/// Changes are persisted immediately, just like native macOS Settings.
final class SettingsDialog: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    private let defaults: UserDefaults
    private let preferences: PreferencesTools
    private let updaterView: () -> NSView
    private let onClose: () -> Void
    private let sidebar = NSStackView()
    private let search = NSSearchField()
    private let breadcrumb = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let pages = NSStackView()
    private var navigation: [SettingsSection: NSButton] = [:]
    private var actions: [ClosureAction] = []
    private var navigationActionCount = 0
    private var themeObserver: NSObjectProtocol?
    private var parentCloseObserver: NSObjectProtocol?
    private var didDismiss = false
    private(set) var selectedSection: SettingsSection

    init(preferences: PreferencesTools, section: SettingsSection, defaults: UserDefaults = .standard,
         updaterView: @escaping () -> NSView, onClose: @escaping () -> Void) {
        self.preferences = preferences
        self.defaults = defaults
        self.selectedSection = section
        self.updaterView = updaterView
        self.onClose = onClose
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self
        panel.title = "Einstellungen"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 860, height: 560)
        panel.onCancel = { [weak self] in self?.dismiss() }
        assemble(in: panel)
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateNavigation()
        }
        navigationActionCount = actions.count
        show(section)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        didDismiss = false
        if let saved = defaults.string(forKey: "settings.windowFrame") {
            let frame = NSRectFromString(saved)
            if frame.width >= window.minSize.width, frame.height >= window.minSize.height {
                window.setFrame(window.constrainFrameRect(frame, to: parent.screen), display: false)
            } else { window.center() }
        } else { window.center() }
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: parent, queue: .main) { [weak self] _ in self?.dismiss() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
    func show(_ section: SettingsSection) {
        commitTimeoutEditing()
        selectedSection = section
        defaults.set(section.rawValue, forKey: "settings.selectedSection")
        window?.title = section.title + " – Einstellungen"
        clear(pages)
        actions.removeSubrange(navigationActionCount..<actions.count)
        let content = makePage(section)
        pages.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: pages.widthAnchor).isActive = true
        let trail = NSMutableAttributedString(string: "Einstellungen   /   ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: SettingsStyle.secondaryTextColor
        ])
        trail.append(NSAttributedString(string: section.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ]))
        breadcrumb.attributedStringValue = trail
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        updateNavigation()
    }
    private func assemble(in panel: NSWindow) {
        let root = SettingsSurfaceView(color: SettingsStyle.canvasColor)
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        if let frameView = root.superview {
            root.widthAnchor.constraint(equalTo: frameView.widthAnchor).isActive = true
        }
        let side = SettingsSurfaceView(color: SettingsStyle.sidebarColor)
        add(side, to: root)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 16, right: 8)
        add(sidebar, to: side)
        search.placeholderString = "Suchen"
        search.font = .systemFont(ofSize: 13)
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Einstellungen suchen")
        sidebar.addArrangedSubview(search)
        search.heightAnchor.constraint(equalToConstant: 28).isActive = true
        search.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
        sidebar.setCustomSpacing(12, after: search)
        for section in SettingsSection.allCases {
            let button = SettingsNavigationButton(title: section.title, symbol: section.symbol)
            bind(button) { [weak self] in self?.show(section) }
            sidebar.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -16).isActive = true
            button.heightAnchor.constraint(equalToConstant: 34).isActive = true
            navigation[section] = button
        }
        let hint = label("Änderungen werden sofort gespeichert.", size: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byWordWrapping
        sidebar.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalTo: search.widthAnchor).isActive = true
        sidebar.setCustomSpacing(24, after: navigation[.updates]!)
        let divider = SettingsDivider()
        add(divider, to: root)
        let header = NSView()
        add(header, to: root)
        breadcrumb.font = .systemFont(ofSize: 13)
        breadcrumb.textColor = .secondaryLabelColor
        add(breadcrumb, to: header)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Einstellungen schließen")!, target: nil, action: nil)
        close.isBordered = false
        ContextCommands.configure(close, id: "dialog.cancel")
        close.toolTip = ContextCommands.binding(for: "dialog.cancel").map { "Einstellungen schließen · " + $0.label } ?? "Einstellungen schließen"
        bind(close) { [weak self] in self?.dismiss() }
        add(close, to: header)
        let rule = SettingsDivider()
        add(rule, to: root)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // Keep the legacy scroller gutter stable when switching between pages.
        // Otherwise AppKit changes the clip width during document layout.
        scroll.autohidesScrollers = false
        add(scroll, to: root)
        // Flipped document coordinates keep short pages at the top and make scrolling predictable.
        let document = SettingsDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        pages.orientation = .vertical
        pages.alignment = .leading
        pages.spacing = 32
        add(pages, to: document)
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            side.topAnchor.constraint(equalTo: root.topAnchor),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 224),
            sidebar.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: side.topAnchor),
            divider.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 48),
            breadcrumb.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            breadcrumb.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28),
            close.heightAnchor.constraint(equalToConstant: 28),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pages.topAnchor.constraint(equalTo: document.topAnchor, constant: 30),
            pages.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            pages.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 32),
            pages.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -32),
            pages.widthAnchor.constraint(lessThanOrEqualToConstant: 848),
            pages.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32)
        ])
        let preferredWidth = pages.widthAnchor.constraint(equalTo: document.widthAnchor, multiplier: 0.82)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
    }
    private func makePage(_ section: SettingsSection) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 32
        func append(_ view: NSView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        switch section {
        case .general:
            append(SettingsStyle.section("Verlauf", rows: [
                toggle("Befehlschronik speichern", detail: "Zuletzt ausgeführte Befehle für die nächste Sitzung behalten.", key: "rememberCommands")
            ]))
            append(SettingsStyle.section("Beim Start", rows: [
                toggle("Panelzustand wiederherstellen", detail: "Ordner, Sortierung und Filter beim nächsten Start wieder öffnen.", key: "restorePanels")
            ]))
        case .appearance:
            append(SettingsAppearanceView(defaults: defaults) { [weak self] in self?.preferences.applyAppearance() })
        case .layout:
            append(SettingsStyle.section("Panels", rows: [
                toggle("Panels nebeneinander", detail: "Ausschalten, um die beiden Panels untereinander anzuordnen.", key: "verticalPanels")
            ]))
            append(SettingsStyle.section("Bedienelemente", rows: [
                toggle("Funktionstastenleiste anzeigen", detail: "Dateiaktionen und ihre Tastenkürzel am unteren Fensterrand.", key: "showFunctionBar"),
                toggle("Symbolleiste anzeigen", detail: "Schneller Zugriff auf Navigation und häufige Aktionen.", key: "showToolbar")
            ]))
        case .panels:
            let density = NSPopUpButton()
            density.addItems(withTitles: ["Kompakt", "Standard", "Groß"])
            density.selectItem(at: max(0, min(2, defaults.object(forKey: "rowDensity") as? Int ?? 1)))
            bind(density) { [weak self, weak density] in
                guard let self, let density else { return }
                self.defaults.set(density.indexOfSelectedItem, forKey: "rowDensity")
                self.preferences.apply()
            }
            append(SettingsStyle.section("Dateiliste", rows: [
                row("Zeilenhöhe", detail: "Gilt für beide Dateipanels.", control: density),
                toggle("Dateisymbole anzeigen", detail: "Datei- und Ordnersymbole neben den Namen einblenden.", key: "showIcons"),
                toggle("Versteckte Dateien anzeigen", detail: "Dateien und Ordner mit einem führenden Punkt in beiden Panels anzeigen.", key: "showHidden", fallback: false)
            ]))
            append(SettingsStyle.section("Status", rows: [
                toggle("Auswahlstatus anzeigen", detail: "Anzahl und Größe der markierten Dateien im Panel anzeigen.", key: "showSummary")
            ]))
        case .confirmations:
            append(SettingsStyle.section("Dateiaktionen", rows: [
                toggle("Vor dem Papierkorb nachfragen", detail: "Vor dem Verschieben ausgewählter Dateien eine Bestätigung anfordern.", key: "confirmTrash")
            ]))
        case .encoding:
            var encodingRows: [NSView] = []
            for (title, pane) in [("Linkes Panel", preferences.owner.leftPane), ("Rechtes Panel", preferences.owner.rightPane)] {
                let popup = NSPopUpButton()
                popup.addItems(withTitles: PreferencesTools.encodings.map(\.0))
                popup.selectItem(at: PreferencesTools.encodings.firstIndex { $0.1 == pane.textEncoding } ?? 0)
                bind(popup) { [weak self, weak popup, weak pane] in
                    guard let self, let popup, let pane, PreferencesTools.encodings.indices.contains(popup.indexOfSelectedItem) else { return }
                    pane.textEncoding = PreferencesTools.encodings[popup.indexOfSelectedItem].1
                    self.preferences.savePanels()
                }
                encodingRows.append(row(title, detail: "Textcodierung für Vorschau und Inhaltsansicht.", control: popup))
            }
            append(SettingsStyle.section("Textvorschau", rows: encodingRows))
        case .keyboard:
            let explanation = label("Alle App-Aktionen können eine eigene Tastenkombination erhalten – auch Aktionen ohne Standardbelegung. Die Belegungen gelten für ihren jeweiligen Bereich, etwa Dateipanels, Dialoge, Git oder Remote-Browser.", size: 12, wrapping: true)
            explanation.textColor = SettingsStyle.secondaryTextColor
            append(explanation)
            let edit = NSButton(title: "Belegung bearbeiten …", target: nil, action: nil)
            edit.identifier = .init("settings.keyboardMapping")
            edit.setAccessibilityLabel("Tastaturbelegung bearbeiten")
            edit.controlSize = .small
            edit.bezelStyle = .rounded
            bind(edit) { [weak self] in
                guard let self, let window = self.window else { return }
                self.preferences.learnKeys(from: window)
            }
            append(SettingsStyle.section("Tastaturbelegung", rows: [
                row("Aktionen und Tastenkombinationen", detail: "Belegungen durchsuchen, aufzeichnen, entfernen und einzeln oder vollständig zurücksetzen. Konflikte werden vor dem Speichern angezeigt.", control: edit)
            ]))
        case .connections:
            let saved = max(3, min(300, defaults.object(forKey: "remoteTimeout") as? Int ?? 20))
            let timeout = NSTextField(string: String(saved))
            timeout.identifier = .init("settings.remoteTimeout")
            timeout.delegate = self
            timeout.alignment = .right
            timeout.widthAnchor.constraint(equalToConstant: 64).isActive = true
            timeout.setAccessibilityLabel("Verbindungs-Timeout in Sekunden")
            let stepper = NSStepper()
            stepper.minValue = 3; stepper.maxValue = 300; stepper.increment = 1
            stepper.integerValue = saved
            stepper.setAccessibilityLabel("Verbindungs-Timeout ändern")
            bind(stepper) { [weak self, weak stepper, weak timeout] in
                guard let self, let stepper, let timeout else { return }
                timeout.integerValue = stepper.integerValue
                self.defaults.set(stepper.integerValue, forKey: "remoteTimeout")
            }
            bind(timeout) { [weak self, weak stepper, weak timeout] in
                guard let self, let stepper, let timeout else { return }
                let value = max(3, min(300, Int(timeout.stringValue) ?? saved))
                timeout.integerValue = value
                stepper.integerValue = value
                self.defaults.set(value, forKey: "remoteTimeout")
            }
            let input = NSStackView(views: [timeout, label("s", size: 12), stepper])
            input.spacing = 8
            append(SettingsStyle.section("Remote-Verbindungen", rows: [
                row("Verbindungs-Timeout", detail: "3–300 Sekunden für neue FTP-, SFTP-, SSH- und Nextcloud-Verbindungen. Die Dateiansicht verwendet die gemeinsamen Einstellungen unter Panels.", control: input)
            ]))
        case .updates:
            append(updaterView())
        }
        return stack
    }
    private func toggle(_ title: String, detail: String, key: String, fallback: Bool = true) -> NSView {
        let button = SettingsToggle()
        button.controlSize = .small
        button.setAccessibilityLabel(title)
        button.state = (defaults.object(forKey: key) as? Bool ?? fallback) ? .on : .off
        bind(button) { [weak self, weak button] in
            guard let self, let button else { return }
            self.defaults.set(button.state == .on, forKey: key)
            if key == "rememberCommands", button.state == .off { self.defaults.removeObject(forKey: "commandHistory") }
            if key == "showHidden" { self.preferences.owner.setHiddenFilesVisible(button.state == .on) }
            self.preferences.apply()
        }
        return row(title, detail: detail, control: button)
    }
    private func row(_ title: String, detail: String, control: NSView) -> NSView {
        SettingsStyle.row(title, detail: detail, control: control)
    }
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === search else { return }
        let matches = SettingsSection.allCases.filter { $0.matches(search.stringValue) }
        for (section, button) in navigation { button.isHidden = !matches.contains(section) }
        if let first = matches.first {
            show(matches.contains(selectedSection) ? selectedSection : first)
        } else {
            clear(pages)
            breadcrumb.stringValue = "Einstellungen  /  Suche"
            pages.addArrangedSubview(SettingsStyle.heading("Keine Einstellungen gefunden"))
            pages.addArrangedSubview(label("Versuche einen anderen Suchbegriff.", size: 13))
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field.identifier?.rawValue == "settings.remoteTimeout" else { return }
        field.sendAction(field.action, to: field.target)
    }
    private func updateNavigation() {
        for (section, button) in navigation {
            let selected = section == selectedSection
            button.state = selected ? .on : .off
            button.needsDisplay = true
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }
    private func commitTimeoutEditing() {
        guard let editor = window?.firstResponder as? NSTextView,
              let field = editor.delegate as? NSTextField, field.identifier?.rawValue == "settings.remoteTimeout" else { return }
        field.validateEditing()
        field.sendAction(field.action, to: field.target)
        window?.makeFirstResponder(nil)
    }
    private func dismiss() {
        guard !didDismiss else { return }
        didDismiss = true
        commitTimeoutEditing()
        window?.makeFirstResponder(nil)
        if let window {
            defaults.set(NSStringFromRect(window.frame), forKey: "settings.windowFrame")
            window.orderOut(nil)
        }
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        onClose()
    }
    private func bind(_ control: NSControl, _ action: @escaping () -> Void) {
        let target = ClosureAction(action)
        actions.append(target)
        control.target = target
        control.action = #selector(ClosureAction.invoke(_:))
    }
    private func add(_ child: NSView, to parent: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, wrapping: Bool = false) -> NSTextField {
        let field = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
