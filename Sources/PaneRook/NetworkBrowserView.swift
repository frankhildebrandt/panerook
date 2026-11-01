import AppKit
import NetFS

private final class NetworkTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onActivate?() }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true || handleListNavigation(event) { return }
        super.keyDown(with: event)
    }
}

/// Public Bonjour discovery and NetFS mounting. NetFS owns authentication and
/// share selection; PaneRook receives only the mounted filesystem path.
final class NetworkBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    var onOpenDirectory: ((URL) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onActivate: (() -> Void)?
    var onError: ((Error) -> Void)?

    private struct Row {
        let id: String
        let name: String
        let kind: String
        let service: NetService?
        let volume: URL?
    }
    private let table = NetworkTable()
    private let empty = NSTextField(labelWithString: "Keine Dateiserver gefunden")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton(title: "Mit Server verbinden …", target: nil, action: nil)
    private let refreshButton = NSButton()
    private let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var volumes: [Row] = []
    private var rows: [Row] = []
    private var observers: [NSObjectProtocol] = []
    private var active = false
    private var generation = 0
    private var operationGeneration = 0
    private var resolving: NetService?
    private var mountRequest: AsyncRequestID?
    private var mounting = false
    private var busy: Bool { resolving != nil || mounting }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        table.dataSource = self; table.delegate = self
        table.style = .inset; table.rowHeight = 30
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(openSelection)
        table.setAccessibilityLabel("Netzwerkserver")
        table.onActivate = { [weak self] in self?.onActivate?() }
        table.onKey = { [weak self] in self?.handleKey($0) ?? false }
        for (id, title, width) in [("name", "Name", 310.0), ("kind", "Art", 110.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title; column.width = width; column.minWidth = id == "name" ? 140 : 85
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = NSView(); scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: content.centerXAnchor), empty.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        connectButton.target = self; connectButton.action = #selector(connectToServer)
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Netzwerk aktualisieren")
        refreshButton.target = self; refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Netzwerk aktualisieren"
        cancelButton.target = self; cancelButton.action = #selector(cancelPending)
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        for button in [connectButton, refreshButton, cancelButton] {
            AppStyle.configureButton(button); button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        cancelButton.isHidden = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        let footer = NSStackView(views: [connectButton, refreshButton, spinner, status, NSView(), cancelButton])
        footer.spacing = 6
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let root = NSStackView(views: [content, footer]); root.orientation = .vertical
        root.alignment = .leading; root.spacing = 2
        root.translatesAutoresizingMaskIntoConstraints = false; addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor), root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor), root.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.widthAnchor.constraint(equalTo: root.widthAnchor), footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.loadMountedVolumes() })
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        browsers.forEach { $0.stop() }
        resolving?.stop()
        if let mountRequest { NetFSMountURLCancel(mountRequest) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    func start() {
        guard !active else { return }
        active = true; generation += 1
        services = [:]; volumes = []; rebuildRows()
        status.stringValue = "Suche läuft"
        for type in ["_smb._tcp.", "_afpovertcp._tcp."] {
            let browser = NetServiceBrowser(); browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        loadMountedVolumes()
    }
    func stop() {
        active = false; generation += 1
        cancelPending()
        browsers.forEach { $0.delegate = nil; $0.stop() }
        browsers = []
    }
    func focus() { window?.makeFirstResponder(table) }
    @objc private func refresh() {
        guard active, !busy else { return }
        onActivate?(); stop(); start(); focus()
    }

    private func loadMountedVolumes() {
        guard active else { return }
        let request = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeNameKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
            let mounted = urls.compactMap { url -> Row? in
                guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsLocal == false else { return nil }
                return Row(id: "volume:" + url.standardizedFileURL.path, name: values.volumeName ?? url.lastPathComponent,
                           kind: "Freigabe", service: nil, volume: url)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == request else { return }
                self.volumes = mounted; self.rebuildRows()
            }
        }
    }
    private func serviceID(_ service: NetService) -> String { service.domain + "|" + service.type + "|" + service.name }
    private func rebuildRows() {
        let previous = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil
        rows = volumes + services.map { key, service in
            Row(id: key, name: service.name, kind: service.type.hasPrefix("_smb.") ? "SMB" : "AFP", service: service, volume: nil)
        }
        rows.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.kind < $1.kind : order == .orderedAscending
        }
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == previous }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        empty.isHidden = !rows.isEmpty
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard active, browsers.contains(where: { $0 === browser }) else { return }
        services[serviceID(service)] = service
        if !moreComing { rebuildRows() }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard active, browsers.contains(where: { $0 === browser }) else { return }
        services.removeValue(forKey: serviceID(service))
        if !moreComing { rebuildRows() }
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard active, browsers.contains(where: { $0 === browser }) else { return }
        status.stringValue = "Netzwerksuche nicht verfügbar"
        status.toolTip = "Bitte den lokalen Netzwerkzugriff für PaneRook in den Systemeinstellungen prüfen. Fehler: \(errorDict)"
    }

    @objc private func openSelection() {
        guard active, !busy, rows.indices.contains(table.selectedRow), window?.attachedSheet == nil else { return }
        onActivate?()
        let row = rows[table.selectedRow]
        if let volume = row.volume { onOpenDirectory?(volume); return }
        guard let service = row.service else { return }
        operationGeneration += 1
        resolving = service; service.delegate = self
        setBusy("Server wird aufgelöst …")
        service.resolve(withTimeout: 8)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard active, resolving === sender else { return }
        guard let host = sender.hostName, !host.isEmpty, sender.port > 0 else {
            finishResolution(); report("Die Serveradresse konnte nicht ermittelt werden."); return
        }
        var components = URLComponents()
        components.scheme = sender.type.hasPrefix("_smb.") ? "smb" : "afp"
        components.host = host; components.port = sender.port; components.path = "/"
        finishResolution()
        guard let url = components.url else { report("Die Serveradresse ist ungültig."); return }
        mount(url)
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard active, resolving === sender else { return }
        finishResolution(); report("Die Serveradresse konnte nicht aufgelöst werden.")
    }
    private func finishResolution() {
        resolving?.delegate = nil; resolving?.stop(); resolving = nil
        updateControls()
    }

    @objc private func connectToServer() {
        guard active, !busy, let window, window.attachedSheet == nil else { return }
        onActivate?()
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        AppStyle.configureField(input); input.stringValue = "smb://"
        input.setAccessibilityLabel("Serveradresse"); input.placeholderString = "smb://server/Freigabe"
        let alert = NSAlert(); alert.messageText = "Mit Server verbinden"
        alert.accessoryView = input; alert.addButton(withTitle: "Verbinden"); alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts(); alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.active else { return }
            self.focus()
            guard response == .alertFirstButtonReturn else { return }
            do { self.mount(try Self.serverURL(input.stringValue)) }
            catch { self.report(error.localizedDescription) }
        }
    }
    /// Credentials are collected by macOS's authentication agent, not this field.
    static func serverURL(_ address: String) throws -> URL {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["smb", "afp"].contains(scheme),
              let host = components.host, !host.isEmpty, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else {
            throw NSError(domain: "PaneRook.Network", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bitte eine smb://- oder afp://-Adresse ohne Passwort eingeben."])
        }
        return url
    }
    private func mount(_ url: URL) {
        guard active, !busy else { return }
        operationGeneration += 1; let request = operationGeneration
        mounting = true; setBusy("Freigabe wird verbunden …")
        let openOptions = NSMutableDictionary(dictionary: [kNAUIOptionKey: kNAUIOptionAllowUI])
        let mountOptions = NSMutableDictionary(dictionary: [kNetFSAllowSubMountsKey: true])
        var identifier: AsyncRequestID?
        let result = NetFSMountURLAsync(url as CFURL, nil, nil, nil,
            openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary,
            &identifier, .main) { [weak self] result, _, mountpoints in
                guard let self, self.active, self.operationGeneration == request else { return }
                self.mountRequest = nil; self.mounting = false; self.updateControls()
                if result == -128 { self.status.stringValue = ""; return }
                guard result == 0 else { self.mountError(result); return }
                let paths = (mountpoints as? [String]) ?? []
                guard let path = paths.first else { self.report("Die Freigabe wurde ohne erreichbaren Mountpunkt verbunden."); return }
                self.status.stringValue = ""
                self.onOpenDirectory?(URL(fileURLWithPath: path, isDirectory: true))
            }
        if result == 0 { mountRequest = identifier }
        else { mounting = false; updateControls(); mountError(result) }
    }
    private func mountError(_ code: Int32) {
        if code == -128 { status.stringValue = ""; return }
        let error = NSError(domain: code > 0 ? NSPOSIXErrorDomain : NSOSStatusErrorDomain, code: Int(code))
        status.stringValue = error.localizedDescription; status.toolTip = error.localizedDescription
        onError?(error)
    }
    @objc private func cancelPending() {
        operationGeneration += 1
        finishResolution()
        if let mountRequest { NetFSMountURLCancel(mountRequest) }
        mountRequest = nil; mounting = false; updateControls()
        status.stringValue = ""
    }
    private func setBusy(_ text: String) { status.stringValue = text; updateControls() }
    private func updateControls() {
        // Keep the table as a keyboard responder while a request is running, so
        // Escape/Ctrl-G and panel switching continue to reach this view.
        connectButton.isEnabled = !busy; refreshButton.isEnabled = !busy
        cancelButton.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
    private func report(_ message: String) {
        status.stringValue = message; status.toolTip = message
        onError?(NSError(domain: "PaneRook.Network", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if busy, (((event.keyCode == 53 || event.keyCode == 109) && flags.isEmpty) || (event.keyCode == 5 && flags == .control)) {
            cancelPending(); return true
        }
        if flags.isEmpty && (event.keyCode == 36 || event.keyCode == 76) { openSelection(); return true }
        return onKey?(event) ?? false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let field = NSTextField(labelWithString: tableColumn?.identifier.rawValue == "kind" ? item.kind : item.name)
        field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = item.volume?.path ?? item.service?.name
        return field
    }
}
