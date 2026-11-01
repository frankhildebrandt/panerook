import AppKit
import Darwin
import PaneRookCore

enum PanelMode { case listing, quickView, info, tree, network }

final class FileTable: NSTableView {
    var handleKey: ((NSEvent) -> Bool)?
    var didFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { didFocus?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if handleKey?(event) == true || handleListNavigation(event) { return }
        super.keyDown(with: event)
    }
}

final class PaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let table = FileTable()
    let pathField = NSTextField()
    let favoritesButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let summary = NSTextField(labelWithString: "")
    private let back = NSButton()
    private let surface = PaneSurface()
    private let listing = NSScrollView()
    private let content = NSView()
    private let inspection = PanelInspectionView()
    private let tree = PanelDirectoryTree()
    private let network = NetworkBrowserView()
    private var generation = 0
    private var allEntries: [FileEntry] = []
    private var panelized = false
    private var directorySizes: [URL: Int64] = [:]
    private var inspectionURL: URL?
    private var iconsVisible = true
    private var highlights: [(pattern: String, color: NSColor)] = []
    private var summaryHeight: NSLayoutConstraint?
    private(set) var mode: PanelMode = .listing
    private(set) var filterPattern = ""
    var textEncoding: String.Encoding = .utf8 { didSet { if mode == .quickView { showInspection(of: inspectionURL) } } }
    var visitedDirectories: [URL] { Array((history + [directory]).reversed().reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }) }
    private(set) var directory: URL
    private(set) var entries: [FileEntry] = []
    var onActivate: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onError: ((Error) -> Void)?
    var onOpenSelection: (() -> Void)?
    var onDirectoryChanged: (() -> Void)?
    var onSelectionChanged: ((URL?) -> Void)?
    var showHidden = false
    var isActive = false { didSet { updateNavigation() } }
    private var history: [URL] = []
    private let label: String
    private var loading = false
    private(set) var sortKey = "name"
    private(set) var sortAscending = true

    init(label: String, directory: URL) {
        self.label = label
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func loadView() {
        view = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        ])
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Zurück")
        AppStyle.configureButton(back)
        back.isBordered = false
        back.controlSize = .small
        back.target = self
        back.action = #selector(goBack)
        back.toolTip = "Zurück"
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Übergeordneter Ordner")!, target: self, action: #selector(goUp))
        AppStyle.configureButton(up)
        up.isBordered = false
        up.controlSize = .small
        up.toolTip = "Übergeordneter Ordner · ⌘↑"

        AppStyle.configureField(pathField)
        pathField.placeholderString = "Pfad"
        pathField.toolTip = "Pfad eingeben · ⌘L"
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.delegate = self
        pathField.cell?.isScrollable = true
        pathField.setAccessibilityLabel("\(label): Ordnerpfad")

        table.delegate = self
        table.dataSource = self
        table.rowHeight = 29
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.autoresizingMask = [.width]
        table.target = self
        table.doubleAction = #selector(openFromTable)
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
        listing.documentView = table
        listing.hasVerticalScroller = true
        listing.autohidesScrollers = true
        listing.borderType = .noBorder
        for child in [listing, inspection, tree, network] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
            NSLayoutConstraint.activate([
                child.topAnchor.constraint(equalTo: content.topAnchor), child.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                child.leadingAnchor.constraint(equalTo: content.leadingAnchor), child.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        tree.onActivate = { [weak self] in self?.onActivate?() }
        tree.onKey = { [weak self] in self?.onKey?($0) ?? false }
        tree.onSelection = { [weak self] url in self?.updateSummary(); self?.onSelectionChanged?(url) }
        tree.onOpen = { [weak self] url in self?.navigate(to: url) }
        tree.onError = { [weak self] in self?.onError?($0) }
        inspection.onActivate = { [weak self] in self?.onActivate?() }
        inspection.onKey = { [weak self] in self?.onKey?($0) ?? false }
        network.onKey = { [weak self] in self?.onKey?($0) ?? false }
        network.onActivate = { [weak self] in self?.onActivate?() }
        network.onError = { [weak self] in self?.onError?($0) }
        network.onOpenDirectory = { [weak self] url in self?.setMode(.listing); self?.navigate(to: url) }
        inspection.isHidden = true; tree.isHidden = true; network.isHidden = true
        summary.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingMiddle
        AppStyle.configureButton(favoritesButton)
        favoritesButton.isBordered = false
        favoritesButton.controlSize = .small
        favoritesButton.imagePosition = .imageOnly
        favoritesButton.setAccessibilityLabel("\(label): Favoriten")
        favoritesButton.toolTip = "Favoriten · ⌥↓"
        favoritesButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let navigation = NSStackView(views: [back, up, pathField, favoritesButton])
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 6
        navigation.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        navigation.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        back.widthAnchor.constraint(equalToConstant: 24).isActive = true
        up.widthAnchor.constraint(equalToConstant: 24).isActive = true
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        for child in [navigation, content, summary] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: surface.topAnchor),
            navigation.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            navigation.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: navigation.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -1),
            content.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10),
            summary.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            summary.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
            summary.heightAnchor.constraint(equalToConstant: 16)
        ])
        updateNavigation()
        navigate(to: directory, recordHistory: false)
    }

    var selectedEntries: [FileEntry] {
        guard !loading else { return [] }
        guard mode != .quickView && mode != .info && mode != .network else { return [] }
        if mode == .tree { return tree.selectedURL.flatMap { try? LocalInspection.entry(at: $0) }.map { [$0] } ?? [] }
        return table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    var selectedFiles: [URL] { selectedEntries.filter { !$0.isParent }.map(\.url) }

    func focus() {
        if mode == .network { network.focus(); return }
        let responder: NSView = mode == .tree ? tree.outline : (mode == .listing ? table : inspection)
        view.window?.makeFirstResponder(responder)
    }

    func setMode(_ mode: PanelMode) {
        _ = view
        if self.mode == .network && mode != .network { network.stop() }
        self.mode = mode
        listing.isHidden = mode != .listing
        inspection.isHidden = mode != .quickView && mode != .info
        tree.isHidden = mode != .tree
        network.isHidden = mode != .network
        pathField.stringValue = mode == .network ? "Netzwerk" : directory.path
        if mode == .network { network.start() }
        if mode == .tree { tree.setRoot(directory, showHidden: showHidden) }
        if mode == .quickView || mode == .info { showInspection(of: inspectionURL) }
        updateSummary()
        updateNavigation()
        if isActive { focus() }
        onSelectionChanged?(selectedFiles.first)
    }

    func showInspection(of url: URL?) {
        inspectionURL = url
        guard isViewLoaded, mode == .quickView || mode == .info else { return }
        inspection.show(url, information: mode == .info, encoding: textEncoding)
        updateSummary()
    }

    func setFilter(_ pattern: String) {
        filterPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isViewLoaded else { return }
        let selected = Set(selectedFiles)
        entries = LocalInspection.filter(allEntries, pattern: filterPattern)
        applySort(); table.reloadData()
        let indexes = IndexSet(entries.indices.filter { selected.contains(entries[$0].url) })
        table.selectRowIndexes(indexes.isEmpty && !entries.isEmpty ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
        updateSummary()
    }

    func panelize(_ urls: [URL]) {
        _ = view
        generation += 1; loading = false; panelized = true
        var seen = Set<URL>()
        allEntries = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }.compactMap { try? LocalInspection.entry(at: $0) }
        allEntries.insert(.parent(of: directory), at: 0)
        setMode(.listing); setFilter(filterPattern)
        pathField.stringValue = directory.path
    }

    func showDirectorySizes(_ sizes: [URL: Int64]) {
        let selected = Set(selectedFiles)
        directorySizes.merge(sizes) { _, new in new }
        if sortKey == "size" { applySort() }
        table.reloadData()
        table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].url) }), byExtendingSelection: false)
    }

    func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool) {
        _ = view
        table.rowHeight = min(44, max(18, rowHeight)); tree.outline.rowHeight = table.rowHeight
        iconsVisible = showIcons
        summary.isHidden = !showSummary
        if summaryHeight == nil { summaryHeight = summary.constraints.first { $0.firstAttribute == .height } }
        summaryHeight?.constant = showSummary ? 16 : 0
        table.reloadData()
    }

    func applyHighlights(_ rules: [(pattern: String, color: NSColor)]) { highlights = rules; table.reloadData() }

    var isBriefListing: Bool {
        isViewLoaded && !table.tableColumns.isEmpty
            && table.tableColumns.dropFirst().allSatisfy(\.isHidden)
    }

    func setSort(key: String, ascending: Bool) {
        guard ["name", "size", "modified"].contains(key) else { return }
        _ = view
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
    }

    func setBriefListing(_ brief: Bool) {
        _ = view
        guard isBriefListing != brief else { return }
        for column in table.tableColumns.dropFirst() {
            column.isHidden = brief
        }
        // The existing first-column-only autoresizing keeps metadata column widths intact.
        table.sizeToFit()
    }

    func selectMatching(_ pattern: String, select: Bool) {
        guard isViewLoaded, !loading, !pattern.isEmpty else { return }
        let matches = IndexSet(entries.indices.filter {
            !entries[$0].isParent && fnmatch(pattern, entries[$0].name, 0) == 0
        })
        var selection = table.selectedRowIndexes
        selection.subtract(IndexSet(entries.indices.filter { entries[$0].isParent }))
        if select { selection.formUnion(matches) }
        else { selection.subtract(matches) }
        table.selectRowIndexes(selection, byExtendingSelection: false)
    }

    func invertSelection() {
        guard isViewLoaded, !loading else { return }
        let selected = table.selectedRowIndexes
        let inverted = IndexSet(entries.indices.filter {
            !entries[$0].isParent && !selected.contains($0)
        })
        table.selectRowIndexes(inverted, byExtendingSelection: false)
    }

    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil) {
        if mode == .network { setMode(.listing) }
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
                    self.panelized = false
                    self.directorySizes = [:]
                    self.allEntries = files
                    if url.path != "/" { self.allEntries.insert(.parent(of: url), at: 0) }
                    self.entries = LocalInspection.filter(self.allEntries, pattern: self.filterPattern)
                    self.applySort()
                    self.pathField.stringValue = url.path
                    self.table.reloadData()
                    // Normalize both sides: macOS listings may return /private/tmp
                    // while the entered path uses /tmp. Keep leaf symlinks distinct.
                    let desired = select.map { Set([$0.standardizedFileURL]) }
                        ?? (oldDirectory == url ? Set(preserved.map(\.standardizedFileURL)) : [])
                    let indexes = IndexSet(self.entries.indices.filter { desired.contains(self.entries[$0].url.standardizedFileURL) })
                    self.table.selectRowIndexes(indexes.isEmpty && !self.entries.isEmpty ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
                    self.updateSummary()
                    self.updateNavigation()
                    if self.mode == .tree { self.tree.setRoot(url, showHidden: self.showHidden) }
                    self.onDirectoryChanged?()
                    self.onSelectionChanged?(self.selectedFiles.first)
                case .failure(let error):
                    self.pathField.stringValue = self.directory.path
                    self.updateSummary()
                    self.onError?(error)
                }
            }
        }
    }

    func refresh(select: URL? = nil) {
        if mode == .network { network.stop(); network.start(); return }
        navigate(to: directory, recordHistory: false, select: select)
    }
    func showFavorites() { favoritesButton.performClick(nil) }
    @objc func goUp() {
        if mode == .network { setMode(.listing); return }
        navigate(to: directory.deletingLastPathComponent(), select: directory)
    }
    @objc private func goBack() {
        if mode == .network { setMode(.listing); return }
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
    @objc private func openFromTable() { onActivate?(); onOpenSelection?() }
    @objc func openSelection() {
        guard !loading, let entry = selectedEntries.first else { return }
        if entry.isDirectory { navigate(to: entry.url) }
        else if !NSWorkspace.shared.open(entry.url) {
            onError?(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Datei konnte nicht geöffnet werden."]))
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSummary(); onSelectionChanged?(selectedFiles.first) }
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
            case "size" where (directorySizes[a.url] ?? a.size) != (directorySizes[b.url] ?? b.size): order = (directorySizes[a.url] ?? a.size) < (directorySizes[b.url] ?? b.size) ? .orderedAscending : .orderedDescending
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
            if iconsVisible {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = entry.isParent ? NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil) : NSWorkspace.shared.icon(forFile: entry.url.path)
            cell.addSubview(image)
            NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 18), image.heightAnchor.constraint(equalToConstant: 18)])
            leading = 28
            }
            let name: String
            if panelized && !entry.isParent {
                let prefix = directory.path == "/" ? "/" : directory.path + "/"
                name = entry.url.path.hasPrefix(prefix) ? String(entry.url.path.dropFirst(prefix.count)) : entry.url.path
            } else { name = entry.name }
            text.stringValue = name + (entry.isSymbolicLink ? " ↗" : "")
            text.font = .systemFont(ofSize: 12, weight: entry.isDirectory ? .medium : .regular)
            if let rule = highlights.first(where: { LocalInspection.matches(entry.name, pattern: $0.pattern) }) { text.textColor = rule.color }
            if panelized && !entry.isParent { cell.toolTip = entry.url.path }
        } else if id.rawValue == "size" {
            let bytes = entry.isDirectory ? directorySizes[entry.url] : entry.size
            text.stringValue = entry.isParent ? "" : bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
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
    private func updateNavigation() {
        guard isViewLoaded else { return }
        pathField.textColor = isActive ? .labelColor : .secondaryLabelColor
        surface.isActive = isActive
        back.isEnabled = mode == .network || !history.isEmpty
    }
    private func updateSummary() {
        guard !loading else { return }
        if mode == .network { summary.stringValue = ""; return }
        if mode == .quickView || mode == .info {
            summary.stringValue = inspectionURL?.lastPathComponent ?? ""
            return
        }
        if mode == .tree { summary.stringValue = tree.selectedURL?.path ?? directory.path; return }
        let selected = selectedEntries.filter { !$0.isParent }
        let count = entries.filter { !$0.isParent }.count
        summary.stringValue = (count == 1 ? "1 Eintrag" : "\(count) Einträge")
            + (selected.isEmpty ? "" : "  ·  \(selected.count) ausgewählt")
            + (filterPattern.isEmpty ? "" : "  ·  \(filterPattern)")
            + (panelized ? "  ·  Suchergebnisse" : "")
    }
}
