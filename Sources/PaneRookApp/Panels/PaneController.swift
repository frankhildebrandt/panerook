import PaneRookRemote
import PaneRookPanels
import AppKit
import Darwin
import PaneRookCore



final class FileTable: NSTableView, NSMenuItemValidation {
    var copyFiles: (() -> Void)?
    var pasteFiles: (() -> Void)?
    var canCopyFiles: (() -> Bool)?
    var canPasteFiles: (() -> Bool)?
    @objc func copy(_ sender: Any?) { copyFiles?() }
    @objc func paste(_ sender: Any?) { pasteFiles?() }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return canCopyFiles?() == true }
        if item.action == #selector(paste(_:)) { return canPasteFiles?() == true }
        return true
    }
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

final class ThemedFileRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        ThemeManager.theme == .paneRook ? super.interiorBackgroundStyle : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard ThemeManager.theme != .paneRook else { super.drawSelection(in: dirtyRect); return }
        let frame = bounds.insetBy(dx: 2, dy: 1)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)
        let base = ThemeManager.surfaceColor
        let accent = ThemeManager.accentColor
        (base.blended(withFraction: isEmphasized ? 0.22 : 0.12, of: accent) ?? base).setFill()
        shape.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            accent.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }
}

final class PaneController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, PanelAccess {
    let tabID: UUID
    var onWorkspaceReconnectRequested: (() -> Void)?
    var pendingWorkspaceConnection: ConnectionBookmark?
    private var restoredTerminalDirectory: URL?
    var hasLiveTerminal: Bool { terminalContent?.isRunning == true }
    let table = FileTable()
    weak var fileExchange: NativeFileExchange?
    let pathField = NSTextField()
    let favoritesButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let availableSpace = NSTextField(labelWithString: "")
    private let capacityReader: (URL) -> Int64?
    private var capacityRequest = 0
    private let summary = NSTextField(labelWithString: "")
    private let back = NSButton()
    private let navigation = NSStackView()
    private let gitBar = NSStackView()
    private let gitButton = NSButton()
    private let gitFilterButton = NSPopUpButton()
    private let watchButton = NSButton()
    private var contentTop: NSLayoutConstraint?
    private var contentBottom: NSLayoutConstraint?
    private var historyContentEdges: [NSLayoutConstraint] = []
    private var gitInlineWidth: NSLayoutConstraint?
    private var gitInlineConstraints: [NSLayoutConstraint] = []
    private var gitRowConstraints: [NSLayoutConstraint] = []
    private var gitBarIsInline = false
    private var gitRequest = 0
    private let gitWorker = DispatchQueue(label: "PaneRook.panel.git", qos: .utility)
    private let gitWatches = GitWatchStore()
    private let gitStatusCache: GitStatusCache
    private var cachedGitHeader: GitHeaderStatus?
    private var watchObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?
    private let localObservation: LocalDirectoryObservation
    private let directoryReader: (URL, Bool) throws -> [FileEntry]
    private let gitSnapshotReader: (URL) throws -> GitSnapshot?
    private var observationSuspended = false
    private var localObservationHidden = false
    private var observationRequest = 0
    private var automaticRefreshRunning = false
    private var pendingLocalChange = LocalDirectoryObservation.Change()
    private var gitSnapshotLoading = false
    private var gitSnapshotPending = false
    private var observedGitRefresh: DispatchWorkItem?
    private var lastObservedGitRefresh: TimeInterval = -.infinity
    private let surface = PaneSurface()
    private let listing = NSScrollView()
    private let content = NSView()
    private let inspection = PanelInspectionView()
    private let tree = PanelDirectoryTree()
    private let network = NetworkBrowserView()
    private let gitHistory = GitHistoryView()
    private var terminalContent: (any TerminalPanelContent)?
    private(set) var remoteContent: (any RemotePanelContent)?
    private var state: PanelState
    private let gitStatusQueue = DispatchQueue(label: "app.panerook.panel.git-status", qos: .utility)
    private var gitStatusReader: GitStatusReader?
    private let repositoryQueue = DispatchQueue(label: "app.panerook.panel.git-repository", qos: .utility)
    private var repositoryReader: GitRepositoryReader?
    private var listingGitRepository: GitRepositoryInfo?
    var gitRepository: GitRepositoryInfo? { mode == .terminal ? nil : listingGitRepository }
    private var generation: Int { state.generation }
    var allEntries: [FileEntry] { get { state.allEntries } set { state.allEntries = newValue } }
    private var panelized: Bool { state.panelized }
    var directorySizes: [URL: Int64] { get { state.directorySizes } set { state.directorySizes = newValue } }
    private var inspectionURL: URL?
    private var iconsVisible = true
    private var summaryVisible = true
    private var highlights: [(pattern: String, color: NSColor)] = []
    private var summaryHeight: NSLayoutConstraint?
    var mode: PanelMode { get { state.mode } set { state.mode = newValue } }
    var filterPattern: String { get { remoteContent?.filterPattern ?? state.filterPattern } set { state.filterPattern = newValue } }
    var gitFilter: GitFileFilter { state.gitFilter }
    var textEncoding: String.Encoding {
        get { state.textEncoding }
        set { state.textEncoding = newValue; if mode == .quickView { showInspection(of: inspectionURL) } }
    }
    var visitedDirectories: [URL] { state.visitedDirectories }
    /// A terminal is a local transfer destination, while the hidden listing retains its location.
    var directory: URL { mode == .terminal ? terminalContent?.currentDirectory ?? state.directory : state.directory }
    var isArchiveDirectory: Bool { ArchiveFileSystem.location(for: directory) != nil }
    var entries: [FileEntry] { get { state.entries } set { state.entries = newValue } }
    var onActivate: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onError: ((Error) -> Void)?
    var onOpenSelection: (() -> Void)?
    var onDirectoryChanged: (() -> Void)?
    var onRepositoryVisited: ((GitRepositoryInfo) -> Void)?
    var onOpenGit: (() -> Void)?
    var onGitHistoryRequested: (() -> Void)?
    var onSelectionChanged: ((URL?) -> Void)?
    var showHidden: Bool {
        get { state.showHidden }
        set { state.showHidden = newValue; remoteContent?.showHidden = newValue }
    }
    var isActive = false { didSet { remoteContent?.isActive = isActive; updateNavigation() } }
    private var history: [URL] { state.history }
    private let label: String
    private var loading: Bool { state.loading }
    var pendingTaskRefresh: Bool { get { state.pendingTaskRefresh } set { state.pendingTaskRefresh = newValue } }
    var sortKey: String { get { remoteContent?.sortKey ?? state.sortKey } set { state.sortKey = newValue } }
    var sortAscending: Bool { get { remoteContent?.sortAscending ?? state.sortAscending } set { state.sortAscending = newValue } }

    init(label: String, directory: URL, tabID: UUID = UUID(), gitStatusCache: GitStatusCache = .shared,
         terminalContent: (any TerminalPanelContent)? = nil,
         capacityReader: @escaping (URL) -> Int64? = FileSystem.availableCapacity,
         localObservation: LocalDirectoryObservation = LocalDirectoryObservation(),
         directoryReader: @escaping (URL, Bool) throws -> [FileEntry] = { try FileSystem.list($0, showHidden: $1) },
         gitSnapshotReader: @escaping (URL) throws -> GitSnapshot? = { try GitRepository.discover(in: $0)?.snapshot() }) {
        self.tabID = tabID
        self.label = label
        self.state = PanelState(directory: directory)
        self.gitStatusCache = gitStatusCache
        self.cachedGitHeader = gitStatusCache.header(for: directory)
        self.terminalContent = terminalContent
        self.capacityReader = capacityReader
        self.localObservation = localObservation
        self.directoryReader = directoryReader
        self.gitSnapshotReader = gitSnapshotReader
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        gitStatusReader?.cancel()
        repositoryReader?.cancel()
        localObservation.stop()
        observedGitRefresh?.cancel()
        if let watchObserver { NotificationCenter.default.removeObserver(watchObserver) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    override func loadView() {
        view = NSView()
        localObservation.onChange = { [weak self] in self?.receiveLocalChange($0) }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, self.view.window === window else { return }
            self.observationSuspended = true
            self.stopLocalObservation()
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor)
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
        up.toolTip = "Übergeordneter Ordner"

        AppStyle.configureField(pathField)
        pathField.placeholderString = "Pfad"
        pathField.toolTip = "Pfad eingeben"
        pathField.target = self
        pathField.action = #selector(pathEntered)
        pathField.delegate = self
        pathField.cell?.isScrollable = true
        pathField.setAccessibilityLabel("\(label): Ordnerpfad")

        availableSpace.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        availableSpace.textColor = .secondaryLabelColor
        availableSpace.setContentHuggingPriority(.required, for: .horizontal)
        availableSpace.setContentCompressionResistancePriority(.required, for: .horizontal)
        availableSpace.setAccessibilityLabel("\(label): Verfügbarer Speicherplatz")
        availableSpace.isHidden = true

        table.delegate = self
        table.dataSource = self
        configureFileExchange()
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
        table.backgroundColor = ThemeManager.surfaceColor
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.backgroundColor = ThemeManager.surfaceColor
            self.table.needsDisplay = true
            self.table.enumerateAvailableRowViews { row, _ in
                // Preserve selected text contrast when switching between the native
                // selection and a tinted theme, without rebuilding cells or icons.
                for case let cell as NSTableCellView in row.subviews {
                    cell.backgroundStyle = row.interiorBackgroundStyle
                }
                row.needsDisplay = true
            }
            self.favoritesButton.contentTintColor = ThemeManager.accentColor
            self.watchButton.contentTintColor = ThemeManager.accentColor
        }
        for (id, title, width) in [("name", "Name", 270.0), ("git", "Git", 66.0), ("size", "Größe", 85.0), ("modified", "Geändert", 132.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 140 : width
            column.resizingMask = id == "name" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if id != "git" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            column.isHidden = id == "git"
            table.addTableColumn(column)
        }
        listing.documentView = table
        listing.hasVerticalScroller = true
        listing.hasHorizontalScroller = true
        listing.autohidesScrollers = true
        listing.borderType = .noBorder
        for child in [listing, inspection, tree, network, gitHistory] {
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
        gitHistory.onActivate = { [weak self] in self?.onActivate?() }
        gitHistory.onKey = { [weak self] in self?.onKey?($0) ?? false }
        gitHistory.onClose = { [weak self] in self?.setMode(.listing) }
        inspection.isHidden = true; tree.isHidden = true; network.isHidden = true; gitHistory.isHidden = true
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
        for child in [back, up, pathField, availableSpace, favoritesButton] { navigation.addArrangedSubview(child) }
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 6
        navigation.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 12)
        navigation.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        back.widthAnchor.constraint(equalToConstant: 24).isActive = true
        up.widthAnchor.constraint(equalToConstant: 24).isActive = true
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        configureGitBar()
        for child in [navigation, gitBar, content, summary] {
            child.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(child)
        }
        let contentTop = content.topAnchor.constraint(equalTo: navigation.bottomAnchor)
        self.contentTop = contentTop
        let contentBottom = content.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -10)
        self.contentBottom = contentBottom
        historyContentEdges = [
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 1),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -1)
        ]
        let gitInlineWidth = gitBar.widthAnchor.constraint(equalToConstant: 0)
        self.gitInlineWidth = gitInlineWidth
        gitInlineConstraints = [
            navigation.trailingAnchor.constraint(equalTo: gitBar.leadingAnchor, constant: -6),
            gitBar.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
            gitBar.centerYAnchor.constraint(equalTo: navigation.centerYAnchor),
            gitInlineWidth
        ]
        gitRowConstraints = [
            navigation.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            gitBar.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 10),
            gitBar.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            gitBar.centerYAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 16)
        ]
        NSLayoutConstraint.activate(gitRowConstraints)
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: surface.topAnchor),
            navigation.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            contentTop,
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -1),
            contentBottom,
            summary.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            summary.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            summary.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
            summary.heightAnchor.constraint(equalToConstant: 16)
        ])
        updateNavigation()
        navigate(to: directory, recordHistory: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateGitBarLayout()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let resuming = observationSuspended
        observationSuspended = false
        updateLocalObservation(refresh: resuming)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        observationSuspended = true
        stopLocalObservation()
    }

    /// Hiding an ancestor (Ctrl-O, or a future tab host) need not deliver an
    /// NSViewController disappearance callback. The host can signal it directly.
    func setLocalObservationVisible(_ visible: Bool) {
        let hidden = !visible
        guard localObservationHidden != hidden else { return }
        localObservationHidden = hidden
        if visible { updateLocalObservation(refresh: true) }
        else { stopLocalObservation() }
    }

    var selectedEntries: [FileEntry] {
        guard remoteContent == nil else { return [] }
        guard !loading else { return [] }
        guard mode != .quickView && mode != .info && mode != .network && mode != .gitHistory && mode != .terminal else { return [] }
        if mode == .tree { return tree.selectedURL.flatMap { try? LocalInspection.entry(at: $0) }.map { [$0] } ?? [] }
        return table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }
    var selectedFiles: [URL] { selectedEntries.filter { !$0.isParent }.map(\.url) }
    var canExportNativeFiles: Bool {
        isViewLoaded && remoteContent == nil && mode == .listing && !loading && !isArchiveDirectory
    }
    var fileExchangeDirectory: URL? { canExportNativeFiles && !panelized ? directory : nil }
    var hasFileListKeyboardFocus: Bool {
        canExportNativeFiles && view.window?.firstResponder === table
    }
    private var listingSelection: [URL] {
        table.selectedRowIndexes.compactMap { entries.indices.contains($0) && !entries[$0].isParent ? entries[$0].url : nil }
    }
    var canUseGitFilter: Bool { remoteContent == nil && state.gitSnapshot != nil && !loading && mode == .listing }
    var hasPanelKeyboardFocus: Bool {
        guard mode != .terminal else { return false }
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        if let remoteContent, remoteContent.viewController.isViewLoaded {
            return responder.isDescendant(of: remoteContent.viewController.view)
        }
        return responder === table || responder === tree.outline || responder === inspection || responder.isDescendant(of: inspection)
            || (mode == .gitHistory && responder.isDescendant(of: gitHistory))
    }

    var hasTerminalKeyboardFocus: Bool {
        remoteContent == nil && mode == .terminal && terminalContent?.hasKeyboardFocus == true
    }


    func focus() {
        if let remoteContent { remoteContent.focus(); return }
        if mode == .terminal { terminalContent?.focus(); return }
        if mode == .network { network.focus(); return }
        if mode == .gitHistory { gitHistory.focus(); return }
        let responder: NSView = mode == .tree ? tree.outline : (mode == .listing ? table : inspection)
        view.window?.makeFirstResponder(responder)
    }

    func showRemoteContent(_ content: (any RemotePanelContent)?) {
        _ = view
        if remoteContent === content { return }
        if content != nil && mode == .gitHistory { setMode(.listing) }
        if content != nil {
            if content?.awaitsWorkspaceAuthentication != true { pendingWorkspaceConnection = nil }
            if mode == .terminal { setMode(.listing) }
            terminalContent?.stop()
        }
        let brief = isBriefListing
        let key = sortKey, ascending = sortAscending, pattern = filterPattern
        let previous = remoteContent
        if content == nil { pendingWorkspaceConnection = nil }
        remoteContent = nil
        previous?.disconnect()
        previous?.viewController.view.removeFromSuperview()
        previous?.viewController.removeFromParent()
        remoteContent = content
        if content != nil { stopLocalObservation() }
        surface.isHidden = content != nil
        if let content {
            content.onKey = { [weak self] event in self?.onKey?(event) ?? false }
            content.isActive = isActive
            if mode == .network { network.stop() }
            let controller = content.viewController
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            content.showHidden = showHidden
            content.setSort(key: key, ascending: ascending)
            content.setFilter(pattern)
            content.setBriefListing(brief)
            content.applyDisplayOptions(rowHeight: table.rowHeight, showIcons: iconsVisible, showSummary: summaryVisible)
            if let menu = favoritesButton.menu { content.installFavoritesMenu(menu) }
        } else if mode == .network { network.start() }
        refreshAvailableCapacity()
        updateLocalObservation(refresh: content == nil)
        onSelectionChanged?(selectedFiles.first)
        if isActive { focus() }
    }

    func remoteStateDidChange() { onSelectionChanged?(nil) }
    func activate() { onActivate?() }

    private func prepareTerminal() {
        if terminalContent == nil { terminalContent = GhosttyTerminalController() }
        guard let terminal = terminalContent else { return }
        if terminal.viewController.parent == nil {
            terminal.onActivate = { [weak self] in
                guard let self, self.mode == .terminal, self.remoteContent == nil else { return }
                self.onActivate?()
            }
            terminal.onDirectoryChanged = { [weak self] _ in
                guard let self, self.mode == .terminal, self.remoteContent == nil else { return }
                self.onDirectoryChanged?()
                self.onSelectionChanged?(nil)
            }
            terminal.onClose = { [weak self] in
                guard let self, self.mode == .terminal, self.remoteContent == nil else { return }
                self.setMode(.listing)
            }
            let controller = terminal.viewController
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: content.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }
        terminal.start(directory: restoredTerminalDirectory ?? state.directory)
        restoredTerminalDirectory = nil
    }

    func setMode(_ mode: PanelMode) {
        _ = view
        if remoteContent != nil {
            guard mode == .listing else { return }
        } else { showRemoteContent(nil) }
        if (mode == .tree || mode == .terminal) && state.isArchiveDirectory {
            onError?(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Im Archiv bitte die Dateiliste zur Ordnernavigation verwenden."]))
            return
        }
        let openingHistory = mode == .gitHistory && self.mode != .gitHistory
        let changingTerminal = mode == .terminal || self.mode == .terminal
        if self.mode == .network && mode != .network { network.stop() }
        if self.mode == .gitHistory && mode != .gitHistory { gitHistory.stop() }
        let previousMode = self.mode
        self.mode = mode
        if mode != .listing && mode != .tree { stopLocalObservation() }
        if mode == .terminal { prepareTerminal() }
        terminalContent?.setVisible(mode == .terminal)
        let fullContent = mode == .gitHistory || mode == .terminal
        navigation.isHidden = fullContent
        summary.isHidden = fullContent || !summaryVisible
        NSLayoutConstraint.deactivate(historyContentEdges)
        contentTop?.isActive = !fullContent
        contentBottom?.isActive = !fullContent
        if fullContent { NSLayoutConstraint.activate(historyContentEdges) }
        listing.isHidden = mode != .listing
        inspection.isHidden = mode != .quickView && mode != .info
        tree.isHidden = mode != .tree
        network.isHidden = mode != .network
        gitHistory.isHidden = mode != .gitHistory
        pathField.stringValue = mode == .network ? "Netzwerk" : directory.path
        pathField.isEditable = mode != .gitHistory
        pathField.toolTip = mode == .gitHistory ? "Git-Verlauf der Auswahl im anderen Panel" : "Pfad eingeben"
        if mode == .network { network.start() }
        if mode == .tree { tree.setRoot(directory, showHidden: showHidden) }
        if mode == .gitHistory {
            if openingHistory { gitHistory.follow(directory: nil, selection: nil, isDirectory: false) }
            onGitHistoryRequested?()
        }
        if mode == .quickView || mode == .info { showInspection(of: inspectionURL) }
        updateSummary()
        updateNavigation()
        refreshAvailableCapacity()
        updateLocalObservation(refresh: previousMode != mode)
        if isActive { focus() }
        onSelectionChanged?(selectedFiles.first)
        if changingTerminal { onDirectoryChanged?() }
    }

    func showInspection(of url: URL?) {
        inspectionURL = url
        guard isViewLoaded, mode == .quickView || mode == .info else { return }
        inspection.show(url, information: mode == .info, encoding: textEncoding)
        updateSummary()
    }

    /// Like quick view, Git history follows the opposite panel's selection.
    /// The viewer's own directory and listing selection remain available on return.
    func showGitHistory(from source: PaneController) {
        guard isViewLoaded, mode == .gitHistory else { return }
        guard source.remoteContent == nil, !source.isArchiveDirectory, source.mode != .network else {
            pathField.stringValue = "Git · anderes Panel"
            gitHistory.follow(directory: nil, selection: nil, isDirectory: false)
            return
        }
        let entries = source.selectedEntries.filter { !$0.isParent }
        let selection = entries.count == 1 ? entries.first : nil
        let sourceDirectory = selection.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? source.directory
        pathField.stringValue = selection?.url.path ?? source.directory.path
        pathField.toolTip = "Git-Verlauf der Auswahl im anderen Panel"
        gitHistory.follow(directory: sourceDirectory, selection: selection?.url,
                          isDirectory: selection?.isDirectory ?? false)
    }

    func setFilter(_ pattern: String) {
        filterPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let remoteContent { remoteContent.setFilter(state.filterPattern); return }
        guard isViewLoaded else { return }
        let selected = Set(mode == .gitHistory || mode == .terminal ? listingSelection : selectedFiles)
        state.filterAndSort(); table.reloadData()
        let indexes = IndexSet(entries.indices.filter { selected.contains(entries[$0].url) })
        table.selectRowIndexes(indexes.isEmpty && !entries.isEmpty ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
        updateSummary()
    }

    func setGitFilter(_ filter: GitFileFilter) {
        state.gitFilter = filter
        setFilter(filterPattern)
        updateGitBar()
    }

    func panelize(_ urls: [URL]) {
        _ = view
        showRemoteContent(nil)
        stopLocalObservation()
        gitStatusReader?.cancel()
        repositoryReader?.cancel()
        listingGitRepository = nil
        var seen = Set<URL>()
        let files = urls.filter { $0.isFileURL && seen.insert($0.standardizedFileURL).inserted }.compactMap { try? LocalInspection.entry(at: $0) }
        state.showResults(files)
        gitRequest += 1
        state.gitSnapshot = nil
        updateGitBar()
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
        summaryVisible = showSummary
        summary.isHidden = !showSummary || mode == .gitHistory || mode == .terminal
        if summaryHeight == nil { summaryHeight = summary.constraints.first { $0.firstAttribute == .height } }
        summaryHeight?.constant = showSummary ? 16 : 0
        reloadListingPreservingSelection()
        remoteContent?.applyDisplayOptions(rowHeight: table.rowHeight, showIcons: showIcons, showSummary: showSummary)
    }

    func applyHighlights(_ rules: [(pattern: String, color: NSColor)]) { highlights = rules; reloadListingPreservingSelection() }

    private func reloadListingPreservingSelection() {
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
    }

    var isBriefListing: Bool {
        if let remoteContent { return remoteContent.isBriefListing }
        return isViewLoaded && !table.tableColumns.isEmpty
            && table.tableColumns.dropFirst().allSatisfy(\.isHidden)
    }

    func setSort(key: String, ascending: Bool) {
        guard ["name", "size", "modified"].contains(key) else { return }
        if let remoteContent {
            state.sortKey = key; state.sortAscending = ascending
            remoteContent.setSort(key: key, ascending: ascending)
            return
        }
        _ = view
        table.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
    }

    func setBriefListing(_ brief: Bool) {
        _ = view
        if let remoteContent { remoteContent.setBriefListing(brief); return }
        guard isBriefListing != brief else { return }
        for column in table.tableColumns.dropFirst() {
            column.isHidden = brief || (column.identifier.rawValue == "git" && state.gitSnapshot == nil)
        }
        // The existing first-column-only autoresizing keeps metadata column widths intact.
        table.sizeToFit()
    }

    func selectMatching(_ pattern: String, select: Bool) {
        if let remoteContent { remoteContent.selectMatching(pattern, select: select); return }
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
        if let remoteContent { remoteContent.invertSelection(); return }
        guard isViewLoaded, !loading else { return }
        let selected = table.selectedRowIndexes
        let inverted = IndexSet(entries.indices.filter {
            !entries[$0].isParent && !selected.contains($0)
        })
        table.selectRowIndexes(inverted, byExtendingSelection: false)
    }

    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil, preserveDirectorySizes: Bool = false) {
        showRemoteContent(nil)
        if mode == .network || mode == .gitHistory || mode == .terminal { setMode(.listing) }
        let oldDirectory = directory
        let preserved = Set(selectedFiles)
        let hidden = showHidden
        gitStatusReader?.cancel()
        repositoryReader?.cancel()
        let request = state.beginNavigation()
        stopLocalObservation()
        updateLocalObservation(directory: url)
        clearAvailableCapacity()
        gitRequest += 1
        summary.stringValue = "Ordner wird gelesen …"
        let read = directoryReader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let files = try read(url, hidden)
                let root = ArchiveFileSystem.location(for: url) == nil ? GitWorktreeLocation.root(containing: url) : nil
                return (files: files, gitRoot: root)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                switch result {
                case .success(let listing):
                    guard self.state.completeNavigation(request, to: url, files: listing.files,
                        recordHistory: recordHistory, preserveDirectorySizes: preserveDirectorySizes) else { return }
                    self.listingGitRepository = nil
                    self.restoreGitStatus(in: listing.gitRoot)
                    self.applyCachedGitStatuses(request: request)
                    if self.mode == .tree && self.isArchiveDirectory { self.setMode(.listing) }
                    if self.mode != .gitHistory && self.mode != .terminal { self.pathField.stringValue = url.path }
                    self.table.reloadData()
                    // Normalize both sides: macOS listings may return /private/tmp
                    // while the entered path uses /tmp. Keep leaf symlinks distinct.
                    let desired = select.map { Set([$0.standardizedFileURL]) }
                        ?? (oldDirectory == url ? Set(preserved.map(\.standardizedFileURL)) : [])
                    let indexes = IndexSet(self.entries.indices.filter { desired.contains(self.entries[$0].url.standardizedFileURL) })
                    self.table.selectRowIndexes(indexes.isEmpty && !self.entries.isEmpty ? IndexSet(integer: 0) : indexes, byExtendingSelection: false)
                    if select != nil, let row = indexes.first { self.table.scrollRowToVisible(row) }
                    self.updateSummary()
                    self.updateNavigation()
                    self.refreshAvailableCapacity()
                    self.refreshGitStatus()
                    if self.mode == .tree { self.tree.setRoot(url, showHidden: self.showHidden) }
                    self.onDirectoryChanged?()
                    self.onSelectionChanged?(self.selectedFiles.first)
                    self.loadGitStatuses(request: request)
                    self.loadGitRepository(request: request)
                case .failure(let error):
                    guard self.state.failNavigation(request) else { return }
                    if self.mode != .gitHistory { self.pathField.stringValue = self.directory.path }
                    self.updateSummary()
                    self.refreshAvailableCapacity()
                    self.refreshGitStatus()
                    self.onError?(error)
                    self.loadGitStatuses(request: request)
                    self.loadGitRepository(request: request)
                }
                self.updateLocalObservation()
                self.receiveLocalChange(LocalDirectoryObservation.Change())
                if self.pendingTaskRefresh {
                    self.pendingTaskRefresh = false
                    self.refreshAfterTask()
                }
            }
        }
    }

    private func loadGitRepository(request: Int) {
        guard generation == request, !panelized, !state.isArchiveDirectory else { return }
        let reader = GitRepositoryReader()
        repositoryReader = reader
        let directory = state.directory
        let observation = observationRequest
        repositoryQueue.async { [weak self] in
            let repository = reader.repository(containing: directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, self.observationRequest == observation,
                      !self.panelized, !reader.isCancelled else { return }
                self.listingGitRepository = repository
                self.updateLocalObservation()
                if let repository { self.onRepositoryVisited?(repository) }
            }
        }
    }

    private func loadGitStatuses(request: Int, only changed: Set<URL>? = nil) {
        guard generation == request, !panelized, !state.isArchiveDirectory else { return }
        gitStatusReader?.cancel()
        let reader = GitStatusReader()
        gitStatusReader = reader
        // Events use physical paths; the panel may have entered through a
        // symlink. These are always direct children of the same listing.
        let changedNames = changed.map { Set($0.map(\.lastPathComponent)) }
        let folders = allEntries.filter {
            $0.isDirectory && !$0.isParent && (changedNames == nil || changedNames!.contains($0.name))
        }
        let cachedFolders = Set(folders.filter { state.gitStatuses[$0.url] != nil }.map(\.url))
        let observation = observationRequest
        gitStatusQueue.async { [weak self] in
            for folder in folders {
                guard !reader.isCancelled else { return }
                let status = reader.status(for: folder.url)
                guard status != nil || cachedFolders.contains(folder.url) else { continue }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.observationRequest == observation, !reader.isCancelled else { return }
                    let previous = self.state.gitStatuses[folder.url]
                    guard self.state.applyGitStatus(status, for: folder.url, request: request) else { return }
                    self.gitStatusCache.store(status, for: folder.url)
                    guard previous != status, let row = self.entries.firstIndex(where: { $0.url == folder.url }) else { return }
                    self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }

    private func applyCachedGitStatuses(request: Int) {
        for folder in allEntries where folder.isDirectory && !folder.isParent {
            if let status = gitStatusCache.status(for: folder.url) {
                state.applyGitStatus(status, for: folder.url, request: request)
            }
        }
    }

    private func restoreGitStatus(in root: URL?) {
        guard !panelized, !state.isArchiveDirectory else { return }
        // Resolve repository boundaries on the listing worker, then reuse its
        // entire worktree snapshot even for a directory never visited before.
        let header = root.flatMap { gitStatusCache.header(for: $0) }
        cachedGitHeader = header.flatMap { $0.root.standardizedFileURL.path == root?.path ? $0 : nil }
        let remembered = root.flatMap { gitStatusCache.snapshot(for: $0) }
        let previous = state.gitSnapshot
        state.gitSnapshot = remembered.flatMap { $0.root.standardizedFileURL.path == root?.path ? $0 : nil }
            ?? previous.flatMap { $0.root.standardizedFileURL.path == root?.path ? $0 : nil }
        state.watchedPaths = state.gitSnapshot.map { gitWatches.paths(in: $0.root) } ?? []
        state.filterAndSort()
    }

    func canApplyTaskResult(in url: URL) -> Bool {
        remoteContent == nil && state.canApplyTaskResult(in: url)
    }

    /// A background completion must not replace search results or an in-flight navigation.
    func refreshAfterTask() {
        if let remoteContent { remoteContent.refresh(); return }
        if mode == .gitHistory { gitHistory.refresh(); return }
        guard isViewLoaded, !panelized, mode == .listing || mode == .tree else { return }
        guard !loading else { pendingTaskRefresh = true; return }
        navigate(to: directory, recordHistory: false, preserveDirectorySizes: true)
    }

    func refresh(select: URL? = nil) {
        if let remoteContent { remoteContent.refresh(); return }
        if mode == .terminal { return }
        if mode == .gitHistory { gitHistory.refresh(); return }
        if mode == .network { network.stop(); network.start(); return }
        navigate(to: directory, recordHistory: false, select: select)
    }

    private var canObserveLocalDirectory: Bool {
        isViewLoaded && !observationSuspended && !localObservationHidden && remoteContent == nil && !panelized
            && (mode == .listing || mode == .tree)
    }

    private func stopLocalObservation() {
        observationRequest += 1
        localObservation.stop()
        automaticRefreshRunning = false
        pendingLocalChange = LocalDirectoryObservation.Change()
        gitRequest += 1
        gitSnapshotPending = false
        observedGitRefresh?.cancel(); observedGitRefresh = nil
        lastObservedGitRefresh = -.infinity
        gitStatusReader?.cancel()
        repositoryReader?.cancel()
    }

    private func updateLocalObservation(refresh: Bool = false, directory target: URL? = nil) {
        let url = target ?? state.directory
        guard canObserveLocalDirectory, ArchiveFileSystem.location(for: url) == nil else {
            localObservation.stop()
            return
        }
        localObservation.watch(directory: url,
            worktree: target == nil ? state.gitSnapshot?.root ?? listingGitRepository?.worktreeRoot : nil,
            metadata: target == nil ? listingGitRepository?.commonDirectory : nil,
            ignoredPaths: target == nil ? Set(state.gitSnapshot.map { snapshot in
                snapshot.files.filter(\.isIgnored).map { snapshot.root.appendingPathComponent($0.path).standardizedFileURL }
            } ?? []) : [])
        if refresh {
            receiveLocalChange(.init(listing: true, git: true, repository: true))
        }
    }

    private func receiveLocalChange(_ change: LocalDirectoryObservation.Change) {
        guard canObserveLocalDirectory, !state.isArchiveDirectory else { return }
        pendingLocalChange.merge(change)
        guard !loading, !automaticRefreshRunning, !pendingLocalChange.isEmpty else { return }
        let change = pendingLocalChange
        pendingLocalChange = LocalDirectoryObservation.Change()
        let request = generation, observation = observationRequest, url = state.directory
        if change.invalidated { localObservation.stop() }
        if change.git { queueObservedGitRefresh() }
        if change.repository { repositoryReader?.cancel(); loadGitRepository(request: request) }
        guard change.listing || mode == .tree && !change.descendants.isEmpty else {
            if !change.descendants.isEmpty { loadGitStatuses(request: request, only: change.descendants) }
            return
        }
        automaticRefreshRunning = true
        let hidden = showHidden, read = directoryReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try read(url, hidden) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.observationRequest == observation, self.generation == request,
                      self.state.directory == url, self.canObserveLocalDirectory, !self.loading else { return }
                self.automaticRefreshRunning = false
                switch result {
                case .success(let files):
                    let presentation = ListingPresentation(table: self.table, entries: self.entries)
                    guard self.state.applyObservedListing(files, in: url, request: request) else { return }
                    self.table.reloadData()
                    self.summary.toolTip = nil
                    presentation.restore(table: self.table, entries: self.entries)
                    if self.mode == .tree { self.tree.refreshLoadedDirectories() }
                    self.loadGitStatuses(request: request, only: change.descendants.isEmpty ? nil : change.descendants)
                    self.updateSummary(); self.updateNavigation(); self.refreshAvailableCapacity()
                    self.updateLocalObservation()
                    self.onSelectionChanged?(self.selectedFiles.first)
                case .failure(let error):
                    // A lost volume or removed root must not cause recurring
                    // modal errors. Cmd-R/navigation can retry and reattach.
                    self.stopLocalObservation()
                    self.clearAvailableCapacity()
                    self.summary.stringValue = "Ordner nicht verfügbar · ⌘R zum erneuten Laden"
                    self.summary.toolTip = error.localizedDescription
                }
                self.receiveLocalChange(LocalDirectoryObservation.Change())
            }
        }
    }

    private func queueObservedGitRefresh() {
        guard observedGitRefresh == nil else { return }
        let request = observationRequest
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.observationRequest == request, self.canObserveLocalDirectory, !self.loading else { return }
            self.observedGitRefresh = nil
            self.lastObservedGitRefresh = ProcessInfo.processInfo.systemUptime
            self.refreshGitStatus()
        }
        observedGitRefresh = item
        let delay = max(0, 2 - (ProcessInfo.processInfo.systemUptime - lastObservedGitRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    func installFavoritesMenu(_ menu: NSMenu) {
        favoritesButton.menu = menu
        remoteContent?.installFavoritesMenu(menu)
    }
    func showFavorites() {
        if let remoteContent { remoteContent.showFavorites(); return }
        favoritesButton.performClick(nil)
    }
    @objc func goUp() {
        if let remoteContent { remoteContent.goUp(); return }
        if mode == .network { setMode(.listing); return }
        let parent = mode == .terminal ? directory.deletingLastPathComponent() : state.parentDirectory
        navigate(to: parent, select: directory)
    }
    @objc func goBack() {
        if let remoteContent { remoteContent.goBack(); return }
        if mode == .network { setMode(.listing); return }
        guard let previous = state.popHistory() else { return }
        navigate(to: previous, recordHistory: false)
    }
    @objc private func pathEntered() {
        do {
            navigate(to: try FileSystem.directory(from: pathField.stringValue, relativeTo: directory))
            view.window?.makeFirstResponder(table)
        } catch { onError?(error) }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { onActivate?() }
    func controlTextDidChange(_ obj: Notification) { updateGitBarLayout() }
    @objc private func openFromTable() { onActivate?(); onOpenSelection?() }
    @objc func openSelection() {
        if let remoteContent { remoteContent.openSelection(); return }
        guard !loading, let entry = selectedEntries.first else { return }
        if entry.isParent {
            goUp()
        }
        else if entry.isDirectory || (!entry.isSymbolicLink && ArchiveFileSystem.location(for: entry.url)?.memberPath.isEmpty == true) {
            navigate(to: entry.url)
        }
        else if !NSWorkspace.shared.open(entry.url) {
            onError?(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Datei konnte nicht geöffnet werden."]))
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ThemedFileRow() }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSummary(); updateGitBar(); onSelectionChanged?(selectedFiles.first)
    }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = table.sortDescriptors.first else { return }
        let selected = Set(mode == .gitHistory || mode == .terminal ? listingSelection : selectedFiles)
        sortKey = descriptor.key ?? "name"
        sortAscending = descriptor.ascending
        applySort()
        table.reloadData()
        table.selectRowIndexes(IndexSet(entries.indices.filter { selected.contains(entries[$0].url) }), byExtendingSelection: false)
    }
    private func applySort() { state.sort() }
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
        var trailing = cell.trailingAnchor
        var trailingInset: CGFloat = -4
        if id.rawValue == "name" {
            if iconsVisible {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            if entry.isParent {
                image.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)
            } else if isArchiveDirectory {
                image.image = NSImage(systemSymbolName: entry.isDirectory ? "folder" : "doc", accessibilityDescription: nil)
            } else {
                image.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            }
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
            if let status = state.gitStatuses[entry.url] {
                let badge = GitStatusBadge(status: status)
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                badge.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(badge)
                NSLayoutConstraint.activate([
                    badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    badge.widthAnchor.constraint(lessThanOrEqualTo: cell.widthAnchor, multiplier: 0.5),
                    badge.widthAnchor.constraint(lessThanOrEqualToConstant: 170)
                ])
                trailing = badge.leadingAnchor
                trailingInset = -8
                cell.toolTip = GitStatusPresentation(status: status).detail
                text.setAccessibilityLabel(text.stringValue + ", " + GitStatusPresentation(status: status).detail)
            }
        } else if id.rawValue == "git" {
            text.stringValue = state.gitSnapshot.flatMap {
                GitPanelPaths.statusLabel(for: entry, snapshot: $0, watchedPaths: state.watchedPaths)
            } ?? ""
            text.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            text.textColor = text.stringValue.trimmingCharacters(in: CharacterSet(charactersIn: "★ ")) == "!"
                || text.stringValue.contains("U") ? .systemRed : .secondaryLabelColor
            cell.toolTip = "Git: Index / Arbeitsverzeichnis · ?? Untracked · !! Ignoriert · ★ Watched"
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
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), text.trailingAnchor.constraint(equalTo: trailing, constant: trailingInset), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
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
        favoritesButton.contentTintColor = ThemeManager.accentColor
        watchButton.contentTintColor = ThemeManager.accentColor
        back.isEnabled = mode == .network || !history.isEmpty
        updateGitBar()
    }
    private func updateSummary() {
        guard !loading else { return }
        if mode == .gitHistory { summary.stringValue = "Git-Diff und Verlauf · schreibgeschützte Vorschau"; return }
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
            + (isArchiveDirectory ? "  ·  Archiv" : "")
            + (state.gitSnapshot != nil && state.gitFilter != .all ? "  ·  \(state.gitFilter.title)" : "")
    }

    private var canShowAvailableCapacity: Bool {
        remoteContent == nil && !loading && !panelized && !isArchiveDirectory
            && (mode == .listing || mode == .tree)
    }

    private func clearAvailableCapacity() {
        capacityRequest += 1
        availableSpace.stringValue = ""
        availableSpace.toolTip = nil
        availableSpace.isHidden = true
        updateGitBarLayout()
    }

    private func refreshAvailableCapacity() {
        clearAvailableCapacity()
        guard canShowAvailableCapacity else { return }
        let request = capacityRequest
        let directory = self.directory
        let read = capacityReader
        // Mounted volumes may take time to respond. Keep this independent of
        // directory loading and discard results after navigation or mode changes.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let capacity = read(directory)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.capacityRequest == request, self.directory == directory,
                      self.canShowAvailableCapacity, let capacity, capacity >= 0 else { return }
                self.availableSpace.stringValue = "\(ByteCountFormatter.string(fromByteCount: capacity, countStyle: .file)) frei"
                self.availableSpace.toolTip = "Verfügbarer Speicherplatz auf dem Volume dieses Ordners\n\(directory.path)"
                self.updateGitBarLayout()
            }
        }
    }

    private func configureGitBar() {
        gitBar.orientation = .horizontal
        gitBar.alignment = .centerY
        gitBar.spacing = 6
        gitButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        gitButton.imagePosition = .imageLeading
        gitButton.lineBreakMode = .byTruncatingMiddle
        gitButton.target = self; gitButton.action = #selector(openGit)
        gitButton.setAccessibilityLabel("\(label): Git-Branch und Repository-Status")
        gitButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        gitButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for filter in GitFileFilter.allCases { gitFilterButton.addItem(withTitle: filter.title) }
        gitFilterButton.target = self; gitFilterButton.action = #selector(gitFilterChanged)
        gitFilterButton.widthAnchor.constraint(equalToConstant: 150).isActive = true
        gitFilterButton.setAccessibilityLabel("\(label): Git-Filter")
        gitFilterButton.toolTip = "Dateiliste nach Git-Status filtern; Ordner mit passenden Einträgen bleiben sichtbar."
        watchButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Watched umschalten")
        watchButton.target = self; watchButton.action = #selector(toggleWatched)
        watchButton.toolTip = "Ausgewählte Dateien oder Ordner als Watched markieren oder entfernen"
        watchButton.setAccessibilityLabel("\(label): Watched umschalten")
        for button in [gitButton, gitFilterButton, watchButton] {
            AppStyle.configureButton(button); button.controlSize = .small
            gitBar.addArrangedSubview(button)
        }
        watchButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        gitBar.isHidden = true
        watchObserver = NotificationCenter.default.addObserver(
            forName: .paneRookGitWatchesChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.reloadGitWatches() }
    }

    /// Git runs separately from directory listing, and only the current navigation may publish results.
    private func refreshGitStatus() {
        gitRequest += 1
        let request = gitRequest
        let url = state.directory
        guard !state.isArchiveDirectory, !panelized, remoteContent == nil,
              mode == .listing || mode == .tree else {
            cachedGitHeader = nil
            state.gitSnapshot = nil; updateGitBar(); return
        }
        // Never queue one expensive snapshot per event while Git is busy.
        guard !gitSnapshotLoading else { gitSnapshotPending = true; return }
        gitSnapshotLoading = true
        updateGitBar()
        let read = gitSnapshotReader
        gitWorker.async { [weak self] in
            let result = Result { try read(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gitSnapshotLoading = false
                if self.gitSnapshotPending {
                    self.gitSnapshotPending = false
                    self.refreshGitStatus()
                    return
                }
                guard self.gitRequest == request, self.state.directory == url, !self.panelized,
                      !self.loading, self.remoteContent == nil, self.mode == .listing || self.mode == .tree else { return }
                self.cachedGitHeader = nil
                switch result {
                case .success(let snapshot):
                    self.gitStatusCache.storeSnapshot(snapshot, for: url)
                    self.gitStatusCache.store(snapshot.map { GitHeaderStatus(snapshot: $0) }, for: url)
                    self.state.gitSnapshot = snapshot
                    self.state.watchedPaths = snapshot.map { self.gitWatches.paths(in: $0.root) } ?? []
                case .failure(let error):
                    self.gitStatusCache.storeSnapshot(nil, for: url)
                    self.gitStatusCache.store(nil as GitHeaderStatus?, for: url)
                    self.state.gitSnapshot = nil
                    self.gitButton.toolTip = error.localizedDescription
                }
                let presentation = ListingPresentation(table: self.table, entries: self.entries)
                self.state.filterAndSort()
                self.table.reloadData()
                presentation.restore(table: self.table, entries: self.entries)
                self.updateSummary()
                self.updateGitBar()
                self.updateLocalObservation()
            }
        }
    }

    private func updateGitBar() {
        guard isViewLoaded else { return }
        defer { updateGitBarLayout() }
        let brief = isBriefListing
        let snapshot = state.gitSnapshot
        let header = snapshot.map { GitHeaderStatus(snapshot: $0) } ?? cachedGitHeader
        let visible = header != nil && !panelized && !isArchiveDirectory && mode == .listing
        gitBar.isHidden = !visible
        table.tableColumn(withIdentifier: .init("git"))?.isHidden = snapshot == nil || brief
        gitFilterButton.isEnabled = snapshot != nil && !loading
        watchButton.isEnabled = snapshot != nil && !selectedFiles.isEmpty && !loading
        guard let header else { return }
        gitButton.title = header.title
        gitButton.toolTip = header.toolTip + (snapshot == nil ? "\nZuletzt bekannter Status · wird aktualisiert …" : "")
        gitButton.contentTintColor = header.operation != nil ? .systemRed : nil
        gitFilterButton.selectItem(at: GitFileFilter.allCases.firstIndex(of: state.gitFilter) ?? 0)
        guard let snapshot else { return }
        let watched = selectedEntries.filter { !$0.isParent }.allSatisfy {
            GitFileFilter.watched.matches($0, snapshot: snapshot, watchedPaths: state.watchedPaths)
        } && !selectedFiles.isEmpty
        watchButton.image = NSImage(systemSymbolName: watched ? "star.fill" : "star", accessibilityDescription: "Watched umschalten")
    }

    private func updateGitBarLayout() {
        guard let contentTop, let gitInlineWidth else { return }
        // Preserve a usable path field in narrow panes. Use intrinsic widths so
        // hiding the capacity label does not change the next layout decision.
        let fixedControls = navigation.arrangedSubviews.filter { $0 !== pathField && $0 !== availableSpace && !$0.isHidden }
        let minimumNavigationWidth = 180 + fixedControls.reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
            + CGFloat(fixedControls.count) * navigation.spacing + navigation.edgeInsets.left + 12
        let hideCapacity = availableSpace.stringValue.isEmpty
            || surface.bounds.width < minimumNavigationWidth + availableSpace.intrinsicContentSize.width + navigation.spacing
        if availableSpace.isHidden != hideCapacity { availableSpace.isHidden = hideCapacity }
        // Measure the desired control sizes, not their compressed frames, so the
        // decision stays stable when switching between one and two rows.
        let gitWidth = ceil(gitButton.intrinsicContentSize.width)
            + gitFilterButton.fittingSize.width + watchButton.fittingSize.width + 2 * gitBar.spacing
        // A scrollable text field's intrinsic width does not include its full text.
        let pathTextWidth = (pathField.stringValue as NSString).size(withAttributes: [
            .font: pathField.font ?? NSFont.systemFont(ofSize: 12)
        ]).width
        let pathWidth = max(180, ceil(pathTextWidth) + 16)
        let visibleControls = navigation.arrangedSubviews.filter { !$0.isHidden }
        let navigationWidth = visibleControls.reduce(CGFloat(0)) {
            $0 + ($1 === pathField ? pathWidth : $1.fittingSize.width)
        } + CGFloat(visibleControls.count - 1) * navigation.spacing
            + navigation.edgeInsets.left + 12
        let inline = !gitBar.isHidden && surface.bounds.width >= navigationWidth + 6 + gitWidth
        if gitInlineWidth.constant != gitWidth { gitInlineWidth.constant = gitWidth }
        if inline != gitBarIsInline {
            NSLayoutConstraint.deactivate(gitBarIsInline ? gitInlineConstraints : gitRowConstraints)
            gitBarIsInline = inline
            navigation.edgeInsets.right = inline ? 0 : 12
            NSLayoutConstraint.activate(inline ? gitInlineConstraints : gitRowConstraints)
        }
        let rowHeight: CGFloat = gitBar.isHidden || inline ? 0 : 32
        if contentTop.constant != rowHeight { contentTop.constant = rowHeight }
    }

    private func reloadGitWatches() {
        guard let snapshot = state.gitSnapshot else { return }
        state.watchedPaths = gitWatches.paths(in: snapshot.root)
        setFilter(filterPattern)
        updateGitBar()
    }

    @objc private func gitFilterChanged() {
        guard GitFileFilter.allCases.indices.contains(gitFilterButton.indexOfSelectedItem) else { return }
        let filter = GitFileFilter.allCases[gitFilterButton.indexOfSelectedItem]
        onActivate?()
        setGitFilter(filter)
    }
    @objc private func openGit() { onActivate?(); onOpenGit?() }
    @objc func toggleWatched() {
        guard canUseGitFilter, let snapshot = state.gitSnapshot else { return }
        let paths = selectedFiles.compactMap { GitPanelPaths.relativePath(for: $0, in: snapshot.root) }
        guard !paths.isEmpty else { return }
        gitWatches.toggle(paths: paths, in: snapshot.root)
        NotificationCenter.default.post(name: .paneRookGitWatchesChanged, object: nil)
    }
}

extension Notification.Name {
    static let paneRookGitWatchesChanged = Notification.Name("PaneRookGitWatchesChanged")
}


extension PaneController {
    var tabTitle: String {
        if let connection = remoteContent?.workspaceBookmark ?? pendingWorkspaceConnection {
            return "☁ " + connection.name
        }
        let name = directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
        return mode == .terminal ? "› " + name : name
    }
    var tabLocationDescription: String {
        if let connection = remoteContent?.workspaceBookmark ?? pendingWorkspaceConnection {
            return "\(connection.kind.rawValue.uppercased()) · \(connection.host)\(connection.path)"
        }
        return directory.path
    }
    func workspaceSnapshot() -> WorkspaceTab {
        var tab = WorkspaceTab(id: tabID, directory: state.directory)
        tab.mode = String(describing: mode)
        tab.terminalDirectory = terminalContent?.currentDirectory ?? restoredTerminalDirectory
        tab.connection = remoteContent?.workspaceBookmark ?? pendingWorkspaceConnection
        tab.sortKey = sortKey; tab.sortAscending = sortAscending
        tab.brief = isBriefListing; tab.filter = filterPattern; tab.gitFilter = gitFilter.rawValue
        tab.encoding = textEncoding.rawValue; tab.showHidden = showHidden
        return tab
    }
    func restoreWorkspaceTab(_ tab: WorkspaceTab) {
        showHidden = tab.showHidden
        restoredTerminalDirectory = tab.terminalDirectory
        pendingWorkspaceConnection = tab.connection
        setSort(key: tab.sortKey, ascending: tab.sortAscending)
        setBriefListing(tab.brief); setFilter(tab.filter)
        setGitFilter(GitFileFilter(rawValue: tab.gitFilter) ?? .all)
        textEncoding = String.Encoding(rawValue: tab.encoding)
        let modes: [String: PanelMode] = ["listing": .listing, "quickView": .quickView, "info": .info,
            "tree": .tree, "network": .network, "gitHistory": .gitHistory, "terminal": .terminal]
        setMode(tab.connection == nil ? modes[tab.mode] ?? .listing : .listing)
        if let bookmark = tab.connection {
            let disconnected = DisconnectedWorkspaceConnection(bookmark: bookmark)
            disconnected.onReconnect = { [weak self] in self?.onWorkspaceReconnectRequested?() }
            disconnected.onReturnToLocal = { [weak self] in
                self?.pendingWorkspaceConnection = nil
                self?.showRemoteContent(nil)
                self?.onDirectoryChanged?()
            }
            showRemoteContent(disconnected)
        }
    }
    /// Explicit tab close is the only tab action allowed to stop its shell.
    func closeTabContent() { terminalContent?.stop(); remoteContent?.disconnect() }
}
