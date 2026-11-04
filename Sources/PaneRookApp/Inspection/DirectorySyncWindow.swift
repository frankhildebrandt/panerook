import AppKit
import PaneRookCore

extension LocalTools {
    func synchronizeDirectories() {
        guard let owner, owner.canUseMenus,
              owner.leftPane.remoteContent == nil, owner.rightPane.remoteContent == nil,
              !owner.leftPane.isArchiveDirectory, !owner.rightPane.isArchiveDirectory else { return }
        let controller = DirectorySyncWindow(host: owner)
        retain(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// Configuration and plans belong to this window, never to a later active panel.
final class DirectorySyncWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private weak var host: (any InspectionHost)?
    private let store: DirectorySyncProfileStore
    private let left = ToolUI.field()
    private let right = ToolUI.field()
    private let profileManagement = NSStackView()
    private let deletion = NSButton(checkboxWithTitle: "Zusätzliche Einträge im Ziel endgültig löschen", target: nil, action: nil)
    private let exclusions = ToolUI.field()
    private let profiles = NSPopUpButton()
    private let profileName = ToolUI.field()
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Ordner vergleichen, Änderungen prüfen und anschließend ausführen.")
    private let preview = NSButton(title: "Vergleichen", target: nil, action: nil)
    private let execute = NSButton(title: "Änderungen ausführen …", target: nil, action: nil)
    private var buttons: [NSButton] = []
    private var savedProfiles: [DirectorySyncProfile] = []
    private(set) var plan: DirectorySyncPlan?
    private(set) var selection = Set<String>()
    private var runningTask: UUID?
    private(set) var confirmation: NSAlert?
    private var busy = false
    private let refresh: () -> Void

    init(host: any InspectionHost, store: DirectorySyncProfileStore = .init()) {
        self.host = host; self.store = store
        let leftPane = host.leftPane, rightPane = host.rightPane
        let leftURL = leftPane.directory, rightURL = rightPane.directory
        refresh = { [weak leftPane, weak rightPane] in
            if leftPane?.canApplyTaskResult(in: leftURL) == true { leftPane?.refreshAfterTask() }
            if rightPane?.canApplyTaskResult(in: rightURL) == true { rightPane?.refreshAfterTask() }
        }
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 990, height: 690),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Ordner synchronisieren"; panel.minSize = NSSize(width: 790, height: 560)
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center(); panel.contentView = AppStyle.background()
        for (control, id) in [(left, "left"), (right, "right"), (deletion, "deletion"),
                              (exclusions, "exclusions"), (profiles, "profiles"), (profileName, "profileName")] as [(NSControl, String)] {
            control.identifier = .init("sync." + id)
        }
        let fromRight = host.activePane === rightPane
        left.stringValue = (fromRight ? rightURL : leftURL).path
        right.stringValue = (fromRight ? leftURL : rightURL).path
        left.setAccessibilityLabel("Quellordner"); right.setAccessibilityLabel("Zielordner")
        deletion.target = self; deletion.action = #selector(optionsChanged)
        exclusions.placeholderString = "*.tmp; .git; build; Unterordner/cache"
        exclusions.toolTip = "Mit Semikolon getrennte Shell-Muster (*, ?, […]); Groß-/Kleinschreibung beachten. Ohne / gilt ein Muster für Namen auf jeder Ebene. Ausgeschlossene Ordner werden nicht betreten."
        for field in [left, right, exclusions] { field.delegate = self }
        profileName.placeholderString = "Profilname"
        profiles.target = self; profiles.action = #selector(loadProfile)
        let save = button("Profil speichern", id: "sync.profile.save", action: #selector(saveProfile))
        let remove = button("Profil entfernen", id: "sync.profile.remove", action: #selector(removeProfile))
        profiles.widthAnchor.constraint(equalToConstant: 190).isActive = true
        profileName.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        profileManagement.orientation = .horizontal; profileManagement.spacing = 8
        for view in [profileName, save, remove] { profileManagement.addArrangedSubview(view) }
        profileManagement.isHidden = true
        let manage = button("Profile verwalten", id: "sync.profiles.manage", action: #selector(toggleProfileManagement))
        let profileRow = NSStackView(views: [profiles, manage, NSView()]); profileRow.spacing = 8
        let sourcePicker = button("Ordner auswählen …", id: "sync.source.choose", action: #selector(chooseSource))
        let destinationPicker = button("Ordner auswählen …", id: "sync.destination.choose", action: #selector(chooseDestination))
        sourcePicker.setAccessibilityLabel("Quellordner auswählen")
        destinationPicker.setAccessibilityLabel("Zielordner auswählen")
        let swap = button("Tauschen", id: "sync.swap", action: #selector(swapFolders))
        swap.toolTip = "Quelle und Ziel tauschen"
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "Von der Quelle zum Ziel")!)
        let flow = NSStackView(views: [arrow, swap]); flow.orientation = .vertical; flow.spacing = 8
        func location(_ title: String, field: NSTextField, choose: NSButton) -> NSStackView {
            let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 14, weight: .semibold)
            let actions = NSStackView(views: [heading, NSView(), choose]); actions.spacing = 8
            let group = NSStackView(views: [actions, field]); group.orientation = .vertical; group.alignment = .leading; group.spacing = 8
            for view in [actions, field] { view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
            return group
        }
        let source = location("Quelle", field: left, choose: sourcePicker)
        let destination = location("Ziel", field: right, choose: destinationPicker)
        let locations = NSStackView(views: [source, flow, destination]); locations.spacing = 12; locations.alignment = .centerY
        source.widthAnchor.constraint(equalTo: destination.widthAnchor).isActive = true
        let options = NSStackView(views: [deletion, NSView()]); options.spacing = 8
        let exceptionsLabel = NSTextField(labelWithString: "Ausnahmen")
        let exclusionsRow = NSStackView(views: [exceptionsLabel, exclusions]); exclusionsRow.spacing = 12
        exclusions.setAccessibilityLabel("Von der Synchronisation ausgeschlossene Namen oder Pfade")
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.style = .inset
        for (id, title, width) in [("selected", "Auswahl", 65.0), ("path", "Relativer Pfad", 330.0), ("action", "Aktion / Hinweis", 360.0), ("bytes", "Umfang", 95.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let all = button("Alle", id: "sync.selectAll", action: #selector(selectAllActions))
        let none = button("Keine", id: "sync.selectNone", action: #selector(selectNone))
        all.setAccessibilityLabel("Alle Änderungen auswählen"); none.setAccessibilityLabel("Keine Änderungen auswählen")
        all.toolTip = "Alle Änderungen auswählen"; none.toolTip = "Keine Änderungen auswählen"
        preview.target = self; preview.action = #selector(makePreview); AppStyle.configureButton(preview); ContextCommands.configure(preview, id: "sync.preview")
        execute.target = self; execute.action = #selector(confirmExecution); AppStyle.configureButton(execute); ContextCommands.configure(execute, id: "sync.execute")
        let close = button("Schließen", id: "dialog.cancel", action: #selector(closeSync))
        let footer = NSStackView(views: [all, none, NSView(), close, preview, execute]); footer.spacing = 8
        status.font = .systemFont(ofSize: 12); status.setContentCompressionResistancePriority(.required, for: .vertical)
        let root = NSStackView(views: [locations, options, exclusionsRow, profileRow, profileManagement, scroll, status, footer])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        for view in [locations, options, exclusionsRow, profileRow, profileManagement, scroll, status, footer] { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true }
        panel.initialFirstResponder = preview
        panel.onCancel = { [weak self] in self?.closeSync() }
        panel.configureCommands(scope: .results) { [weak self] id in self?.performCommand(id) ?? false }
        reloadProfiles(); updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func button(_ title: String, id: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        AppStyle.configureButton(button); ContextCommands.configure(button, id: id); buttons.append(button); return button
    }
    private func performCommand(_ id: String) -> Bool {
        if let button = ([preview, execute] + buttons).first(where: { $0.identifier?.rawValue == id && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }) {
            button.performClick(nil); return true
        }
        return false
    }
    private var options: DirectorySyncOptions {
        .init(direction: .leftToRight,
              deleteExtraneous: deletion.state == .on,
              exclusions: exclusions.stringValue.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
    @objc private func toggleProfileManagement() { profileManagement.isHidden.toggle() }
    @objc private func swapFolders() {
        guard !busy else { return }
        let source = left.stringValue; left.stringValue = right.stringValue; right.stringValue = source
        optionsChanged()
    }
    @objc private func chooseSource() { chooseFolder(for: left, title: "Quellordner auswählen") }
    @objc private func chooseDestination() { chooseFolder(for: right, title: "Zielordner auswählen") }
    private func chooseFolder(for field: NSTextField, title: String) {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel(); picker.title = title; picker.prompt = "Auswählen"
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = URL(fileURLWithPath: (field.stringValue as NSString).expandingTildeInPath, isDirectory: true)
        picker.beginSheetModal(for: window) { [weak self, weak field] response in
            guard let self, let field, response == .OK, let url = picker.url else { return }
            field.stringValue = url.path; self.optionsChanged()
        }
    }
    private func urls() throws -> (URL, URL) {
        let paths = [left.stringValue, right.stringValue].map { ($0 as NSString).expandingTildeInPath }
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw DirectorySyncError.invalidRoots }
        return (URL(fileURLWithPath: paths[0], isDirectory: true), URL(fileURLWithPath: paths[1], isDirectory: true))
    }
    @objc private func optionsChanged() {
        plan = nil; selection = []; table.reloadData()
        status.stringValue = "Optionen geändert. Bitte eine neue Vorschau erstellen."; updateControls()
    }
    func controlTextDidChange(_ obj: Notification) { optionsChanged() }
    private func updateControls() {
        for control in [left, right, deletion, exclusions, profiles, profileName] as [NSControl] { control.isEnabled = !busy }
        buttons.forEach { $0.isEnabled = !busy || $0.identifier?.rawValue == "dialog.cancel" }
        preview.isEnabled = !busy; execute.isEnabled = !busy && plan != nil && !selection.isEmpty
        execute.title = selection.isEmpty ? "Änderungen ausführen …" : "\(selection.count) \(selection.count == 1 ? "Änderung" : "Änderungen") ausführen …"
        preview.title = plan == nil ? "Vergleichen" : "Erneut vergleichen"
    }
    @objc func makePreview() {
        guard !busy, let host else { return }
        do {
            let (a, b) = try urls(); let config = options
            optionsChanged(); busy = true; updateControls(); status.stringValue = "Vorschau wird erfasst …"
            let token = TransferCancellation()
            runningTask = host.tasks.submit(title: "Synchronisationsvorschau", detail: "\(a.path) ↔ \(b.path)", cancellation: { token.cancel() }, work: { progress in
                try DirectorySync.plan(left: a, right: b, options: config, cancellation: token, progress: progress)
            }, onReveal: { [weak self] in self?.showWindow(nil); self?.window?.makeKeyAndOrderFront(nil) }) { [weak self] result in
                guard let self else { return }
                self.busy = false; self.runningTask = nil
                switch result {
                case .success(let plan): self.plan = plan; self.selection = plan.defaultSelection; self.updateSummary()
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                self.table.reloadData(); self.updateControls()
            }
        } catch { showError(error) }
    }
    private func updateSummary() {
        guard let plan else { return }
        let actions = plan.actions.filter { selection.contains($0.id) }
        let added = actions.filter { $0.kind == .addFile || $0.kind == .createDirectory }.count
        let updated = actions.filter { $0.kind == .updateFile }.count
        let deleted = actions.filter { $0.kind.isDeletion }.count
        let blocked = plan.actions.filter { !$0.isSelectable }.count
        let bytes = ByteCountFormatter.string(fromByteCount: plan.transferBytes(selected: selection), countStyle: .file)
        status.stringValue = "\(actions.count) \(actions.count == 1 ? "Änderung" : "Änderungen"): \(added) neu · \(updated) aktualisieren · \(deleted) endgültig löschen · \(bytes)" +
            (blocked > 0 ? " · \(blocked) nicht ausführbar" : "") +
            (plan.excludedCount > 0 ? " · \(plan.excludedCount) ausgeschlossen" : "")
        status.toolTip = "\(plan.source.path) → \(plan.destination.path)"
    }
    @objc func confirmExecution() {
        guard !busy, let plan, !selection.isEmpty, let window, let host else { return }
        let chosen = selection
        let deletions = plan.actions.filter { chosen.contains($0.id) && $0.kind.isDeletion }.count
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Synchronisation ausführen?"
        alert.informativeText = "Quelle: \(plan.source.path)\nZiel: \(plan.destination.path)\n\n\(chosen.count) Aktionen · \(ByteCountFormatter.string(fromByteCount: plan.transferBytes(selected: chosen), countStyle: .file)) übertragen.\n\(deletions) Einträge werden endgültig gelöscht. Vorhandene Dateien werden bei Aktualisierungen ersetzt.\nKein Undo. Bereits abgeschlossene Aktionen bleiben bei Fehler oder Abbruch erhalten."
        alert.addButton(withTitle: "Ausführen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        confirmation = alert
        alert.beginSheetModal(for: window) { [weak self, weak host] response in
            self?.confirmation = nil
            guard let self, let host, response == .alertFirstButtonReturn else { return }
            self.busy = true; self.plan = nil; self.selection = []; self.table.reloadData(); self.updateControls()
            self.status.stringValue = "Synchronisation läuft …"
            let token = TransferCancellation()
            self.runningTask = host.tasks.submit(title: "Ordner synchronisieren", detail: "\(plan.source.path) → \(plan.destination.path) · Bereits abgeschlossene Aktionen bleiben erhalten.", cancellation: { token.cancel() }, work: { progress in
                try DirectorySync.execute(plan, selected: chosen, cancellation: token, progress: progress)
            }, onReveal: { [weak self] in self?.showWindow(nil); self?.window?.makeKeyAndOrderFront(nil) }) { [weak self] result in
                guard let self else { return }
                self.busy = false; self.runningTask = nil; self.refresh(); self.updateControls()
                switch result {
                case .success: self.status.stringValue = "Synchronisation abgeschlossen: \(chosen.count) Aktionen. Für weitere Änderungen eine neue Vorschau erstellen."
                case .failure(let error): self.status.stringValue = "\(error.localizedDescription) Bereits abgeschlossene Aktionen bleiben erhalten. Bitte eine neue Vorschau erstellen."
                }
            }
        }
    }
    @objc private func selectAllActions() { guard !busy, let plan else { return }; selection = plan.defaultSelection; selectionChanged() }
    @objc private func selectNone() { guard !busy else { return }; selection = []; selectionChanged() }
    @objc private func toggle(_ sender: NSButton) {
        guard !busy, let plan, plan.actions.indices.contains(sender.tag) else { return }
        selection = plan.selecting(plan.actions[sender.tag].id, included: sender.state == .on, in: selection); selectionChanged()
    }
    private func selectionChanged() { updateSummary(); table.reloadData(); updateControls() }
    private func reloadProfiles(select id: UUID? = nil) {
        do {
            savedProfiles = try store.profiles(); profiles.removeAllItems()
            profiles.addItems(withTitles: ["Profil laden …"] + savedProfiles.map(\.name))
            profiles.selectItem(at: id.flatMap { id in savedProfiles.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0)
        } catch { showError(error) }
    }
    @objc private func loadProfile() {
        let index = profiles.indexOfSelectedItem - 1
        guard savedProfiles.indices.contains(index) else { profileName.stringValue = ""; return }
        let profile = savedProfiles[index]
        let forward = profile.options.direction == .leftToRight
        left.stringValue = (forward ? profile.left : profile.right).path
        right.stringValue = (forward ? profile.right : profile.left).path
        profileName.stringValue = profile.name; exclusions.stringValue = profile.options.exclusions.joined(separator: "; ")
        deletion.state = profile.options.deleteExtraneous ? .on : .off
        optionsChanged()
    }
    @objc private func saveProfile() {
        do {
            let (a, b) = try urls(); let index = profiles.indexOfSelectedItem - 1
            let id = savedProfiles.indices.contains(index) ? savedProfiles[index].id : UUID()
            try store.save(.init(id: id, name: profileName.stringValue, left: a, right: b, options: options))
            reloadProfiles(select: id)
        } catch { showError(error) }
    }
    @objc private func removeProfile() {
        let index = profiles.indexOfSelectedItem - 1
        guard savedProfiles.indices.contains(index) else { return }
        do { try store.remove(savedProfiles[index].id); reloadProfiles(); profileName.stringValue = "" }
        catch { showError(error) }
    }
    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error); alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
    }
    @objc private func closeSync() { if let runningTask { host?.tasks.cancel(runningTask) }; close() }
    func windowWillClose(_ notification: Notification) { if let runningTask { host?.tasks.cancel(runningTask) } }
    func numberOfRows(in tableView: NSTableView) -> Int { plan?.actions.count ?? 0 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let action = plan?.actions[row] else { return nil }
        if tableColumn?.identifier.rawValue == "selected" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            checkbox.tag = row; checkbox.state = selection.contains(action.id) ? .on : .off; checkbox.isEnabled = action.isSelectable && !busy
            checkbox.setAccessibilityLabel("\(action.kind.label): \(action.id)")
            return checkbox
        }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "action": text = action.detail.map { "\(action.kind.label): \($0)" } ?? action.kind.label
        case "bytes": text = ByteCountFormatter.string(fromByteCount: action.bytes, countStyle: .file)
        default: text = action.relativePath.isEmpty ? "(Stammordner)" : action.relativePath
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingMiddle; field.toolTip = text
        if !action.isSelectable { field.textColor = .secondaryLabelColor }
        return field
    }
}
