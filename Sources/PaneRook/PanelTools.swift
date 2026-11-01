import AppKit
import PaneRookCore

private struct InspectionRow {
    let path: String
    let status: String
    let left: URL?
    let right: URL?
}

/// Search and comparisons are read-only workers. Their captured paths stay stable while the panels navigate.
final class LocalTools {
    private weak var owner: CommanderController?
    private var windows: [NSWindowController] = []
    init(owner: CommanderController) { self.owner = owner }
    func closeAll() { windows.forEach { $0.close() } }
    var taskWindows: [NSWindow] { windows.compactMap(\.window).filter { $0.isVisible } }

    func findFiles() {
        guard let owner, owner.canUseMenus, let window = owner.view.window else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveToolError); return }
        let pane = owner.active!
        let root = ToolUI.field(pane.directory.path)
        let name = ToolUI.field("*")
        let content = ToolUI.field()
        content.toolTip = "Textsuche in den ersten 1 MiB regulärer Dateien; Kodierung des Panels."
        let recursive = NSButton(checkboxWithTitle: "Unterordner durchsuchen", target: nil, action: nil); recursive.state = .on
        let hidden = NSButton(checkboxWithTitle: "Versteckte Dateien", target: nil, action: nil); hidden.state = pane.showHidden ? .on : .off
        let sensitive = NSButton(checkboxWithTitle: "Groß-/Kleinschreibung beachten", target: nil, action: nil)
        let options = NSStackView(views: [recursive, hidden, sensitive]); options.orientation = .vertical; options.alignment = .leading; options.spacing = 4
        let alert = NSAlert(); alert.messageText = "Dateien suchen"
        alert.accessoryView = ToolUI.form([("Suchen in", root), ("Dateiname", name), ("Enthält Text", content), ("", options)])
        alert.addButton(withTitle: "Suchen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { [weak self, weak owner, pane] result in
            guard let self, let owner else { return }
            owner.activate(pane)
            guard result == .alertFirstButtonReturn else { return }
            do {
                let directory = try FileSystem.directory(from: root.stringValue, relativeTo: pane.directory)
                guard ArchiveFileSystem.location(for: directory) == nil else { throw self.archiveToolError }
                let query = FileSearchQuery(namePattern: name.stringValue, content: content.stringValue,
                    recursive: recursive.state == .on, includeHidden: hidden.state == .on,
                    caseSensitive: sensitive.state == .on, encoding: pane.textEncoding)
                let results = self.resultsWindow(title: "Dateien suchen", status: directory.path, panelize: true)
                results.onReveal = { [weak owner, weak pane] row in
                    guard let pane, let url = row.left else { return }
                    pane.setMode(.listing); pane.navigate(to: url.deletingLastPathComponent(), select: url); owner?.activate(pane)
                }
                results.onPanelize = { [weak owner, weak pane] urls in
                    guard let pane else { return }; pane.panelize(urls); owner?.activate(pane)
                }
                let token = results.cancellation
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try LocalInspection.search(in: directory, query: query, cancellation: token) }
                    DispatchQueue.main.async {
                        guard !token.isCancelled else { return }
                        switch result {
                        case .success(let found):
                            let rows = found.urls.map { InspectionRow(path: $0.path, status: "", left: $0, right: nil) }
                            var status = "\(rows.count) Treffer · \(found.visitedEntries) Einträge geprüft"
                            if found.resultLimitReached { status += " · Treffergrenze erreicht" }
                            if found.truncatedFiles > 0 { status += " · \(found.truncatedFiles) Dateien nur bis 1 MiB gelesen" }
                            if found.skippedFiles > 0 { status += " · \(found.skippedFiles) nicht lesbar/dekodierbar" }
                            results.setResults(rows, status: status)
                        case .failure(let error): results.setResults([], status: error.localizedDescription)
                        }
                    }
                }
            } catch { owner.showError(error) }
        }
    }

    func compareDirectories() {
        guard let owner, owner.canUseMenus, let window = owner.view.window else { return }
        guard !owner.left.isArchiveDirectory, !owner.right.isArchiveDirectory else { owner.showError(archiveToolError); return }
        let left = owner.left, right = owner.right
        let recursive = NSButton(checkboxWithTitle: "Unterordner vergleichen", target: nil, action: nil); recursive.state = .on
        let alert = NSAlert(); alert.messageText = "Ordner vergleichen"
        alert.informativeText = "\(left.directory.path)\n\(right.directory.path)"
        alert.accessoryView = recursive; alert.addButton(withTitle: "Vergleichen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self, weak owner] response in
            guard let self, let owner, response == .alertFirstButtonReturn else { return }
            let a = left.directory, b = right.directory, recurse = recursive.state == .on
            let results = self.resultsWindow(title: "Ordnervergleich", status: "\(a.path) ↔ \(b.path)")
            results.onReveal = { [weak owner] row in
                if let url = row.left { left.setMode(.listing); left.navigate(to: url.deletingLastPathComponent(), select: url) }
                if let url = row.right { right.setMode(.listing); right.navigate(to: url.deletingLastPathComponent(), select: url) }
                owner?.activate(row.left == nil ? right : left)
            }
            let token = results.cancellation
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try LocalInspection.compareDirectories(a, b, recursive: recurse, cancellation: token) }
                DispatchQueue.main.async {
                    guard !token.isCancelled else { return }
                    switch result {
                    case .success(let compared):
                        let rows = compared.differences.map { item -> InspectionRow in
                            let status: String
                            switch item.kind {
                            case .onlyLeft: status = "Nur links"
                            case .onlyRight: status = "Nur rechts"
                            case .different: status = "Inhalt verschieden"
                            case .differentType: status = "Typ verschieden"
                            case .unreadable: status = item.detail ?? "Nicht lesbar"
                            }
                            return InspectionRow(path: item.relativePath, status: status, left: item.left, right: item.right)
                        }
                        results.setResults(rows, status: rows.isEmpty ? "Identisch · \(compared.comparedFiles) Dateien byteweise verglichen" : "\(rows.count) Unterschiede · \(compared.comparedFiles) Dateien byteweise verglichen")
                    case .failure(let error): results.setResults([], status: error.localizedDescription)
                    }
                }
            }
            owner.activate(owner.active)
        }
    }

    func compareFiles() {
        guard let owner, owner.canUseMenus else { return }
        guard !owner.left.isArchiveDirectory, !owner.right.isArchiveDirectory else { owner.showError(archiveToolError); return }
        // The active selection wins; the opposite selection is the counterpart, with same-name fallback.
        let active = owner.active!, other = active === owner.left ? owner.right : owner.left
        guard let first = active.selectedEntries.first(where: { !$0.isParent && !$0.isDirectory }) else { NSSound.beep(); return }
        let second = other.selectedEntries.first(where: { !$0.isParent && !$0.isDirectory })
            ?? other.entries.first(where: { !$0.isDirectory && $0.name == first.name })
        guard let second else {
            owner.showError(NSError(domain: "PaneRook", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bitte in jedem Panel eine Datei zum Vergleichen auswählen."]))
            return
        }
        let a = active === owner.left ? first.url : second.url, b = active === owner.left ? second.url : first.url
        let result = FileComparisonWindow(left: a, right: b, leftEncoding: owner.left.textEncoding, rightEncoding: owner.right.textEncoding)
        retain(result); result.showWindow(nil); result.window?.makeKeyAndOrderFront(nil)
        let token = result.cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            let comparison = Result { try LocalInspection.compareFiles(a, b, cancellation: token) }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                switch comparison {
                case .success(let value):
                    result.finish(value.equal ? "Identischer Inhalt" : "Inhalt verschieden · erster Unterschied bei Byte \(value.firstDifferentOffset ?? 0)", detail: "\(ByteCountFormatter.string(fromByteCount: value.leftSize, countStyle: .file)) ↔ \(ByteCountFormatter.string(fromByteCount: value.rightSize, countStyle: .file))")
                case .failure(let error): result.finish("Vergleich nicht abgeschlossen", detail: error.localizedDescription)
                }
            }
        }
    }

    func directorySizes() {
        guard let owner, owner.canUseMenus else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveToolError); return }
        let pane = owner.active!
        let selected = pane.selectedEntries.filter { $0.isDirectory && !$0.isParent && !$0.isSymbolicLink }
        let directories = (selected.isEmpty ? pane.entries.filter { $0.isDirectory && !$0.isParent && !$0.isSymbolicLink } : selected).map(\.url)
        guard !directories.isEmpty else { NSSound.beep(); return }
        let results = resultsWindow(title: "Ordnergrößen", status: "\(directories.count) Ordner")
        results.onReveal = { [weak owner, weak pane] row in
            guard let pane, let url = row.left else { return }
            pane.navigate(to: url.deletingLastPathComponent(), select: url); owner?.activate(pane)
        }
        let token = results.cancellation
        DispatchQueue.global(qos: .userInitiated).async {
            var sizes: [URL: Int64] = [:]; var rows: [InspectionRow] = []
            for url in directories {
                if token.isCancelled { return }
                do {
                    let bytes = try LocalInspection.byteCount(of: url, cancellation: token)
                    sizes[url] = bytes; rows.append(InspectionRow(path: url.path, status: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), left: url, right: nil))
                } catch { rows.append(InspectionRow(path: url.path, status: error.localizedDescription, left: url, right: nil)) }
            }
            DispatchQueue.main.async {
                guard !token.isCancelled else { return }
                pane.showDirectorySizes(sizes)
                results.setResults(rows, status: "\(sizes.count) Ordner berechnet · symbolische Links nicht verfolgt")
            }
        }
    }

    func directoryTree() {
        guard let owner, owner.canUseMenus else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveToolError); return }
        owner.active.setMode(owner.active.mode == .tree ? .listing : .tree)
        owner.active.focus()
    }

    private var archiveToolError: NSError {
        NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Dieses Werkzeug benötigt lokale Dateien und Ordner. Bitte Archiveinträge zuerst in einen lokalen Ordner kopieren."])
    }
    private func retain(_ controller: NSWindowController) {
        windows.removeAll { $0.window?.isVisible == false }
        windows.append(controller)
    }
    private func resultsWindow(title: String, status: String, panelize: Bool = false) -> InspectionResultsWindow {
        let results = InspectionResultsWindow(title: title, status: status, panelize: panelize)
        retain(results); results.showWindow(nil); results.window?.makeKeyAndOrderFront(nil)
        return results
    }
}

private final class InspectionResultsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let cancellation = InspectionCancellation()
    var onReveal: ((InspectionRow) -> Void)?
    var onPanelize: (([URL]) -> Void)?
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let reveal = NSButton(title: "Im Panel zeigen", target: nil, action: nil)
    private let panelize = NSButton(title: "Ins Panel übernehmen", target: nil, action: nil)
    private let closeButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var rows: [InspectionRow] = []

    init(title: String, status: String, panelize enabled: Bool) {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title; panel.minSize = NSSize(width: 560, height: 280); panel.isReleasedWhenClosed = false
        panel.delegate = self; panel.center(); panel.contentView = AppStyle.background()
        table.delegate = self; table.dataSource = self; table.rowHeight = 25; table.style = .inset
        table.target = self; table.doubleAction = #selector(revealSelection)
        for (identifier, title, width) in [("path", "Pfad", 500.0), ("status", "Ergebnis", 235.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width
            column.minWidth = identifier == "path" ? 220 : 150; table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        self.status.stringValue = status; self.status.font = .systemFont(ofSize: 11); self.status.textColor = .secondaryLabelColor; self.status.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        reveal.target = self; reveal.action = #selector(revealSelection); reveal.isEnabled = false; reveal.keyEquivalent = "\r"
        panelize.target = self; panelize.action = #selector(panelizeResults); panelize.isEnabled = false; panelize.isHidden = !enabled
        closeButton.target = self; closeButton.action = #selector(closeResults); closeButton.keyEquivalent = "\u{1b}"
        for button in [reveal, panelize, closeButton] { AppStyle.configureButton(button) }
        let footer = NSStackView(views: [spinner, self.status, NSView(), panelize, reveal, closeButton]); footer.spacing = 8
        let root = NSStackView(views: [scroll, footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20), footer.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        panel.onCancel = { [weak self] in self?.closeResults() }
        panel.initialFirstResponder = table
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func setResults(_ rows: [InspectionRow], status: String) {
        self.rows = rows; self.status.stringValue = status; self.status.toolTip = status
        spinner.stopAnimation(nil); spinner.isHidden = true; closeButton.title = "Schließen"
        table.reloadData(); if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        panelize.isEnabled = !rows.isEmpty; reveal.isEnabled = !rows.isEmpty
    }
    @objc private func revealSelection() { guard rows.indices.contains(table.selectedRow) else { return }; onReveal?(rows[table.selectedRow]); close() }
    @objc private func panelizeResults() { onPanelize?(rows.compactMap(\.left)); close() }
    @objc private func closeResults() { cancellation.cancel(); close() }
    func windowWillClose(_ notification: Notification) { cancellation.cancel() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "status" ? rows[row].status : rows[row].path)
        field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle; field.toolTip = field.stringValue
        return field
    }
}

/// The byte comparison is exact; the side-by-side preview is separately bounded to keep the viewer responsive.
private final class FileComparisonWindow: NSWindowController, NSWindowDelegate {
    let cancellation = InspectionCancellation()
    private let status = NSTextField(labelWithString: "Dateien werden byteweise verglichen …")
    private let detail = NSTextField(labelWithString: "")
    init(left: URL, right: URL, leftEncoding: String.Encoding, rightEncoding: String.Encoding) {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Dateivergleich"; panel.minSize = NSSize(width: 650, height: 320); panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center()
        panel.contentView = AppStyle.background()
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin
        for (url, encoding) in [(left, leftEncoding), (right, rightEncoding)] {
            let label = NSTextField(labelWithString: url.path); label.font = .systemFont(ofSize: 11); label.lineBreakMode = .byTruncatingMiddle; label.toolTip = url.path
            let preview = PanelInspectionView(); preview.show(url, information: false, encoding: encoding)
            let stack = NSStackView(views: [label, preview]); stack.orientation = .vertical; stack.spacing = 6
            stack.alignment = .leading; stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            preview.widthAnchor.constraint(equalTo: label.widthAnchor).isActive = true
            split.addArrangedSubview(stack)
        }
        detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 12, weight: .medium)
        let root = NSStackView(views: [status, detail, split]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            split.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24), detail.widthAnchor.constraint(equalTo: split.widthAnchor)
        ])
        split.setPosition(488, ofDividerAt: 0)
        panel.onCancel = { [weak self] in self?.cancellation.cancel(); self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func finish(_ message: String, detail: String) { status.stringValue = message; self.detail.stringValue = detail; self.detail.toolTip = detail }
    func windowWillClose(_ notification: Notification) { cancellation.cancel() }
}
