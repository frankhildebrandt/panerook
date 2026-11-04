import AppKit
import PaneRookRemote

/// A restored remote location requires explicit authentication. It occupies the
/// pane so local file actions cannot accidentally use its hidden fallback folder.
final class DisconnectedWorkspaceConnection: NSViewController, RemotePanelContent {
    let bookmark: ConnectionBookmark
    var onReconnect: (() -> Void)?
    var onReturnToLocal: (() -> Void)?
    var workspaceBookmark: ConnectionBookmark? { bookmark }
    var awaitsWorkspaceAuthentication: Bool { true }
    var viewController: NSViewController { self }
    var onKey: ((NSEvent) -> Bool)?
    var isActive = false
    var isBusy: Bool { false }
    var hasSelection: Bool { false }
    var canDownload: Bool { false }
    var canUpload: Bool { false }
    var filterPattern = ""
    var sortKey = "name"
    var sortAscending = true
    var isBriefListing = false
    private let connect = NSButton(title: "Wieder verbinden …", target: nil, action: nil)
    init(bookmark: ConnectionBookmark) { self.bookmark = bookmark; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: bookmark.name)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: "\(bookmark.kind.rawValue.uppercased()) · \(bookmark.user)@\(bookmark.host)\n\(bookmark.path)\n\nDie Verbindung wird bei Bedarf neu authentifiziert.")
        description.textColor = .secondaryLabelColor
        description.setAccessibilityLabel("Gespeicherter Remote-Ort")
        connect.target = self; connect.action = #selector(reconnect)
        let local = NSButton(title: "Lokale Dateiliste", target: self, action: #selector(returnToLocal))
        for button in [connect, local] { AppStyle.configureButton(button) }
        let stack = NSStackView(views: [title, description, connect, local])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48)
        ])
    }
    func focus() { view.window?.makeFirstResponder(connect) }
    func focusPath() { focus() }
    func refresh() {}
    func goUp() {}
    func openSelection() { onReconnect?() }
    func download() {}
    func upload() {}
    func makeDirectory() {}
    func deleteSelected() {}
    func disconnect() {}
    func setSort(key: String, ascending: Bool) { sortKey = key; sortAscending = ascending }
    func setFilter(_ pattern: String) { filterPattern = pattern }
    func setBriefListing(_ brief: Bool) { isBriefListing = brief }
    @objc private func reconnect() { onReconnect?() }
    @objc private func returnToLocal() { onReturnToLocal?() }
}
