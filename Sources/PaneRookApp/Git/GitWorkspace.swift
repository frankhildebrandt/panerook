import AppKit
import PaneRookCore
import PaneRookPanels

/// One native workspace for a captured repository; Git always runs off the main thread.
final class GitWorkspace: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onDidChange: (() -> Void)?
    var onClose: (() -> Void)?
    private let repository: GitRepository
    private let queue = DispatchQueue(label: "app.panerook.git", qos: .userInitiated)
    private let branch = NSPopUpButton()
    private let actions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let mode = NSSegmentedControl(labels: ["Dateien", "Verlauf", "Stashes"], trackingMode: .selectOne, target: nil, action: nil)
    private let filter = NSPopUpButton()
    private let search = NSSearchField()
    private let historyPath = NSTextField()
    private let table = NSTableView()
    private let diff = NSTextView()
    private let diffMode = NSSegmentedControl(labels: ["Arbeitskopie", "Staged"], trackingMode: .selectOne, target: nil, action: nil)
    private let details = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let fileActions = NSStackView()
    private let historyActions = NSStackView()
    private let stashActions = NSStackView()
    private var controls: [NSControl] = []
    private var snapshot: GitSnapshot?
    private var statusByPath: [String: GitFileStatus] = [:]
    private var branches: [GitBranch] = []
    private var commits: [GitCommit] = []
    private var files: [String] = []
    private var visibleCommits: [GitCommit] = []
    private var visibleStashes: [GitStash] = []
    private var busy = false
    private var previewGeneration = 0
    private var initialFile: String?
    private let watches = GitWatchStore()
    private var watchedPaths = Set<String>()
    private let filterNames = ["Alle", "Changed", "Staged", "Untracked", "Conflicted", "Stashed", "Watched", "Tracked", "Ignored"]

    init(repository: GitRepository, selectedFile: URL?) {
        self.repository = repository
        initialFile = selectedFile.flatMap { GitPanelPaths.relativePath(for: $0, in: repository.root) }
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        historyPath.stringValue = initialFile ?? ""
        panel.title = "Git · " + repository.root.lastPathComponent
        panel.minSize = NSSize(width: 850, height: 580)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.window?.performClose(nil) }
        panel.center()
        buildView()
    }
    required init?(coder: NSCoder) { fatalError() }

    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }

    private func buildView() {
        guard let window else { return }
        let background = AppStyle.background(); window.contentView = background
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 9
        root.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: background.safeAreaLayoutGuide.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)
        ])
        let path = NSTextField(labelWithString: repository.root.path)
        path.font = .systemFont(ofSize: 11); path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle; path.isSelectable = true
        root.addArrangedSubview(path); path.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        branch.setAccessibilityLabel("Branch oder Tag")
        branch.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        branch.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
        let header = row([branch, button("Wechseln", #selector(switchBranch)), button("Neuer Branch …", #selector(newBranch)), NSView(), actions, button("Aktualisieren", #selector(reload))])
        addMenuActions()
        root.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        details.font = .systemFont(ofSize: 12, weight: .medium); details.lineBreakMode = .byTruncatingMiddle
        root.addArrangedSubview(details); details.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Git-Ansicht")
        filter.addItems(withTitles: filterNames); filter.selectItem(at: 1)
        filter.target = self; filter.action = #selector(refilter); filter.setAccessibilityLabel("Git-Statusfilter")
        search.placeholderString = "Pfad, Nachricht oder Autor filtern"
        search.target = self; search.action = #selector(refilter); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Git-Einträge filtern")
        let scope = row([mode, filter, search]); root.addArrangedSubview(scope)
        scope.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        historyPath.placeholderString = "Dateiverlauf: relativer Pfad (leer = Repository)"
        AppStyle.configureField(historyPath); historyPath.target = self; historyPath.action = #selector(reloadHistory)
        historyPath.setAccessibilityLabel("Dateipfad für den Verlauf")
        historyPath.isHidden = true; root.addArrangedSubview(historyPath)
        historyPath.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        table.delegate = self; table.dataSource = self; table.style = .inset; table.rowHeight = 26
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Git-Dateien, Versionen und Stashes")
        for (id, title, width) in [("status", "Status", 100.0), ("name", "Pfad", 750.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            column.minWidth = id == "status" ? 80 : 200
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(column)
        }
        let listScroll = NSScrollView(); listScroll.hasVerticalScroller = true; listScroll.documentView = table
        listScroll.borderType = .bezelBorder
        let diffScroll = NSScrollView(); diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true
        diff.isEditable = false; diff.isRichText = false; diff.isSelectable = true
        diff.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        diff.textContainerInset = NSSize(width: 10, height: 10); diff.autoresizingMask = [.width]
        diff.isVerticallyResizable = true; diff.textContainer?.widthTracksTextView = true
        diff.setAccessibilityLabel("Git-Diff und Versionsvorschau")
        diffScroll.documentView = diff; diffScroll.borderType = .bezelBorder
        let split = NSSplitView(); split.isVertical = false; split.dividerStyle = .thin
        split.addArrangedSubview(listScroll); split.addArrangedSubview(diffScroll)
        root.addArrangedSubview(split); split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        diffScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        diffMode.selectedSegment = 0; diffMode.target = self; diffMode.action = #selector(showSelection)
        diffMode.setAccessibilityLabel("Diff von Arbeitskopie oder Index")
        fileActions.spacing = 8
        for view in [diffMode, button("Stage", #selector(stage)), button("Unstage", #selector(unstage)), button("Commit …", #selector(commit)), button("Stash …", #selector(saveStash)), button("Beobachten", #selector(toggleWatch))] { fileActions.addArrangedSubview(view) }
        historyActions.spacing = 8
        historyActions.addArrangedSubview(button("Version auschecken …", #selector(checkoutCommit)))
        historyActions.addArrangedSubview(button("Datei dieser Version anzeigen", #selector(showHistoricFile)))
        let hint = NSTextField(labelWithString: "Vorschau: Patch der ausgewählten Version · maximal 200 Commits")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor; historyActions.addArrangedSubview(hint)
        stashActions.spacing = 8
        for (title, action) in [("Stash …", #selector(saveStash)), ("Anwenden", #selector(applyStash)), ("Pop …", #selector(popStash)), ("Löschen …", #selector(dropStash))] { stashActions.addArrangedSubview(button(title, action)) }
        for toolbar in [fileActions, historyActions, stashActions] { root.addArrangedSubview(toolbar) }
        historyActions.isHidden = true; stashActions.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        let footer = row([spinner, status, NSView()]); root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        controls += [branch, actions, mode, filter, search, historyPath, diffMode]
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.spacing = 8; stack.alignment = .centerY; return stack
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        AppStyle.configureButton(control); control.controlSize = .small; controls.append(control); return control
    }
    private func addMenuActions() {
        actions.addItem(withTitle: "Aktionen")
        for (title, tag) in [("Fetch", 1), ("Pull (nur Fast-Forward)", 2), ("Push", 3), ("Ausgewählten Branch mergen …", 4), ("Ausgewählten Branch löschen …", 5), ("Tag anlegen …", 6)] {
            actions.addItem(withTitle: title); actions.lastItem?.tag = tag
        }
        actions.target = self; actions.action = #selector(menuAction)
    }

    @objc func reload() {
        guard !busy else { return }
        perform("Repository wird gelesen …", work: { [repository] in
            (try repository.snapshot(), try repository.branches(), try repository.history(), try repository.tags())
        }) { [weak self] value in
            guard let self else { return }
            self.snapshot = value.0; self.branches = value.1; self.commits = value.2
            self.statusByPath = Dictionary(value.0.files.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            let selectedBranch = self.branch.titleOfSelectedItem
            self.branch.removeAllItems()
            for item in value.1 {
                let label = (item.current ? "● " : "") + item.name + (item.remote ? " (remote)" : "")
                self.branch.addItem(withTitle: label); self.branch.lastItem?.representedObject = item.name
                self.branch.lastItem?.tag = item.remote ? 1 : 0
            }
            for tag in value.3 {
                self.branch.addItem(withTitle: "Tag: " + tag); self.branch.lastItem?.representedObject = tag
                self.branch.lastItem?.tag = 2
            }
            if let selectedBranch, self.branch.itemTitles.contains(selectedBranch) { self.branch.selectItem(withTitle: selectedBranch) }
            else if let current = value.1.firstIndex(where: { $0.current }) { self.branch.selectItem(at: current) }
            self.updateDetails()
            self.refilter()
            if !self.historyPath.stringValue.isEmpty { self.reloadHistory() }
        }
    }

    private func updateDetails() {
        guard let snapshot else { return }
        let changes = snapshot.files.filter { $0.isChanged }.count
        let state = snapshot.head == nil ? " · noch kein Commit" : ""
        let tracking = snapshot.upstream.map { " · \($0) ↑\(snapshot.ahead) ↓\(snapshot.behind)" } ?? " · kein Upstream"
        let operation = snapshot.operation.map { " · \($0)" } ?? ""
        details.stringValue = "\(snapshot.branch)\(state)\(tracking) · \(changes) geändert · \(snapshot.stashes.count) Stashes\(operation)"
    }

    @objc private func modeChanged() {
        filter.isHidden = mode.selectedSegment != 0
        historyPath.isHidden = mode.selectedSegment != 1
        fileActions.isHidden = mode.selectedSegment != 0
        historyActions.isHidden = mode.selectedSegment != 1
        stashActions.isHidden = mode.selectedSegment != 2
        table.allowsMultipleSelection = mode.selectedSegment == 0
        table.tableColumns[0].title = mode.selectedSegment == 0 ? "Status" : mode.selectedSegment == 1 ? "Commit" : "Stash"
        table.tableColumns[1].title = mode.selectedSegment == 0 ? "Pfad" : mode.selectedSegment == 1 ? "Nachricht · Autor · Datum" : "Nachricht"
        refilter()
    }

    @objc private func refilter() {
        guard let snapshot else { return }
        let selected = Set(selectedPaths)
        let term = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = { term.isEmpty || $0.localizedCaseInsensitiveContains(term) }
        if mode.selectedSegment == 0 {
            let byPath = statusByPath
            let watched = watches.paths(in: repository.root)
            watchedPaths = watched
            let allPaths = Set(snapshot.files.map(\.path)).union(snapshot.trackedPaths).union(snapshot.stashedPaths).union(watched)
            files = allPaths.filter { path in
                guard matches(path) else { return false }
                let entry = byPath[path]
                switch self.filter.indexOfSelectedItem {
                case 1: return entry?.isChanged == true
                case 2: return entry?.isStaged == true
                case 3: return entry?.isUntracked == true
                case 4: return entry?.isConflicted == true
                case 5: return snapshot.stashedPaths.contains(path)
                case 6: return watched.contains(path) || watched.contains(where: { path.hasPrefix($0 + "/") })
                case 7: return snapshot.trackedPaths.contains(path)
                case 8: return entry?.isIgnored == true
                default: return true
                }
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } else if mode.selectedSegment == 1 {
            visibleCommits = commits.filter { matches($0.subject + " " + $0.author + " " + $0.id) }
        } else {
            visibleStashes = snapshot.stashes.filter { matches($0.subject + " " + $0.id) }
        }
        table.reloadData()
        var indexes = IndexSet()
        if mode.selectedSegment == 0 {
            indexes = IndexSet(files.indices.filter { selected.contains(files[$0]) || files[$0] == initialFile })
            initialFile = nil
        }
        if indexes.isEmpty && numberOfRows(in: table) > 0 { indexes = IndexSet(integer: 0) }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        status.stringValue = "\(numberOfRows(in: table)) Einträge · Status: Index / Arbeitskopie · ★ beobachtet"
        showSelection()
    }

    @objc private func reloadHistory() {
        guard !busy else { return }
        let path = historyPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Verlauf wird gelesen …", work: { [repository] in try repository.history(path: path.isEmpty ? nil : path) }) { [weak self] commits in
            self?.commits = commits; self?.refilter()
        }
    }

    private var selectedPaths: [String] {
        guard mode.selectedSegment == 0 else { return [] }
        return table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil }
    }
    private var selectedCommit: GitCommit? {
        let row = table.selectedRow
        return mode.selectedSegment == 1 && visibleCommits.indices.contains(row) ? visibleCommits[row] : nil
    }
    private var selectedStash: GitStash? {
        let row = table.selectedRow
        return mode.selectedSegment == 2 && visibleStashes.indices.contains(row) ? visibleStashes[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        mode.selectedSegment == 0 ? files.count : mode.selectedSegment == 1 ? visibleCommits.count : visibleStashes.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < numberOfRows(in: tableView) else { return nil }
        let first = tableColumn?.identifier.rawValue == "status"
        let value: String
        if mode.selectedSegment == 0 {
            let path = files[row]
            let entry = statusByPath[path]
            if first {
                let xy = entry.map { $0.indexStatus + $0.workTreeStatus } ?? "  "
                value = xy + (watchedPaths.contains(path) || watchedPaths.contains(where: { path.hasPrefix($0 + "/") }) ? " ★" : "")
                    + (snapshot?.stashedPaths.contains(path) == true ? " S" : "")
            } else { value = path + (entry?.originalPath.map { " ← " + $0 } ?? "") }
        } else if mode.selectedSegment == 1 {
            let commit = visibleCommits[row]
            value = first ? commit.shortID : "\(commit.subject) · \(commit.author) · \(Self.dateFormatter.string(from: commit.date))"
        } else {
            let stash = visibleStashes[row]; value = first ? stash.id : stash.subject
        }
        let label = NSTextField(labelWithString: value)
        label.font = first ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short; return formatter
    }()
    func tableViewSelectionDidChange(_ notification: Notification) { showSelection() }

    @objc private func showSelection() {
        previewGeneration += 1
        let generation = previewGeneration
        guard !busy else { return }
        let selectedMode = mode.selectedSegment
        let path = selectedPaths.first
        let commit = selectedCommit
        let stash = selectedStash
        let isUntracked = path.flatMap { statusByPath[$0] }?.isUntracked == true
        let staged = diffMode.selectedSegment == 1
        if selectedMode == 0 && path == nil || selectedMode == 1 && commit == nil || selectedMode == 2 && stash == nil {
            diff.string = "Keine Auswahl."; return
        }
        diff.string = "Vorschau wird gelesen …"
        queue.async { [weak self, repository] in
            let result = Result { () -> String in
                if selectedMode == 1 { return try repository.diff(revision: commit!.id) }
                if selectedMode == 2 { return try repository.diff(revision: stash!.objectID) }
                if selectedMode == 0 && isUntracked && !staged, let path {
                    return try Self.untrackedPreview(at: repository.root.appendingPathComponent(path))
                }
                let value = try repository.diff(path: path, staged: staged)
                return value.isEmpty ? "Keine \(staged ? "vorgemerkten" : "nicht vorgemerkten") Änderungen für \(path!)." : value
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewGeneration == generation else { return }
                switch result {
                case .success(let value): self.diff.string = value
                case .failure(let error): self.diff.string = error.localizedDescription
                }
            }
        }
    }

    private static func untrackedPreview(at url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return "Unversionierter Eintrag. Für die Vorschau bitte eine reguläre Datei auswählen."
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 1024 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.contains(0), let value = String(data: data.prefix(limit), encoding: .utf8) else {
            return "Unversionierte Binärdatei oder Datei mit anderer Textcodierung."
        }
        return "Unversionierte Datei · \(url.lastPathComponent)\n\n" + value
            + (data.count > limit ? "\n\n[Vorschau nach 1 MiB gekürzt]" : "")
    }

    private func perform<Value>(_ title: String, work: @escaping () throws -> Value, completion: @escaping (Value) -> Void) {
        guard !busy else { return }
        busy = true; previewGeneration += 1
        controls.forEach { $0.isEnabled = false }; table.isEnabled = false
        status.stringValue = title; spinner.startAnimation(nil)
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false; self.controls.forEach { $0.isEnabled = true }; self.table.isEnabled = true
                self.spinner.stopAnimation(nil)
                switch result {
                case .success(let value): completion(value)
                case .failure(let error): self.status.stringValue = error.localizedDescription; self.showError(error)
                }
            }
        }
    }

    private func mutate(_ title: String, _ operation: GitOperation, expectedStash: GitStash? = nil) {
        perform(title, work: { [repository] in
            Result { () -> String in
                if let expectedStash {
                    let current = try repository.snapshot().stashes.first { $0.id == expectedStash.id }
                    guard current?.objectID == expectedStash.objectID else {
                        throw GitError("Die Stash-Liste wurde inzwischen geändert. Bitte aktualisieren und den Stash erneut auswählen.")
                    }
                }
                return try repository.run(operation)
            }
        }) { [weak self] result in
            guard let self else { return }
            self.onDidChange?()
            self.reload()
            switch result {
            case .success(let output): if !output.isEmpty { self.diff.string = output }
            case .failure(let error): self.diff.string = error.localizedDescription; self.showError(error)
            }
        }
    }
    private func showError(_ error: Error) {
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Git-Aktion fehlgeschlagen"
        alert.informativeText = error.localizedDescription
        alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
    }

    private func prompt(_ title: String, label: String, value: String = "", accept: String = "OK", completion: @escaping (String) -> Void) {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title
        let field = ToolUI.field(value); field.setAccessibilityLabel(label)
        alert.accessoryView = ToolUI.form([(label, field)])
        alert.addButton(withTitle: accept); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
    }
    private func confirm(_ title: String, detail: String, accept: String, completion: @escaping () -> Void) {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: accept); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { completion() } }
    }

    @objc private func stage() {
        let paths = selectedPaths; guard !paths.isEmpty else { return }
        mutate("Dateien werden vorgemerkt …", .stage(paths))
    }
    @objc private func unstage() {
        let paths = selectedPaths; guard !paths.isEmpty else { return }
        mutate("Dateien werden aus dem Index genommen …", .unstage(paths))
    }
    @objc private func toggleWatch() {
        guard !busy, !selectedPaths.isEmpty else { return }
        watches.toggle(paths: selectedPaths, in: repository.root)
        NotificationCenter.default.post(name: .paneRookGitWatchesChanged, object: nil)
        refilter(); onDidChange?()
    }
    @objc private func commit() {
        guard snapshot?.files.contains(where: { $0.isStaged }) == true else {
            status.stringValue = "Zuerst Änderungen mit Stage vormerken."; return
        }
        prompt("Vorgemerkte Änderungen committen", label: "Commit-Nachricht", accept: "Commit") { [weak self] message in
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.mutate("Commit wird erstellt …", .commit(message))
        }
    }
    @objc private func newBranch() {
        prompt("Branch anlegen und wechseln", label: "Branchname", accept: "Anlegen") { [weak self] name in
            self?.mutate("Branch wird angelegt …", .createBranch(name))
        }
    }
    @objc private func switchBranch() {
        guard let item = branch.selectedItem, let name = item.representedObject as? String else { return }
        if item.tag == 2 {
            confirm("Tag auschecken?", detail: "\(name) wird als losgelöster HEAD ausgecheckt. Ein neuer Branch hält anschließende Commits fest.", accept: "Auschecken") { [weak self] in
                self?.mutate("Version wird ausgecheckt …", .checkoutRevision("refs/tags/" + name))
            }
        } else { mutate("Branch wird gewechselt …", .switchBranch(name)) }
    }
    @objc private func checkoutCommit() {
        guard let commit = selectedCommit else { return }
        confirm("Version \(commit.shortID) auschecken?", detail: "\(commit.subject)\n\nDu wechselst auf einen losgelösten HEAD. Mit „Neuer Branch“ kannst du darauf weiterarbeiten. Git schützt entgegenstehende lokale Änderungen.", accept: "Auschecken") { [weak self] in
            self?.mutate("Version wird ausgecheckt …", .checkoutRevision(commit.id))
        }
    }
    @objc private func showHistoricFile() {
        guard let commit = selectedCommit else { return }
        let path = historyPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            prompt("Datei der Version \(commit.shortID) anzeigen", label: "Relativer Dateipfad") { [weak self] path in self?.loadHistoricFile(commit: commit, path: path) }
        } else { loadHistoricFile(commit: commit, path: path) }
    }
    private func loadHistoricFile(commit: GitCommit, path: String) {
        perform("Dateiversion wird gelesen …", work: { [repository] in try repository.show(revision: commit.id, path: path) }) { [weak self] value in
            self?.diff.string = value
            self?.status.stringValue = "\(path) · \(commit.shortID) · Vorschau"
        }
    }
    @objc private func saveStash() {
        prompt("Lokale Änderungen in Stash ablegen", label: "Nachricht (einschließlich unversionierter Dateien)", accept: "Stash anlegen") { [weak self] message in
            self?.mutate("Stash wird angelegt …", .stashSave(message))
        }
    }
    @objc private func applyStash() {
        guard let stash = selectedStash else { return }
        mutate("Stash wird angewendet …", .stashApply(stash.id), expectedStash: stash)
    }
    @objc private func popStash() {
        guard let stash = selectedStash else { return }
        confirm("Stash anwenden und entfernen?", detail: "\(stash.id): \(stash.subject)\nBei Konflikten behält Git den Stash.", accept: "Pop") { [weak self] in
            self?.mutate("Stash wird angewendet …", .stashPop(stash.id), expectedStash: stash)
        }
    }
    @objc private func dropStash() {
        guard let stash = selectedStash else { return }
        confirm("Stash endgültig löschen?", detail: "\(stash.id): \(stash.subject)", accept: "Stash löschen") { [weak self] in
            self?.mutate("Stash wird gelöscht …", .stashDrop(stash.id), expectedStash: stash)
        }
    }
    @objc private func menuAction() {
        guard !busy else { return }
        let item = branch.selectedItem
        let name = item?.representedObject as? String
        switch actions.selectedItem?.tag {
        case 1: mutate("Fetch läuft …", .fetch)
        case 2: mutate("Pull läuft …", .pull)
        case 3:
            confirm("Branch pushen?", detail: "Der aktuelle Branch wird an seinen konfigurierten Remote übertragen.", accept: "Push") { [weak self] in self?.mutate("Push läuft …", .push) }
        case 4:
            guard let name, item?.tag != 2 else { return }
            let reference = (item?.tag == 1 ? "refs/remotes/" : "refs/heads/") + name
            confirm("\(name) in aktuellen Branch mergen?", detail: "Der Merge kann einen Commit erstellen oder Konflikte erzeugen.", accept: "Mergen") { [weak self] in self?.mutate("Merge läuft …", .merge(reference)) }
        case 5:
            guard let name, item?.tag == 0 else { return }
            confirm("Branch \(name) löschen?", detail: "Git löscht nur einen bereits integrierten lokalen Branch.", accept: "Branch löschen") { [weak self] in self?.mutate("Branch wird gelöscht …", .deleteBranch(name)) }
        case 6:
            prompt("Tag am aktuellen Commit anlegen", label: "Tagname", accept: "Tag anlegen") { [weak self] name in self?.mutate("Tag wird angelegt …", .createTag(name)) }
        default: break
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !busy else { status.stringValue = "Git-Aktion läuft. Das Fenster lässt sich nach Abschluss schließen."; return false }
        return true
    }
    func windowWillClose(_ notification: Notification) { previewGeneration += 1; onClose?() }
}
