import AppKit
import PaneRookCore

final class FileTable: NSTableView {
    var handleKey: ((NSEvent) -> Bool)?
    var didFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) != true { super.keyDown(with: event) }
    }
}

final class PaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = FileTable()
    let pathField = NSTextField()
    private let heading = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let indicator = NSView()
    private let back = NSButton()
    private var generation = 0
    private(set) var directory: URL
    private(set) var entries: [FileEntry] = []
    var onActivate: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onError: ((Error) -> Void)?
    var onDirectoryChanged: (() -> Void)?
    var showHidden = false
    var isActive = false { didSet { updateHeading() } }
    private var history: [URL] = []
    private let label: String
    private var loading = false
    private var sortKey = "name"
    private var sortAscending = true

    init(label: String, directory: URL) {
        self.label = label
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        let titleBar = NSStackView()
        titleBar.orientation = .horizontal
        titleBar.spacing = 8
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 4
        indicator.widthAnchor.constraint(equalToConstant: 8).isActive = true
        indicator.heightAnchor.constraint(equalToConstant: 8).isActive = true
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Zurück")
        back.bezelStyle = .texturedRounded
        back.target = self
        back.action = #selector(goBack)
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Übergeordneter Ordner")!, target: self, action: #selector(goUp))
        up.bezelStyle = .texturedRounded
        titleBar.addArrangedSubview(indicator)
        titleBar.addArrangedSubview(heading)
        titleBar.addArrangedSubview(NSView())
        titleBar.addArrangedSubview(back)
        titleBar.addArrangedSubview(up)

        pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.placeholderString = "Pfad eingeben · ⌘L"
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.delegate = self
        pathField.cell?.isScrollable = true
        pathField.setAccessibilityLabel("\(label): Ordnerpfad")

        table.delegate = self
        table.dataSource = self
        table.rowHeight = 29
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.usesAlternatingRowBackgroundColors = true
        table.style = .plain
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.didFocus = { [weak self] in self?.onActivate?() }
        table.handleKey = { [weak self] event in self?.onKey?(event) ?? false }
        table.setAccessibilityLabel("\(label): Dateiliste")
        for (id, title, width) in [("name", "Name", 270.0), ("size", "Größe", 85.0), ("modified", "Geändert", 132.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 140 : width
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingMiddle
        for child in [titleBar, pathField, scroll, summary] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            titleBar.heightAnchor.constraint(equalToConstant: 26),
            pathField.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 8),
            pathField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            pathField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            pathField.heightAnchor.constraint(equalToConstant: 26),
            scroll.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            summary.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            summary.heightAnchor.constraint(equalToConstant: 16)
        ])
        updateHeading()
        navigate(to: directory, recordHistory: false)
    }

    var selectedEntries: [FileEntry] {
        guard !loading else { return [] }
        return table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    var selectedFiles: [URL] { selectedEntries.filter { !$0.isParent }.map(\.url) }

    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil) {
        generation += 1
        let request = generation
        let oldDirectory = directory
        let preserved = Set(selectedFiles)
        let hidden = showHidden
        loading = true
        summary.stringValue = "Ordner wird gelesen …"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileSystem.list(url, showHidden: hidden) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.loading = false
                switch result {
                case .success(let files):
                    if recordHistory && oldDirectory != url { self.history.append(oldDirectory) }
                    self.directory = url
                    self.entries = files
                    if url.path != "/" { self.entries.insert(.parent(of: url), at: 0) }
                    self.applySort()
                    self.pathField.stringValue = url.path
                    self.table.reloadData()
                    let desired = select.map { Set([$0]) } ?? (oldDirectory == url ? preserved : [])
                    let indexes = IndexSet(self.entries.indices.filter { desired.contains(self.entries[$0].url) })
                    self.table.selectRowIndexes(indexes.isEmpty && !self.entries.isEmpty ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
                    self.updateSummary()
                    self.updateHeading()
                    self.onDirectoryChanged?()
                case .failure(let error):
                    self.pathField.stringValue = self.directory.path
                    self.updateSummary()
                    self.onError?(error)
                }
            }
        }
    }

    func refresh(select: URL? = nil) { navigate(to: directory, recordHistory: false, select: select) }
    @objc func goUp() { navigate(to: directory.deletingLastPathComponent(), select: directory) }
    @objc private func goBack() {
        guard let previous = history.popLast() else { return }
        navigate(to: previous, recordHistory: false)
    }
    @objc private func pathEntered() {
        do {
            navigate(to: try FileSystem.directory(from: pathField.stringValue, relativeTo: directory))
            view.window?.makeFirstResponder(table)
        } catch { onError?(error) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { onActivate?() }
    @objc func openSelection() {
        guard !loading, let entry = selectedEntries.first else { return }
        if entry.isDirectory { navigate(to: entry.url) }
        else if !NSWorkspace.shared.open(entry.url) {
            onError?(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Datei konnte nicht geöffnet werden."]))
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSummary() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = table.sortDescriptors.first else { return }
        let selected = Set(selectedFiles)
        sortKey = descriptor.key ?? "name"
        sortAscending = descriptor.ascending
        applySort()
        table.reloadData()
        table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].url) }), byExtendingSelection: false)
    }
    private func applySort() {
        entries.sort { a, b in
            if a.isParent != b.isParent { return a.isParent }
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch sortKey {
            case "size" where a.size != b.size: order = a.size < b.size ? .orderedAscending : .orderedDescending
            case "modified" where a.modified != b.modified: order = (a.modified ?? .distantPast) < (b.modified ?? .distantPast) ? .orderedAscending : .orderedDescending
            default: order = a.name.localizedStandardCompare(b.name)
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = tableColumn!.identifier
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading: CGFloat = 2
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = entry.isParent ? NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil) : NSWorkspace.shared.icon(forFile: entry.url.path)
            cell.addSubview(image)
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18)])
            leading = 28
            text.stringValue = entry.name + (entry.isSymbolicLink ? " ↗" : "")
            text.font = .systemFont(ofSize: 12, weight: entry.isDirectory ? .medium : .regular)
        } else if id.rawValue == "size" {
            text.stringValue = entry.isParent ? "" : entry.isDirectory ? "Ordner" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            text.textColor = .secondaryLabelColor
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            text.stringValue = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
            text.textColor = .secondaryLabelColor
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yy HH:mm"
        return formatter
    }()
    private func updateHeading() {
        guard isViewLoaded else { return }
        heading.stringValue = "\(label.uppercased())  ·  \(directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent)"
        indicator.layer?.backgroundColor = (isActive ? NSColor.controlAccentColor : .tertiaryLabelColor).cgColor
        heading.textColor = isActive ? .labelColor : .secondaryLabelColor
        back.isEnabled = !history.isEmpty
    }
    private func updateSummary() {
        guard !loading else { return }
        let selected = selectedEntries.filter { !$0.isParent }
        let count = entries.filter { !$0.isParent }.count
        summary.stringValue = "\(count) Einträge" + (selected.isEmpty ? "" : "  ·  \(selected.count) ausgewählt") + (showHidden ? "  ·  inkl. versteckte" : "")
    }
}
