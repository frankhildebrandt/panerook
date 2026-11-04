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
    private let addRule = NSPopUpButton()
    private let token = NSPopUpButton()
    private let numberOptions = NSStackView(), dateOptions = NSStackView()
    private let presetManagement = NSStackView()
    private let errorScroll = NSScrollView()
    private let emptyRules = NSTextField(wrappingLabelWithString: "Wähle oben eine Regel, zum Beispiel Text ersetzen oder Nummerieren. Die Vorschau zeigt jede Änderung vor dem Umbenennen.")
    private var sections: [Int: NSStackView] = [:]
    private var enabledSections = Set<Int>()
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
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 650),
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
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20)
        ])
        func label(_ title: String) -> NSTextField { NSTextField(labelWithString: title) }
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.spacing = 8; row.alignment = .centerY
            return row
        }
        func attach(_ view: NSView, to stack: NSStackView) {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        addRule.addItems(withTitles: ["Regel hinzufügen …", "Text ersetzen", "Text hinzufügen", "Nummerieren", "Datum hinzufügen", "Schreibweise ändern"])
        addRule.identifier = .init("rename.addRule")
        addRule.setAccessibilityLabel("Regel hinzufügen")
        addRule.target = self; addRule.action = #selector(addSelectedRule)
        preset.target = self; preset.action = #selector(loadPreset)
        preset.setAccessibilityLabel("Gespeicherte Umbenennungsregeln")
        let manage = NSButton(title: "Vorlagen verwalten", target: self, action: #selector(togglePresets))
        manage.identifier = .init("rename.presets.manage")
        AppStyle.configureButton(manage)
        attach(row([addRule, NSView(), preset, manage]), to: root)

        presetName.placeholderString = "Name der Vorlage"
        presetName.setAccessibilityLabel("Name der Umbenennungsvorlage")
        let save = NSButton(title: "Vorlage speichern", target: self, action: #selector(savePreset))
        let remove = NSButton(title: "Vorlage entfernen", target: self, action: #selector(removePreset))
        presetManagement.orientation = .horizontal; presetManagement.spacing = 8
        for view in [presetName, save, remove] { presetManagement.addArrangedSubview(view) }
        presetManagement.isHidden = true
        attach(presetManagement, to: root)

        let ruleStack = NSStackView(); ruleStack.orientation = .vertical; ruleStack.alignment = .leading; ruleStack.spacing = 16
        ruleStack.translatesAutoresizingMaskIntoConstraints = false
        let ruleScroll = NSScrollView(); ruleScroll.hasVerticalScroller = true
        ruleScroll.drawsBackground = false; ruleScroll.autohidesScrollers = false
        ruleScroll.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let ruleDocument = RenameRulesDocument()
        ruleDocument.translatesAutoresizingMaskIntoConstraints = false
        ruleDocument.addSubview(ruleStack); ruleScroll.documentView = ruleDocument
        NSLayoutConstraint.activate([
            ruleDocument.widthAnchor.constraint(equalTo: ruleScroll.contentView.widthAnchor),
            ruleStack.leadingAnchor.constraint(equalTo: ruleDocument.leadingAnchor),
            ruleStack.topAnchor.constraint(equalTo: ruleDocument.topAnchor),
            ruleStack.trailingAnchor.constraint(equalTo: ruleDocument.trailingAnchor, constant: -12),
            ruleStack.bottomAnchor.constraint(equalTo: ruleDocument.bottomAnchor)
        ])
        emptyRules.font = .systemFont(ofSize: 12); emptyRules.textColor = .secondaryLabelColor
        attach(emptyRules, to: ruleStack)
        func section(_ title: String, id: Int, views: [NSView]) {
            let heading = label(title); heading.font = .systemFont(ofSize: 13, weight: .semibold)
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Regel entfernen")!, target: self, action: #selector(removeRule(_:)))
            remove.tag = id; remove.isBordered = false
            remove.setAccessibilityLabel("\(title): Regel entfernen")
            remove.identifier = .init("rename.removeRule.\(id)")
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
            attach(row([heading, NSView(), remove]), to: stack)
            for view in views { attach(view, to: stack) }
            sections[id] = stack
            attach(stack, to: ruleStack)
        }
        search.placeholderString = "Gesuchter Text"; replacement.placeholderString = "Neuer Text"
        section("Text ersetzen", id: 0, views: [label("Suchen"), search, label("Ersetzen durch"), replacement, regex, matchCase])
        letterCase.addItems(withTitles: ["Unverändert", "kleinbuchstaben", "GROSSBUCHSTABEN", "Wortanfänge groß"])
        section("Schreibweise", id: 1, views: [letterCase])
        prefix.placeholderString = "Text vor dem Namen"; suffix.placeholderString = "Text nach dem Namen"
        token.addItems(withTitles: ["Einfügen …", "Nummer", "Datum"])
        token.target = self; token.action = #selector(insertToken)
        token.setAccessibilityLabel("Nummer oder Datum vor dem Namen einfügen")
        numberOptions.orientation = .vertical; numberOptions.alignment = .leading; numberOptions.spacing = 8
        dateOptions.orientation = .vertical; dateOptions.alignment = .leading; dateOptions.spacing = 8
        for (title, field) in [("Start", start), ("Schritt", step), ("Stellen", digits)] {
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
            numberOptions.addArrangedSubview(row([label(title), NSView(), field]))
        }
        for view in numberOptions.arrangedSubviews { view.widthAnchor.constraint(equalTo: numberOptions.widthAnchor).isActive = true }
        dateSource.addItems(withTitles: ["Heute", "Änderungsdatum", "Erstellungsdatum"])
        attach(dateSource, to: dateOptions); attach(label("Datumsformat"), to: dateOptions); attach(dateFormat, to: dateOptions)
        let tokenHint = NSTextField(wrappingLabelWithString: "Nummer und Datum lassen sich auch nach dem Namen platzieren: {n} bzw. {date} in das untere Feld verschieben.")
        tokenHint.font = .systemFont(ofSize: 11); tokenHint.textColor = .secondaryLabelColor
        token.toolTip = tokenHint.stringValue
        section("Name ergänzen", id: 2, views: [label("Vor dem Namen"), prefix, label("Nach dem Namen"), suffix, token, numberOptions, dateOptions])
        includeExtension.toolTip = "Gilt für alle Regeln. Ohne diese Option bleibt die Dateiendung unverändert."
        let options = NSStackView(views: [includeExtension]); options.orientation = .vertical; options.alignment = .leading
        attach(options, to: ruleStack)
        let order = NSTextField(wrappingLabelWithString: "Reihenfolge: Text ersetzen → Schreibweise → Name ergänzen")
        order.font = .systemFont(ofSize: 11); order.textColor = .secondaryLabelColor
        attach(order, to: ruleStack)

        for (id, title, width) in [("old", "Alter Name", 220.0), ("new", "Neuer Name", 260.0), ("status", "Status", 100.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let content = row([ruleScroll, scroll]); content.alignment = .top
        attach(content, to: root)
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        ruleScroll.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        scroll.heightAnchor.constraint(equalTo: content.heightAnchor).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        summary.font = .systemFont(ofSize: 12)
        attach(summary, to: root)
        errors.frame = NSRect(x: 0, y: 0, width: 900, height: 54)
        errors.isVerticallyResizable = true
        errors.isEditable = false; errors.isSelectable = true; errors.drawsBackground = false
        errors.font = .systemFont(ofSize: 12); errors.textColor = .systemRed
        errors.textContainer?.widthTracksTextView = true; errors.autoresizingMask = [.width]
        errorScroll.documentView = errors; errorScroll.hasVerticalScroller = true; errorScroll.drawsBackground = false
        errorScroll.isHidden = true
        attach(errorScroll, to: root)
        errorScroll.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel(_:)))
        submit.target = self; submit.action = #selector(confirm(_:)); submit.isEnabled = false
        for button in [cancel, submit, save, remove] { AppStyle.configureButton(button) }
        ContextCommands.configure(cancel, id: "dialog.cancel"); ContextCommands.configure(submit, id: "dialog.accept")
        attach(row([NSView(), cancel, submit]), to: root)
        for (field, title) in [(search, "Suchen"), (replacement, "Ersetzen"), (prefix, "Präfix"), (suffix, "Suffix"),
                               (start, "Nummerierung: Start"), (step, "Nummerierung: Schritt"), (digits, "Nummerierung: Stellen"),
                               (dateFormat, "Datumsformat")] {
            AppStyle.configureField(field); field.delegate = self
            field.setAccessibilityLabel(title); field.cell?.isScrollable = true
            field.cell?.sendsActionOnEndEditing = false
            field.target = self; field.action = #selector(confirm(_:))
        }
        for control: NSControl in [regex, matchCase, includeExtension, letterCase, dateSource] {
            control.target = self; control.action = #selector(rulesChanged)
        }
        panel.minSize = NSSize(width: 820, height: 520)
        panel.initialFirstResponder = addRule
    }

    @objc private func addSelectedRule() {
        let choice = addRule.indexOfSelectedItem
        switch choice {
        case 1: enabledSections.insert(0)
        case 2: enabledSections.insert(2)
        case 3: addToken("{n}_")
        case 4: addToken("{date}_")
        case 5: enabledSections.insert(1)
        default: return
        }
        addRule.selectItem(at: 0)
        updateRuleVisibility(); updatePreview()
        window?.makeFirstResponder(choice == 1 ? search : choice == 5 ? letterCase : prefix)
    }
    private func addToken(_ value: String) {
        enabledSections.insert(2)
        let marker = String(value.dropLast())
        if !prefix.stringValue.contains(marker) && !suffix.stringValue.contains(marker) {
            prefix.stringValue += value
        }
    }
    @objc private func insertToken() {
        if token.indexOfSelectedItem == 1 { addToken("{n}_") }
        else if token.indexOfSelectedItem == 2 { addToken("{date}_") }
        token.selectItem(at: 0); updateRuleVisibility(); updatePreview()
    }
    @objc private func removeRule(_ sender: NSButton) {
        enabledSections.remove(sender.tag)
        switch sender.tag {
        case 0: search.stringValue = ""; replacement.stringValue = ""; regex.state = .off
        case 1: letterCase.selectItem(at: 0)
        case 2: prefix.stringValue = ""; suffix.stringValue = ""
        default: break
        }
        updateRuleVisibility(); updatePreview(); window?.makeFirstResponder(addRule)
    }
    @objc private func togglePresets() { presetManagement.isHidden.toggle() }
    private func updateRuleVisibility() {
        emptyRules.isHidden = !enabledSections.isEmpty
        for (id, section) in sections { section.isHidden = !enabledSections.contains(id) }
        let template = prefix.stringValue + suffix.stringValue
        numberOptions.isHidden = !template.contains("{n}")
        dateOptions.isHidden = !template.contains("{date}")
    }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in completion(acceptedPlan) }
        window.makeFirstResponder(addRule)
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
        enabledSections = []
        if !rules.search.isEmpty || !rules.replacement.isEmpty { enabledSections.insert(0) }
        if rules.letterCase != .unchanged { enabledSections.insert(1) }
        if !rules.prefix.isEmpty || !rules.suffix.isEmpty { enabledSections.insert(2) }
        updateRuleVisibility(); updatePreview()
    }
    private func rules() throws -> BatchRenameRules {
        let usesNumber = (prefix.stringValue + suffix.stringValue).contains("{n}")
        let first = Int(start.stringValue), delta = Int(step.stringValue), width = Int(digits.stringValue)
        if usesNumber && (first == nil || delta == nil || width == nil) {
            throw BatchRenameError("Start, Schritt und Stellen müssen ganze Zahlen sein.")
        }
        var rules = BatchRenameRules()
        rules.search = search.stringValue; rules.replacement = replacement.stringValue
        rules.prefix = prefix.stringValue; rules.suffix = suffix.stringValue
        // Inactive number fields must not prevent an unrelated rule from being used.
        // Preserve valid preferences, but discard invalid dormant values in saved rules.
        rules.numberStart = first ?? 1; rules.numberStep = delta ?? 1
        rules.numberDigits = usesNumber ? width! : width.flatMap { (1...18).contains($0) ? $0 : nil } ?? 3
        rules.regularExpression = regex.state == .on; rules.caseSensitive = matchCase.state == .on
        rules.includeExtension = includeExtension.state == .on
        rules.letterCase = BatchRenameRules.LetterCase.allCases[letterCase.indexOfSelectedItem]
        rules.dateSource = BatchRenameRules.DateSource.allCases[dateSource.indexOfSelectedItem]
        rules.dateFormat = dateFormat.stringValue
        return rules
    }
    func controlTextDidChange(_ obj: Notification) { updateRuleVisibility(); updatePreview() }
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
            summary.stringValue = "Vorschau wird geprüft …"; errors.string = ""; errorScroll.isHidden = true
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
                        self.summary.stringValue = "\(plan.changedItems.count) von \(sources.count) Namen werden geändert"
                        self.submit.title = "\(plan.changedItems.count) umbenennen"
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
        errors.string = message; errorScroll.isHidden = false
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
        preset.removeAllItems(); preset.addItem(withTitle: "Vorlage laden …")
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

/// A short rule list stays at the top; longer combinations remain scrollable.
private final class RenameRulesDocument: NSView {
    override var isFlipped: Bool { true }
}
