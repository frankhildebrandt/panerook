import AppKit
import PaneRookRemote

final class RemoteEditWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onUpload: ((RemoteEditSession) -> Void)?
    var onOpen: ((RemoteEditSession) -> Void)?
    var onCancel: ((RemoteEditSession) -> Void)?
    var onStop: ((RemoteEditSession) -> Void)?
    private var sessions: [RemoteEditSession] = []
    private var pending = Set<ObjectIdentifier>()
    private let table = NSTableView()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let upload = NSButton(title: "Hochladen / Wiederholen", target: nil, action: nil)
    private let open = NSButton(title: "Im Editor öffnen", target: nil, action: nil)
    private let cancel = NSButton(title: "Upload abbrechen", target: nil, action: nil)
    private let stop = NSButton(title: "Beobachtung beenden …", target: nil, action: nil)
    private let root: URL

    init(root: URL) {
        self.root = root
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 470),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Remote-Arbeitskopien"; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 780, height: 390); panel.center(); panel.contentView = AppStyle.background()
        table.delegate = self; table.dataSource = self; table.style = .inset; table.rowHeight = 30
        table.setAccessibilityLabel("Offene Remote-Arbeitskopien")
        for (id, title, width) in [("file", "Serverdatei", 430.0), ("status", "Uploadstatus", 410.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let notice = NSTextField(wrappingLabelWithString: "Im Editor speichern, dann hier Hochladen wählen. Änderungen werden nach kurzer Ruhezeit erkannt. Vorherige Serverversionen bleiben als .PaneRookEdit-….backup erhalten. FTP kann bestehende Dateien nicht sicher ersetzen.")
        notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
        detail.isSelectable = true; detail.font = .systemFont(ofSize: 11); detail.maximumNumberOfLines = 6
        let folder = NSButton(title: "Arbeitskopien im Finder", target: self, action: #selector(revealFolder))
        let buttons = [(open, "remoteEdit.open", #selector(openFile)), (upload, "remoteEdit.upload", #selector(uploadFile)),
                       (cancel, "remoteEdit.cancel", #selector(cancelUpload)), (stop, "remoteEdit.stop", #selector(stopWatching)),
                       (folder, "remoteEdit.reveal", #selector(revealFolder))]
        for (button, id, action) in buttons {
            button.target = self; button.action = action; AppStyle.configureButton(button); ContextCommands.configure(button, id: id)
        }
        let footer = NSStackView(views: [folder, NSView(), open, upload]); footer.spacing = 8
        let secondary = NSStackView(views: [NSView(), stop, cancel]); secondary.spacing = 8
        let layout = NSStackView(views: [notice, scroll, detail, secondary, footer])
        layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 12
        layout.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), layout.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            layout.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), layout.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
        for view in [notice, scroll, detail, secondary, footer] { view.widthAnchor.constraint(equalTo: layout.widthAnchor, constant: -32).isActive = true }
        panel.initialFirstResponder = table
        panel.onCancel = { [weak self] in self?.close() }
        panel.configureCommands(scope: .remoteEdit) { [weak self] id in
            guard let self else { return false }
            switch id {
            case "remoteEdit.open" where self.open.isEnabled: self.openFile()
            case "remoteEdit.upload" where self.upload.isEnabled: self.uploadFile()
            case "remoteEdit.cancel" where self.cancel.isEnabled: self.cancelUpload()
            case "remoteEdit.stop" where self.stop.isEnabled: self.stopWatching()
            case "remoteEdit.reveal": self.revealFolder()
            default: return false
            }
            return true
        }
        update([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private var selected: RemoteEditSession? { sessions.indices.contains(table.selectedRow) ? sessions[table.selectedRow] : nil }
    func update(_ sessions: [RemoteEditSession], pending: Set<ObjectIdentifier> = []) {
        let selected = self.selected
        self.pending = pending
        self.sessions = sessions; table.reloadData()
        if let selected, let row = sessions.firstIndex(where: { $0 === selected }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else if !sessions.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateButtons()
    }
    private func updateButtons() {
        let status = selected?.snapshot
        let busy = selected.map { pending.contains(ObjectIdentifier($0)) || $0.snapshot.isBusy } ?? false
        open.isEnabled = selected != nil
        upload.isEnabled = !busy && (status.map { $0.hasChanges || $0.phase == .failed || $0.phase == .conflict } ?? false)
        cancel.isEnabled = busy
        stop.isEnabled = selected != nil && !busy
        if let selected, let status {
            detail.stringValue = selected.workingURL.path + "\n" + status.message
                + (status.serverArtifacts.isEmpty ? "" : "\nServerpfade: " + status.serverArtifacts.joined(separator: " · "))
            detail.toolTip = detail.stringValue
        } else {
            detail.stringValue = "Erhaltene Arbeitskopien: \(root.path)\nZum Wiederaufnehmen mit demselben Server und Benutzer verbinden und F4 auf der ursprünglichen Datei drücken. Vorhandene Kopien werden dabei nicht neu heruntergeladen. Dateien einer inzwischen gelöschten Serverdatei können über den Finder gerettet werden."
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    func numberOfRows(in tableView: NSTableView) -> Int { sessions.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sessions.indices.contains(row) else { return nil }
        let session = sessions[row]
        let status = pending.contains(ObjectIdentifier(session)) && !session.snapshot.isBusy ? "Upload wartet …" : session.snapshot.message
        let text = tableColumn?.identifier.rawValue == "status" ? status.components(separatedBy: "\n").first! : session.identity.host + session.identity.path
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = text; field.font = .systemFont(ofSize: 12)
        return field
    }
    @objc private func openFile() { if let selected { onOpen?(selected) } }
    @objc private func uploadFile() { if let selected { onUpload?(selected) } }
    @objc private func cancelUpload() { if let selected { onCancel?(selected) } }
    @objc private func stopWatching() { if let selected { onStop?(selected) } }
    @objc private func revealFolder() {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path)
        } catch { NSAlert(error: error).runModal() }
    }
}
