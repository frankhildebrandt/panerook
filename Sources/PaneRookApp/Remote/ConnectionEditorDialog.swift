import PaneRookRemote
import AppKit
import PaneRookCore

/// The same fields serve an ad-hoc connection and the bookmark editor. Passwords
/// are only shown for FTP/Nextcloud connections and never enter a bookmark.
final class ConnectionEditorDialog: NSWindowController {
    enum Purpose { case connection, bookmark }
    enum Outcome {
        case connect(RemoteConnection, path: String)
        case saved(ConnectionBookmark)
        case archive
    }
    private let purpose: Purpose
    private let bookmarks: [ConnectionBookmark]
    private let saveBookmark: (ConnectionBookmark) throws -> Void
    private let completion: (Outcome?) -> Void
    private let protocols: [RemoteProtocol] = RemoteProtocol.available
    private var kind: RemoteProtocol
    private var bookmarkID: UUID?
    private var outcome: Outcome?
    private let preset = NSPopUpButton()
    private let protocolPicker = NSPopUpButton()
    private let name = NSTextField()
    private let host = NSTextField()
    private let port = NSTextField()
    private let user = NSTextField()
    private let path = NSTextField()
    private let identity = NSTextField()
    private let password = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "Im Archiv speichern", target: nil, action: nil)
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var nameRow: NSView!
    private var identityRow: NSView!
    private var passwordRow: NSView!
    private var passwordLabel: NSTextField!
    private var focusPassword = false

    init(kind: RemoteProtocol, bookmark: ConnectionBookmark? = nil, bookmarks: [ConnectionBookmark] = [],
         purpose: Purpose, archiveError: String? = nil, allowsArchive: Bool = false,
         saveBookmark: @escaping (ConnectionBookmark) throws -> Void, completion: @escaping (Outcome?) -> Void) {
        self.kind = bookmark?.kind ?? kind
        self.purpose = purpose
        self.bookmarks = bookmarks.filter { $0.kind == kind }
        self.bookmarkID = bookmark?.id
        self.saveBookmark = saveBookmark
        self.completion = completion
        focusPassword = purpose == .connection && (bookmark?.kind.provider.usesPassword == true)
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.cancel(nil) }
        panel.contentView = AppStyle.background(material: .sheet)
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        func row(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 110).isActive = true
            control.setAccessibilityLabel(title)
            let row = NSStackView(views: [label, control]); row.spacing = 10
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(row)
            return row
        }
        if purpose == .connection {
            preset.addItem(withTitle: "Neue Verbindung")
            preset.addItems(withTitles: self.bookmarks.map { "\($0.name) · \(Self.address($0))" })
            preset.target = self; preset.action = #selector(presetChanged)
            row("Gespeichert", preset).isHidden = self.bookmarks.isEmpty
        } else {
            protocolPicker.addItems(withTitles: protocols.map(Self.title))
            protocolPicker.target = self; protocolPicker.action = #selector(protocolChanged)
            _ = row("Protokoll", protocolPicker)
        }
        nameRow = row("Name", name)
        _ = row("Server", host)
        _ = row("Port", port)
        _ = row("Benutzer", user)
        passwordRow = row("Passwort", password)
        passwordLabel = (passwordRow as? NSStackView)?.arrangedSubviews.first as? NSTextField
        identityRow = row("Schlüsseldatei", identity)
        identity.placeholderString = "SSH-Agent / ~/.ssh/config"
        identity.toolTip = "Optionaler Pfad zum privaten SSH-Schlüssel. Der Schlüsselinhalt wird nicht gespeichert."
        _ = row("Startpfad", path)
        if purpose == .connection {
            remember.target = self; remember.action = #selector(rememberChanged)
            remember.toolTip = "Speichert die Verbindungsdaten ohne Passwort."
            stack.addArrangedSubview(remember)
        }
        notice.font = .systemFont(ofSize: 11); notice.textColor = .secondaryLabelColor
        stack.addArrangedSubview(notice)
        errorLabel.font = .systemFont(ofSize: 12); errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityLabel("Fehler bei der Verbindung")
        errorLabel.isHidden = archiveError == nil
        errorLabel.stringValue = archiveError ?? ""
        stack.addArrangedSubview(errorLabel)
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel(_:)))
        let submit = NSButton(title: purpose == .connection ? "Verbinden" : "Speichern", target: self, action: #selector(confirm(_:)))
        for button in [cancel, submit] { AppStyle.configureButton(button) }
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        submit.keyEquivalent = "\r"; submit.keyEquivalentModifierMask = []
        let buttons = NSStackView(); buttons.spacing = 10
        var keyViews: [NSView] = purpose == .connection ? [preset] : [protocolPicker]
        keyViews += [name, host, port, user, password, identity, path]
        if purpose == .connection { keyViews.append(remember) }
        if allowsArchive {
            let archive = NSButton(title: "Archiv …", target: self, action: #selector(openArchive))
            AppStyle.configureButton(archive); buttons.addArrangedSubview(archive); keyViews.append(archive)
        }
        buttons.addArrangedSubview(NSView()); buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(submit)
        keyViews += [cancel, submit]
        for index in keyViews.indices { keyViews[index].nextKeyView = keyViews[(index + 1) % keyViews.count] }
        stack.addArrangedSubview(buttons)
        for field in [name, host, port, user, path, identity, password] {
            AppStyle.configureField(field)
            field.cell?.isScrollable = true
            field.cell?.sendsActionOnEndEditing = false
            field.target = self; field.action = #selector(confirm(_:))
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 27).isActive = true
        }
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 530)
        ])
        fill(bookmark)
        panel.initialFirstResponder = purpose == .bookmark ? name : (focusPassword ? password : host)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    static func title(_ kind: RemoteProtocol) -> String { kind.provider.title }
    static func address(_ bookmark: ConnectionBookmark) -> String {
        (try? bookmark.connection())?.displayName ?? bookmark.host
    }
    private static func defaultPort(_ kind: RemoteProtocol) -> Int { kind.provider.defaultPort }
    private var usesPassword: Bool { kind.provider.usesPassword }
    private func fill(_ bookmark: ConnectionBookmark?) {
        bookmarkID = bookmark?.id
        if let bookmark { kind = bookmark.kind }
        protocolPicker.selectItem(at: protocols.firstIndex(of: kind) ?? 0)
        name.stringValue = bookmark?.name ?? ""
        host.stringValue = bookmark?.host ?? ""
        port.stringValue = String(bookmark?.port ?? Self.defaultPort(kind))
        user.stringValue = bookmark?.user ?? NSUserName()
        path.stringValue = bookmark?.path ?? "/"
        identity.stringValue = bookmark?.identityFile ?? ""
        password.stringValue = ""
        remember.state = .off
        if let bookmark, let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { preset.selectItem(at: index + 1) }
        updateForm()
    }
    private func updateForm() {
        window?.title = purpose == .bookmark ? (bookmarkID == nil ? "Verbindung speichern" : "Verbindung bearbeiten") : Self.title(kind) + "-Verbindung"
        nameRow.isHidden = purpose == .connection && remember.state != .on
        passwordRow.isHidden = purpose != .connection || !usesPassword
        identityRow.isHidden = usesPassword
        let provider = kind.provider
        host.placeholderString = provider.hostPlaceholder
        host.toolTip = provider.hostHint
        passwordLabel.stringValue = provider.passwordLabel
        password.setAccessibilityLabel(provider.passwordAccessibilityLabel)
        password.toolTip = provider.passwordHint
        path.toolTip = provider.pathHint
        notice.stringValue = provider.notice
        resize()
    }
    private func resize() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded(); window.setContentSize(content.fittingSize)
    }
    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in
            password.stringValue = ""
            completion(outcome)
        }
        let first: NSTextField = purpose == .bookmark ? name : (focusPassword ? password : host)
        first.selectText(nil)
    }
    @objc private func presetChanged() {
        let index = preset.indexOfSelectedItem - 1
        fill(bookmarks.indices.contains(index) ? bookmarks[index] : nil)
        errorLabel.isHidden = true; resize()
        if purpose == .connection && usesPassword && index >= 0 { password.selectText(nil) }
    }
    @objc private func protocolChanged() {
        let next = protocols[protocolPicker.indexOfSelectedItem]
        if port.stringValue == String(Self.defaultPort(kind)) { port.stringValue = String(Self.defaultPort(next)) }
        kind = next; password.stringValue = ""; updateForm()
    }
    @objc private func rememberChanged() {
        if remember.state == .on && name.stringValue.isEmpty { name.stringValue = host.stringValue }
        updateForm()
    }
    @objc private func confirm(_ sender: Any?) {
        if sender is NSTextField {
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return }
        }
        guard outcome == nil else { return }
        do {
            let connection = try RemoteConnection(kind: kind, host: host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                port: Int(port.stringValue) ?? 0, user: user.stringValue, password: purpose == .connection && usesPassword ? password.stringValue : "",
                identityFile: usesPassword ? "" : identity.stringValue,
                timeout: UserDefaults.standard.object(forKey: "remoteTimeout") as? Int ?? 20)
            let directory = try RemoteFileSystem.normalizedPath(path.stringValue)
            var bookmark: ConnectionBookmark?
            if purpose == .bookmark || remember.state == .on {
                bookmark = try ConnectionBookmark(id: bookmarkID ?? UUID(), name: name.stringValue, kind: kind, host: connection.host,
                    port: connection.port, user: connection.user, path: directory, identityFile: connection.identityFile)
                try saveBookmark(bookmark!)
            }
            outcome = purpose == .connection ? .connect(connection, path: directory) : .saved(bookmark!)
            finish(.OK)
        } catch { errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false; resize(); NSSound.beep() }
    }
    @objc private func openArchive() { outcome = .archive; finish(.OK) }
    @objc private func cancel(_ sender: Any?) { outcome = nil; finish(.cancel) }
    private func finish(_ result: NSApplication.ModalResponse) {
        if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: result) }
    }
}
