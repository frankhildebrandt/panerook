import AppKit

/// File menus use the same policies as the menu bar and keyboard. A menu captures
/// its context so a late click never acts on another panel or a refreshed selection.
final class FileContextActions {
    private unowned let owner: CommanderController
    private var information: FileInformationWindow?

    init(owner: CommanderController) { self.owner = owner }

    func registerCommands(in registry: CommandRegistry) {
        registry.add(.file, "Pfad kopieren", id: "files.copyPath", order: 54,
            enabled: { self.owner.canUseMenus && !Self.paths(in: self.owner.active).isEmpty }) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.paths(in: self.owner.active).joined(separator: "\n"), forType: .string)
            }
        registry.add(.file, "Informationen", id: "files.info", order: 55, key: "i",
            enabled: { self.owner.canUseMenus && Self.details(in: self.owner.active) != nil }) {
                guard let details = Self.details(in: self.owner.active) else { return }
                self.information?.close()
                let window = FileInformationWindow(details: details)
                self.information = window
                window.showWindow(nil)
                window.window?.makeKeyAndOrderFront(nil)
            }
    }

    func menu(for pane: PaneController) -> NSMenu? {
        guard pane === owner.left || pane === owner.right else { return nil }
        owner.activate(pane)
        guard owner.canUseMenus, !Self.paths(in: pane).isEmpty else { return nil }
        let identity = Self.identity(in: pane)
        let menu = FileContextMenu { [weak owner, weak pane] in
            guard let owner, let pane else { return false }
            return owner.active === pane && (pane === owner.left || pane === owner.right)
                && owner.canUseMenus && Self.identity(in: pane) == identity
        }
        let groups: [[(String, String)]] = [
            [("preview.open", "Öffnen"), ("preview", "Vorschau"), ("edit", "Bearbeiten")],
            [("files.rename", "Umbenennen …"), ("copy", "In anderes Panel kopieren …"),
             ("move", "In anderes Panel verschieben …")],
            [("files.clipboard.copy", "Kopieren"), ("files.copyPath", "Pfad kopieren"), ("files.info", "Informationen")],
            [("trash", pane.remoteContent != nil || pane.isArchiveDirectory ? "Endgültig löschen …" : "In den Papierkorb")]
        ]
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for (id, title) in group {
                guard let command = owner.commandRegistry[id] else { continue }
                menu.add(command, title: title, binding: owner.commandRegistry.bindings[id])
            }
        }
        return menu
    }

    private static func identity(in pane: PaneController) -> [String] {
        if let remote = pane.remoteContent as? RemoteBrowser {
            return [String(describing: ObjectIdentifier(remote)), remote.directory] + paths(in: pane)
        }
        return [pane.directory.path, String(describing: pane.mode)] + paths(in: pane)
    }

    static func paths(in pane: PaneController) -> [String] {
        if let remote = pane.remoteContent as? RemoteBrowser {
            guard !remote.isBusy, !remote.disconnected else { return [] }
            return remote.selection.map { (remote.directory as NSString).appendingPathComponent($0.name) }
        }
        guard pane.remoteContent == nil, pane.mode == .listing || pane.mode == .tree else { return [] }
        return pane.selectedFiles.map(\.path)
    }

    private static func details(in pane: PaneController) -> [(String, String)]? {
        let name: String, path: String, kind: String, size: Int64, modified: Date?
        var connection: String?
        if let remote = pane.remoteContent as? RemoteBrowser {
            guard !remote.isBusy, !remote.disconnected, remote.selection.count == 1, let entry = remote.selection.first else { return nil }
            name = entry.name; path = (remote.directory as NSString).appendingPathComponent(name)
            kind = entry.isSymbolicLink ? "Symbolischer Link" : entry.isDirectory ? "Ordner" : "Datei"
            size = entry.size; modified = entry.modified; connection = remote.displayName
        } else {
            guard pane.remoteContent == nil, paths(in: pane).count == 1,
                  let entry = pane.selectedEntries.first(where: { !$0.isParent }) else { return nil }
            name = entry.name; path = entry.url.path
            kind = entry.isSymbolicLink ? "Symbolischer Link" : entry.isDirectory ? "Ordner" : "Datei"
            size = entry.size; modified = entry.modified
        }
        var rows = [("Name", name), ("Pfad", path), ("Art", kind)]
        if let connection { rows.append(("Verbindung", connection)) }
        if kind != "Ordner" { rows.append(("Größe", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) }
        rows.append(("Geändert", modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Unbekannt"))
        return rows
    }
}

final class FileContextMenu: NSMenu, NSMenuDelegate, NSMenuItemValidation {
    private static weak var activeMenu: FileContextMenu?
    static var isTracking: Bool { activeMenu != nil }
    static func cancelActiveTracking() { activeMenu?.cancelTrackingWithoutAnimation() }
    private let contextIsCurrent: () -> Bool

    init(contextIsCurrent: @escaping () -> Bool) {
        self.contextIsCurrent = contextIsCurrent
        super.init(title: "Datei")
        delegate = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func add(_ command: AppCommand, title: String, binding: AppKeyBinding?) {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.identifier = .init(command.id)
        item.target = self
        item.representedObject = command
        item.toolTip = binding.map { title + " · " + $0.label }
        item.isEnabled = contextIsCurrent() && command.enabled()
        addItem(item)
    }
    @objc func performCommand(_ sender: NSMenuItem) {
        guard contextIsCurrent(), let command = sender.representedObject as? AppCommand else { return }
        command.perform()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        contextIsCurrent() && (menuItem.representedObject as? AppCommand)?.enabled() == true
    }
    func menuWillOpen(_ menu: NSMenu) { Self.activeMenu = self }
    func menuDidClose(_ menu: NSMenu) { if Self.activeMenu === self { Self.activeMenu = nil } }
}

private final class FileInformationWindow: NSWindowController {
    init(details: [(String, String)]) {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 350),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Informationen · " + (details.first?.1 ?? "Datei")
        panel.minSize = NSSize(width: 400, height: 300)
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = AppStyle.background()
        let rows = details.map { key, value -> [NSView] in
            let label = NSTextField(labelWithString: key)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(wrappingLabelWithString: value)
            value.isSelectable = true
            return [label, value]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14; grid.columnSpacing = 16
        grid.column(at: 0).width = 85
        grid.xPlacement = .fill; grid.yPlacement = .top
        grid.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -20)
        ])
        panel.onCancel = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}
