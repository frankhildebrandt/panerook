import AppKit
import PaneRookCore

final class BatchRenameDialog: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let search = NSTextField(), replacement = NSTextField()
    private let prefix = NSTextField(), suffix = NSTextField()
    private let start = NSTextField(), step = NSTextField(), digits = NSTextField()
    private let dateFormat = NSTextField()
    private let regex = NSButton(checkboxWithTitle: "Regulärer Ausdruck", target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: "Groß-/Kleinschreibung beachten", target: nil, action: nil)
    private let includeExtension = NSButton(checkboxWithTitle: "Auch Erweiterung bearbeiten", target: nil, action: nil)
    private let letterCase = NSPopUpButton(), dateSource = NSPopUpButton()
    private let preset = NSPopUpButton(), presetName = NSTextField()
    private let table = NSTableView()
    private let summary = NSTextField(labelWithString: "Quellen werden erfasst …")
    private let errors = NSTextView()
    private let submit = NSButton(title: "Umbenennen", target: nil, action: nil)
    private let store: BatchRenamePresets
    private let completion: (BatchRenamePlan?) -> Void
    private let worker = DispatchQueue(label: "app.panerook.batch-rename-preview", qos: .userInitiated)
    private let referenceDate = Date()
    private var sources: [BatchRenameSource] = []
    private var sourceError: String?
    private var loaded = false
    private var revision = 0
    private var pendingPreview: DispatchWorkItem?
    private var acceptedPlan: BatchRenamePlan?
    private(set) var previewNames: [String] = []
    private(set) var previewPlan: BatchRenamePlan?
    private(set) var isPreviewPending = true

    init(sources urls: [URL], store: BatchRenamePresets = .init(), completion: @escaping (BatchRenamePlan?) -> Void) {
        self.store = store; self.completion = completion
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 690),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Mehrfachumbenennen"
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.cancel(nil) }
        panel.contentView = AppStyle.background(material: .sheet)
        buildUI(in: panel)
        setRules(store.lastRules)
        reloadPresets()
        worker.async { [weak self] in
            let result = Result { try urls.map { try BatchRenameSource(url: $0) } }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let sources): self.sources = sources
                case .failure(let error): self.sourceError = error.localizedDescription
                }
                self.loaded = true
                self.updatePreview()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    private func buildUI(in panel: NSPanel) {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18)
        ])
        func row(_ views: [NSView]) {
            let row = NSStackView(views: views); row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
        let title = label("Regeln kombinieren · Vorschau ohne Dateiänderungen")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)
        row([label("Suchen"), search, label("Ersetzen"), replacement])
        row([regex, matchCase, NSView()])
        row([label("Schreibweise"), letterCase, includeExtension, NSView()])
        letterCase.addItems(withTitles: ["Unverändert", "kleinbuchstaben", "GROSSBUCHSTABEN", "Wortanfänge groß"])
        row([label("Präfix"), prefix, label("Suffix"), suffix])
        row([label("Nummer {n}: Start"), start, label("Schritt"), step, label("Stellen"), digits])
        row([label("Datum {date}"), dateSource, label("Format"), dateFormat])
        dateSource.addItems(withTitles: ["Dialog geöffnet", "Änderungsdatum", "Erstellungsdatum"])
        let hint = label("Präfix/Suffix: {n} = Nummer, {date} = Datum (z. B. yyyy-MM-dd). Reihenfolge: Suchen → Schreibweise → Präfix/Suffix.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        presetName.placeholderString = "Preset-Name (gleicher Name ersetzt)"
        let save = NSButton(title: "Speichern", target: self, action: #selector(savePreset))
        let remove = NSButton(title: "Entfernen", target: self, action: #selector(removePreset))
        row([preset, presetName, save, remove])
        preset.target = self; preset.action = #selector(loadPreset)
        preset.setAccessibilityLabel("Gespeicherte Umbenennungsregeln")
        for (id, title, width) in [("old", "Alter Name", 280.0), ("new", "Neuer Name", 340.0), ("status", "Status", 160.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = 100
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        stack.addArrangedSubview(summary)
        errors.isEditable = false; errors.isSelectable = true; errors.drawsBackground = false
        errors.font = .systemFont(ofSize: 12); errors.textColor = .systemRed
        errors.textContainer?.widthTracksTextView = true
        errors.autoresizingMask = [.width]
        let errorScroll = NSScrollView(); errorScroll.documentView = errors; errorScroll.hasVerticalScroller = true
        errorScroll.drawsBackground = false
        stack.addArrangedSubview(errorScroll)
        errorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        errorScroll.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel(_:)))
        submit.target = self; submit.action = #selector(confirm(_:)); submit.isEnabled = false
        for button in [cancel, submit, save, remove] { AppStyle.configureButton(button) }
        ContextCommands.configure(cancel, id: "dialog.cancel")
        ContextCommands.configure(submit, id: "dialog.accept")
        row([NSView(), cancel, submit])
        for (field, title) in [(search, "Suchen"), (replacement, "Ersetzen"), (prefix, "Präfix"), (suffix, "Suffix"),
                               (start, "Nummerierung: Start"), (step, "Nummerierung: Schritt"), (digits, "Nummerierung: Stellen"),
                               (dateFormat, "Datumsformat")] {
            AppStyle.configureField(field); field.delegate = self
            field.setAccessibilityLabel(title); field.cell?.isScrollable = true
            field.cell?.sendsActionOnEndEditing = false
            field.target = self; field.action = #selector(confirm(_:))
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        }
        search.widthAnchor.constraint(equalTo: replacement.widthAnchor).isActive = true
        prefix.widthAnchor.constraint(equalTo: suffix.widthAnchor).isActive = true
        for control: NSControl in [regex, matchCase, includeExtension, letterCase, dateSource] {
            control.target = self; control.action = #selector(rulesChanged)
        }
        panel.minSize = NSSize(width: 860, height: 660)
        panel.initialFirstResponder = search
    }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in completion(acceptedPlan) }
        window.makeFirstResponder(search)
    }
    func setRules(_ rules: BatchRenameRules) {
        search.stringValue = rules.search; replacement.stringValue = rules.replacement
        prefix.stringValue = rules.prefix; suffix.stringValue = rules.suffix
        start.stringValue = String(rules.numberStart); step.stringValue = String(rules.numberStep)
        digits.stringValue = String(rules.numberDigits); dateFormat.stringValue = rules.dateFormat
        regex.state = rules.regularExpression ? .on : .off
        matchCase.state = rules.caseSensitive ? .on : .off
        includeExtension.state = rules.includeExtension ? .on : .off
        letterCase.selectItem(at: BatchRenameRules.LetterCase.allCases.firstIndex(of: rules.letterCase)!)
        dateSource.selectItem(at: BatchRenameRules.DateSource.allCases.firstIndex(of: rules.dateSource)!)
        updatePreview()
    }
    private func rules() throws -> BatchRenameRules {
        guard let first = Int(start.stringValue), let delta = Int(step.stringValue), let width = Int(digits.stringValue) else {
            throw BatchRenameError("Start, Schritt und Stellen müssen ganze Zahlen sein.")
        }
        var rules = BatchRenameRules()
        rules.search = search.stringValue; rules.replacement = replacement.stringValue
        rules.prefix = prefix.stringValue; rules.suffix = suffix.stringValue
        rules.numberStart = first; rules.numberStep = delta; rules.numberDigits = width
        rules.regularExpression = regex.state == .on; rules.caseSensitive = matchCase.state == .on
        rules.includeExtension = includeExtension.state == .on
        rules.letterCase = BatchRenameRules.LetterCase.allCases[letterCase.indexOfSelectedItem]
        rules.dateSource = BatchRenameRules.DateSource.allCases[dateSource.indexOfSelectedItem]
        rules.dateFormat = dateFormat.stringValue
        return rules
    }
    func controlTextDidChange(_ obj: Notification) { updatePreview() }
    @objc private func rulesChanged() { updatePreview() }

    func updatePreview() {
        pendingPreview?.cancel()
        revision += 1
        let expected = revision
        previewPlan = nil; isPreviewPending = true; submit.isEnabled = false
        guard loaded else { return }
        previewNames = []; table.reloadData()
        if let sourceError { showFailure(sourceError); return }
        do {
            let rules = try rules(), sources = sources, date = referenceDate
            summary.stringValue = "Vorschau wird geprüft …"; errors.string = ""
            // Debouncing and a generation check prevent obsolete results from enabling execution.
            let pending = DispatchWorkItem { [weak self] in
                var names: [String] = []
                let result = Result { () -> BatchRenamePlan in
                    names = try rules.names(for: sources, referenceDate: date)
                    return try BatchRenamePlan(sources: sources, names: names)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.revision == expected else { return }
                    self.previewNames = names; self.isPreviewPending = false
                    switch result {
                    case .success(let plan):
                        self.previewPlan = plan
                        self.submit.isEnabled = !plan.changedItems.isEmpty
                        self.summary.stringValue = "\(plan.changedItems.count) von \(sources.count) Einträgen ändern sich · Ausführung im jeweiligen Quellordner"
                        self.errors.string = ""
                    case .failure(let error): self.showFailure(error.localizedDescription)
                    }
                    self.table.reloadData()
                }
            }
            pendingPreview = pending
            worker.asyncAfter(deadline: .now() + 0.15, execute: pending)
        } catch { showFailure(error.localizedDescription) }
    }
    private func showFailure(_ message: String) {
        isPreviewPending = false; previewPlan = nil; submit.isEnabled = false
        summary.stringValue = "Bitte Regeln oder Auswahl prüfen. Es wurde nichts umbenannt."
        errors.string = message
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sources.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let source = sources[row].url
        let name = row < previewNames.count ? previewNames[row] : "—"
        let id = tableColumn?.identifier.rawValue
        let text = id == "old" ? source.lastPathComponent : id == "new" ? name :
            (previewPlan == nil ? "Prüfen" : source.lastPathComponent.utf8.elementsEqual(name.utf8) ? "Unverändert" : "Umbenennen")
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = id == "new" ? source.deletingLastPathComponent().appendingPathComponent(name).path : source.path
        return field
    }
    private func reloadPresets() {
        preset.removeAllItems(); preset.addItem(withTitle: "Preset laden …")
        preset.addItems(withTitles: store.presets.map(\.name))
    }
    @objc private func loadPreset() {
        let index = preset.indexOfSelectedItem - 1
        guard store.presets.indices.contains(index) else { return }
        let value = store.presets[index]; presetName.stringValue = value.name; setRules(value.rules)
    }
    @objc private func savePreset() {
        do {
            let value = try rules()
            _ = try value.names(for: sources, referenceDate: referenceDate)
            try store.save(name: presetName.stringValue, rules: value)
            reloadPresets(); updatePreview()
        } catch { showFailure(error.localizedDescription) }
    }
    @objc private func removePreset() {
        guard preset.indexOfSelectedItem > 0, let name = preset.titleOfSelectedItem else { return }
        do { try store.remove(name: name); reloadPresets(); updatePreview() }
        catch { showFailure(error.localizedDescription) }
    }
    @objc private func confirm(_ sender: Any?) {
        if sender is NSTextField {
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  ContextCommands.matching(event, scope: .dialog)?.hasPrefix("dialog.accept") == true else { return }
        }
        guard !isPreviewPending, let plan = previewPlan, !plan.changedItems.isEmpty, acceptedPlan == nil else { NSSound.beep(); return }
        do { try store.remember(rules()) } catch { showFailure(error.localizedDescription); return }
        acceptedPlan = plan
        if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: .OK) }
    }
    @objc private func cancel(_ sender: Any?) {
        revision += 1; acceptedPlan = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
    }
}
