import AppKit
import GhosttyTerminal

/// The panel owns presentation; the terminal owns its shell and working directory.
@MainActor
protocol TerminalPanelContent: AnyObject {
    var viewController: NSViewController { get }
    var currentDirectory: URL? { get }
    var hasKeyboardFocus: Bool { get }
    var isRunning: Bool { get }
    var onActivate: (() -> Void)? { get set }
    var onDirectoryChanged: ((URL) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func start(directory: URL)
    func stop()
    func focus()
    func setVisible(_ visible: Bool)
}

/// An embedded Ghostty exec surface. Hiding it retains the PTY and scrollback.
@MainActor
final class GhosttyTerminalController: NSViewController, TerminalPanelContent {
    var viewController: NSViewController { self }
    private(set) var currentDirectory: URL?
    private(set) var isRunning = false
    var onActivate: (() -> Void)?
    var onDirectoryChanged: ((URL) -> Void)?
    var onClose: (() -> Void)?

    private let titleField = NSTextField(labelWithString: "Ghostty")
    private let directoryField = NSTextField(labelWithString: "")
    private let terminalContainer = NSView()
    private var terminalView: AppTerminalView?
    private var runtime: TerminalController?
    private var session: SessionDelegate?
    private var visible = true
    private var windowCloseObserver: NSObjectProtocol?

    var hasKeyboardFocus: Bool {
        guard isViewLoaded, let terminalView, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === terminalView || responder.isDescendant(of: terminalView)
    }

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }

    override func loadView() {
        let hostView = TerminalHostView()
        hostView.onWindowChanged = { [weak self] window in self?.observeWindowClose(window) }
        view = hostView
        view.isHidden = !visible
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setAccessibilityLabel("Ghostty: Terminaltitel")
        directoryField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        directoryField.textColor = .secondaryLabelColor
        directoryField.lineBreakMode = .byTruncatingMiddle
        directoryField.setAccessibilityLabel("Ghostty: aktuelles lokales Verzeichnis")
        directoryField.toolTip = "Kopieren und Verschieben aus dem anderen Panel verwenden dieses Verzeichnis."
        let labels = NSStackView(views: [titleField, directoryField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let close = NSButton(title: "Dateiliste", target: self, action: #selector(returnToFiles))
        AppStyle.configureButton(close)
        close.controlSize = .small
        close.toolTip = "Zur Dateiliste wechseln; das Terminal läuft weiter."
        close.setAccessibilityLabel("Ghostty: zur Dateiliste wechseln")
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [labels, close])
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        for child in [header, terminalContainer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
            terminalContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            terminalContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            terminalContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1)
        ])
    }

    func start(directory: URL) {
        _ = view
        guard !isRunning else { terminalView?.setSurfaceVisible(visible); return }
        guard let directory = Self.localDirectory(from: directory.absoluteString) else {
            titleField.stringValue = "Ghostty · Ordner nicht verfügbar"
            return
        }
        stop()
        currentDirectory = directory
        directoryField.stringValue = directory.path
        titleField.stringValue = "Ghostty"
        // Load only this app's configuration. Standalone Ghostty key bindings
        // can create windows or terminate an app and do not belong to a pane.
        let configuration = TerminalConfiguration(startingFrom: .default) {
            $0.withCustom("shell-integration", "detect")
            $0.withCustom("keybind", "clear")
            $0.withCustom("keybind", "super+c=copy_to_clipboard")
            $0.withCustom("keybind", "super+v=paste_from_clipboard")
            $0.withCustom("keybind", "super+a=select_all")
            $0.withCustom("keybind", "super+plus=increase_font_size:1")
            $0.withCustom("keybind", "super+minus=decrease_font_size:1")
            $0.withCustom("keybind", "super+zero=reset_font_size")
            $0.withWindowPaddingX(8)
            $0.withWindowPaddingY(6)
        }
        let runtime = TerminalController(configuration: configuration)
        guard runtime.lastConfigurationIssue == nil else {
            titleField.stringValue = "Ghostty · Konfiguration konnte nicht geladen werden"
            titleField.toolTip = runtime.lastConfigurationIssue
            return
        }
        let terminal = AppTerminalView(frame: .zero)
        let delegate = SessionDelegate(owner: self)
        terminal.configuration = TerminalSurfaceOptions(
            workingDirectory: directory.path,
            envVars: ["PANEROOK_TERMINAL": "1"],
            waitAfterCommand: false
        )
        terminal.delegate = delegate
        terminal.controller = runtime
        terminal.setAccessibilityLabel("Ghostty-Terminal")
        self.runtime = runtime
        session = delegate
        terminalView = terminal
        isRunning = true
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor)
        ])
        terminal.setSurfaceVisible(visible)
        onDirectoryChanged?(directory)
    }

    func stop() {
        // Retire the callback receiver before freeing the surface: a queued
        // pwd/exit message from the old shell must not affect its replacement.
        session = nil
        terminalView?.delegate = nil
        terminalView?.setSurfaceVisible(false)
        terminalView?.controller = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        runtime = nil
        isRunning = false
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        if isViewLoaded { view.isHidden = !visible }
        terminalView?.setSurfaceVisible(visible)
    }

    func focus() { _ = terminalView?.acquireProgrammaticFocus() }

    @objc private func returnToFiles() { onClose?() }

    private func observeWindowClose(_ window: NSWindow?) {
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        guard let window else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    /// Ghostty 1.3.1's stream handler checks OSC 7's hostname with
    /// hostname.isLocal before emitting this path-only pwd action.
    /// Accept file URLs too, but never interpret another host as a local path.
    static func localDirectory(from value: String) -> URL? {
        guard !value.isEmpty, !value.utf8.contains(0) else { return nil }
        let directory: URL
        if value.hasPrefix("/") {
            directory = URL(fileURLWithPath: value, isDirectory: true)
        } else {
            guard let url = URL(string: value), url.isFileURL,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil else { return nil }
            let host = url.host?.lowercased() ?? ""
            let localHosts = ["", "localhost", "127.0.0.1", "::1", ProcessInfo.processInfo.hostName.lowercased()]
            guard localHosts.contains(host), url.path.hasPrefix("/") else { return nil }
            directory = URL(fileURLWithPath: url.path, isDirectory: true)
        }
        let normalized = directory.standardizedFileURL
        guard (try? normalized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return normalized
    }

    private func updateDirectory(_ path: String, from source: SessionDelegate) {
        guard session === source, let directory = Self.localDirectory(from: path), directory != currentDirectory else { return }
        currentDirectory = directory
        directoryField.stringValue = directory.path
        onDirectoryChanged?(directory)
    }

    private func finishSession(_ source: SessionDelegate) {
        guard session === source else { return }
        // Ghostty can invoke a close callback from its app tick. Tear down on
        // the next run loop turn, after the C callback has returned.
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source, self.session === source else { return }
            self.stop()
            self.titleField.stringValue = "Ghostty · Shell beendet"
            self.onClose?()
        }
    }

    private func confirmClipboard(_ request: TerminalClipboardConfirmationRequest, from source: SessionDelegate) {
        guard session === source, case .paste = request.kind,
              isViewLoaded, let window = view.window, window.attachedSheet == nil else {
            request.respond(allow: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Text in das Terminal einfügen?"
        alert.informativeText = "Der Text enthält mehrere Zeilen oder Steuerzeichen. Eingefügte Befehle können sofort ausgeführt werden."
        alert.addButton(withTitle: "Abbrechen")
        alert.addButton(withTitle: "Einfügen")
        alert.beginSheetModal(for: window) { [weak self, weak source] response in
            guard let self, let source, self.session === source else {
                request.respond(allow: false)
                return
            }
            request.respond(allow: response == .alertSecondButtonReturn)
        }
    }

    private final class SessionDelegate: TerminalSurfacePwdDelegate, TerminalSurfaceTitleDelegate,
        TerminalSurfaceFocusDelegate, TerminalSurfaceCloseDelegate, TerminalSurfaceClipboardConfirmationDelegate,
        TerminalSurfaceOpenURLDelegate
    {
        weak var owner: GhosttyTerminalController?
        init(owner: GhosttyTerminalController) { self.owner = owner }
        func terminalDidChangeWorkingDirectory(_ path: String) { owner?.updateDirectory(path, from: self) }
        func terminalDidChangeTitle(_ title: String) {
            guard let owner, owner.session === self else { return }
            let title = String(String.UnicodeScalarView(title.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }.prefix(160)))
            owner.titleField.stringValue = title.isEmpty ? "Ghostty" : "Ghostty · " + title
        }
        func terminalDidChangeFocus(_ focused: Bool) {
            guard focused, let owner, owner.session === self else { return }
            owner.onActivate?()
        }
        func terminalDidClose(processAlive: Bool) { owner?.finishSession(self) }
        func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
            guard let owner else { request.respond(allow: false); return }
            owner.confirmClipboard(request, from: self)
        }
        func terminalDidRequestOpenURL(_ value: String, kind: TerminalOpenURLKind) {
            guard let owner, owner.session === self, let url = URL(string: value),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

private final class TerminalHostView: NSView {
    var onWindowChanged: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?(window)
    }
}
