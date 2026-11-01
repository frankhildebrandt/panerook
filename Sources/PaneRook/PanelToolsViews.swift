import AppKit
import Quartz
import UniformTypeIdentifiers
import PaneRookCore

private final class InspectionText: NSTextView {
    var onKey: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder(); if result { onActivate?() }; return result
    }
}

/// Native inline inspector. Text is decoded explicitly; Quick Look handles images, PDFs and other documents.
final class PanelInspectionView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    private let text = InspectionText()
    private let scroll = NSScrollView()
    private var preview: QLPreviewView?
    private var generation = 0
    private var eventMonitor: Any?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onActivate?(); return true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); onActivate?() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        text.isEditable = false; text.isRichText = false
        text.drawsBackground = false; text.textColor = .labelColor
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        text.onKey = { [weak self] in self?.onKey?($0) ?? false }
        text.onActivate = { [weak self] in self?.onActivate?() }
        scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        install(scroll)
        // Quick Look embeds its own responders. Keep pane activation and MC keys working
        // when one of those responders, rather than our text view, receives the event.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else { return event }
            if event.type == .leftMouseDown {
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onActivate?() }
            } else if let responder = window.firstResponder as? NSView, responder === self || responder.isDescendant(of: self) {
                if self.onKey?(event) == true { return nil }
            }
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }; preview?.close() }

    private func install(_ child: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor), child.bottomAnchor.constraint(equalTo: bottomAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor), child.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    func show(_ url: URL?, information: Bool, encoding: String.Encoding) {
        generation += 1; let request = generation
        preview?.previewItem = nil; preview?.removeFromSuperview(); preview?.close(); preview = nil
        scroll.isHidden = false
        guard let url else { text.string = "Keine Datei ausgewählt"; return }
        text.string = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<String?, Error> = Result {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isReadableKey, .isWritableKey, .contentTypeKey])
                if information || values.isDirectory == true {
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    let type = values.isSymbolicLink == true ? "Symbolischer Link" : (values.isDirectory == true ? "Ordner" : "Datei")
                    var lines = [url.lastPathComponent, "", "Pfad\t\(url.path)", "Typ\t\(type)", "Größe\t\(ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file))"]
                    if let date = values.contentModificationDate { lines.append("Geändert\t\(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium))") }
                    if let date = values.creationDate { lines.append("Erstellt\t\(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium))") }
                    if let permissions = attributes[.posixPermissions] as? NSNumber { lines.append("Rechte\t\(String(permissions.intValue, radix: 8))") }
                    if let owner = attributes[.ownerAccountName] as? String { lines.append("Eigentümer\t\(owner)") }
                    if let group = attributes[.groupOwnerAccountName] as? String { lines.append("Gruppe\t\(group)") }
                    if values.isSymbolicLink == true, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) { lines.append("Ziel\t\(target)") }
                    lines.append("Zugriff\t\(values.isReadable == true ? "Lesen" : "–") · \(values.isWritable == true ? "Schreiben" : "–")")
                    return lines.joined(separator: "\n")
                }
                guard values.isRegularFile == true else { return nil }
                if let type = values.contentType, type.conforms(to: .image) || type.conforms(to: .pdf) || type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .archive) { return nil }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                // NULs identify common binary formats before an arbitrary legacy encoding can decode them.
                let unicodeWithNULs = encoding == .utf16 || encoding == .utf16LittleEndian || encoding == .utf16BigEndian || encoding == .utf32 || encoding == .utf32LittleEndian || encoding == .utf32BigEndian
                if !unicodeWithNULs && data.contains(0) { return nil }
                guard let decoded = String(data: data, encoding: encoding) else { return nil }
                let suffix = (values.fileSize ?? 0) > data.count ? "\n\n… Vorschau auf 1 MiB begrenzt." : ""
                return decoded + suffix
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                switch result {
                case .success(let value?): self.text.string = value
                case .success(nil):
                    if let preview = QLPreviewView(frame: self.bounds, style: .compact) {
                        preview.autostarts = false
                        preview.shouldCloseWithWindow = false
                        self.preview = preview; self.install(preview); preview.previewItem = url as NSURL
                        self.scroll.isHidden = true
                    } else { self.text.string = "Keine Vorschau verfügbar." }
                case .failure(let error): self.text.string = error.localizedDescription
                }
            }
        }
    }
}

private final class DirectoryOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if accepted { onActivate?() }; return accepted }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true || handleListNavigation(event) { return }
        super.keyDown(with: event)
    }
}

/// Loads only one directory level per expansion; symlink directories remain leaves.
final class PanelDirectoryTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node {
        let url: URL?
        let name: String
        let expandable: Bool
        var children: [Node]?
        var loading = false
        lazy var placeholder = Node(url: nil, name: "…", expandable: false)
        init(url: URL?, name: String, expandable: Bool) { self.url = url; self.name = name; self.expandable = expandable }
    }
    private let tree = DirectoryOutline()
    var outline: NSOutlineView { tree }
    private var root: Node?
    private var generation = 0
    private var hiddenFiles = false
    var onActivate: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onSelection: ((URL?) -> Void)?
    var onOpen: ((URL) -> Void)?
    var onError: ((Error) -> Void)?
    var selectedURL: URL? { (tree.item(atRow: tree.selectedRow) as? Node)?.url }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("directory"))
        column.title = "Ordner"; column.minWidth = 120
        tree.addTableColumn(column); tree.outlineTableColumn = column
        tree.delegate = self; tree.dataSource = self; tree.headerView = nil
        tree.rowHeight = 29; tree.style = .inset
        tree.target = self; tree.doubleAction = #selector(open)
        tree.onKey = { [weak self] in self?.onKey?($0) ?? false }
        tree.onActivate = { [weak self] in self?.onActivate?() }
        tree.setAccessibilityLabel("Verzeichnisbaum")
        let scroll = NSScrollView(); scroll.documentView = tree
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false; addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func setRoot(_ url: URL, showHidden: Bool) {
        guard root?.url != url || hiddenFiles != showHidden else { return }
        generation += 1; hiddenFiles = showHidden
        root = Node(url: url, name: url.path, expandable: true)
        tree.reloadData()
        tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        tree.expandItem(root)
    }
    private func load(_ node: Node) {
        guard let url = node.url, node.expandable, !node.loading, node.children == nil else { return }
        node.loading = true
        let request = generation, showHidden = hiddenFiles
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try FileSystem.list(url, showHidden: showHidden).filter(\.isDirectory) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                node.loading = false
                switch result {
                case .success(let entries): node.children = entries.map { Node(url: $0.url, name: $0.name + ($0.isSymbolicLink ? " ↗" : ""), expandable: !$0.isSymbolicLink) }
                case .failure(let error): node.children = []; self.onError?(error)
                }
                self.tree.reloadItem(node, reloadChildren: true)
                self.tree.expandItem(node)
            }
        }
    }
    @objc private func open() { if let url = selectedURL { onOpen?(url) } }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? Node else { return root == nil ? 0 : 1 }
        if node.children == nil { load(node); return node.expandable ? 1 : 0 }
        return node.children!.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return root! }
        return node.children?[index] ?? node.placeholder
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.expandable == true }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.url != nil }
    func outlineViewSelectionDidChange(_ notification: Notification) { onSelection?(selectedURL) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = NSTableCellView(); let text = NSTextField(labelWithString: node.name)
        text.font = .systemFont(ofSize: 12); text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
        cell.toolTip = node.url?.path
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
