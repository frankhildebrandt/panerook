import AppKit
import PaneRookCore
import PaneRookPanels

/// The other pane supplies the repository and selected file or directory.
final class GitHistoryView: NSView {
    var onActivate: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onClose: (() -> Void)?

    private let scope = NSPopUpButton()
    private let source = NSSegmentedControl(labels: ["Verlauf", "Arbeitskopie", "Staged"], trackingMode: .selectOne, target: nil, action: nil)
    private let contentMode = NSSegmentedControl(labels: ["Diff", "Datei"], trackingMode: .selectOne, target: nil, action: nil)
    private let versions = NSPopUpButton()
    private let older = NSButton()
    private let newer = NSButton()
    private let reloadButton = NSButton()
    private let details = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let targetTitle = NSTextField(labelWithString: "Git-Verlauf")
    private let sourceLabel = NSTextField(labelWithString: "Auswahl im anderen Panel")
    private let commitTitle = NSTextField(labelWithString: "Versionen entdecken")
    private let targetIcon = NSImageView()
    private let modes = NSStackView()
    private let diff = GitDiffView()
    private let queue = DispatchQueue(label: "app.panerook.git-history", qos: .userInitiated)
    private var directory: URL?
    private var selectedFile: URL?
    private var selectionIsDirectory = false
    private struct FollowContext: Equatable {
        let directory: URL?
        let selection: URL?
        let isDirectory: Bool
    }
    private var followedContext: FollowContext?
    private var pendingContentMode: Int?
    private var repository: GitRepository?
    private var path: String?
    private var entries: [GitHistoryEntry] = []
    private var generation = 0
    private var previewGeneration = 0
    private var loading = false
    private var eventMonitor: Any?
    private var themeObserver: NSObjectProtocol?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onActivate?(); return true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func mouseDown(with event: NSEvent) { focus() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in self?.updateColors() }
        updateColors()
        scope.addItem(withTitle: "Repository")
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.setAccessibilityLabel("Git-Verlauf: Repository, Datei oder Verzeichnis")
        scope.toolTip = "Folgt der Auswahl im anderen Panel"
        scope.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scope.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scope.cell?.lineBreakMode = .byTruncatingMiddle
        source.selectedSegment = 0; source.target = self; source.action = #selector(showSelection)
        source.setAccessibilityLabel("Git-Version, Arbeitskopie oder Staged-Diff")
        contentMode.selectedSegment = 0; contentMode.target = self; contentMode.action = #selector(showSelection)
        contentMode.setAccessibilityLabel("Commit-Diff oder Datei dieser Version")
        versions.target = self; versions.action = #selector(showSelection)
        versions.setAccessibilityLabel("Git-Version auswählen")
        versions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        versions.setContentHuggingPriority(.defaultLow, for: .horizontal)
        versions.cell?.lineBreakMode = .byTruncatingMiddle
        configure(older, symbol: "chevron.left", label: "Ältere Version", action: #selector(previousVersion))
        configure(newer, symbol: "chevron.right", label: "Neuere Version", action: #selector(nextVersion))
        configure(reloadButton, symbol: "arrow.clockwise", label: "Git-Verlauf aktualisieren", action: #selector(reload))
        let close = NSButton(title: "Dateiliste", target: self, action: #selector(closeViewer))
        AppStyle.configureButton(close)
        close.isBordered = false
        close.setContentHuggingPriority(.required, for: .horizontal)
        close.setContentCompressionResistancePriority(.required, for: .horizontal)
        close.font = .systemFont(ofSize: 12, weight: .medium)
        close.toolTip = "Zur Dateiliste zurückkehren"
        for control in [scope, versions] {
            AppStyle.configureButton(control)
            control.isBordered = false
            control.font = .systemFont(ofSize: 12, weight: .medium)
        }
        scope.setContentHuggingPriority(.required, for: .horizontal)
        scope.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        for control in [source, contentMode] {
            control.controlSize = .regular
            control.segmentStyle = .rounded
            control.font = .systemFont(ofSize: 12, weight: .medium)
        }
        for label in [targetTitle, sourceLabel, commitTitle, details, status] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        targetTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        targetTitle.setAccessibilityLabel("Git-Auswahl")
        sourceLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.setAccessibilityLabel("Git-Quelle")
        commitTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        commitTitle.isSelectable = true
        commitTitle.setAccessibilityLabel("Commit-Nachricht")
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        details.isSelectable = true
        details.setAccessibilityLabel("Ausgewählte Git-Version")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Git-Verlauf: Status")
        targetIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        targetIcon.contentTintColor = ThemeManager.accentColor
        targetIcon.symbolConfiguration = .init(pointSize: 22, weight: .medium)
        let icon = GitHistoryCard(tint: 0.12, bordered: false)
        targetIcon.translatesAutoresizingMaskIntoConstraints = false
        icon.addSubview(targetIcon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 40), icon.heightAnchor.constraint(equalToConstant: 40),
            targetIcon.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            targetIcon.centerYAnchor.constraint(equalTo: icon.centerYAnchor)
        ])
        let identity = NSStackView(views: [targetTitle, sourceLabel])
        identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 4
        for label in [targetTitle, sourceLabel] { label.widthAnchor.constraint(equalTo: identity.widthAnchor).isActive = true }
        let header = row([icon, identity, reloadButton, close])
        header.distribution = .fill
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 0)
        identity.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for view in [source, scope] { modes.addArrangedSubview(view) }
        modes.spacing = 10; modes.alignment = .centerY
        modes.setHuggingPriority(.required, for: .vertical)
        source.setContentHuggingPriority(.required, for: .horizontal)
        let versionsLabel = NSTextField(labelWithString: "VERSION")
        versionsLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        versionsLabel.textColor = .secondaryLabelColor
        let context = row([versionsLabel, NSView(), contentMode])
        let navigation = row([older, versions, newer])
        navigation.spacing = 6
        versions.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        (versions.cell as? NSPopUpButtonCell)?.usesItemFromMenu = false
        let commitContent = NSStackView(views: [context, commitTitle, details, navigation])
        commitContent.orientation = .vertical; commitContent.alignment = .leading; commitContent.spacing = 8
        let commitCard = GitHistoryCard(tint: 0.035)
        commitContent.translatesAutoresizingMaskIntoConstraints = false
        commitCard.addSubview(commitContent)
        NSLayoutConstraint.activate([
            commitContent.topAnchor.constraint(equalTo: commitCard.topAnchor, constant: 12),
            commitContent.bottomAnchor.constraint(equalTo: commitCard.bottomAnchor, constant: -12),
            commitContent.leadingAnchor.constraint(equalTo: commitCard.leadingAnchor, constant: 12),
            commitContent.trailingAnchor.constraint(equalTo: commitCard.trailingAnchor, constant: -12)
        ])
        for child in [context, commitTitle, details, navigation] {
            child.widthAnchor.constraint(equalTo: commitContent.widthAnchor).isActive = true
        }
        let root = NSStackView(views: [header, modes, commitCard, diff, status])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 14, left: 12, bottom: 10, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.documentView = root
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            root.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 150)
        ])
        for child in [header, modes, commitCard, diff, status] {
            child.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        }
        diff.usePaneStyle()
        diff.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateControls()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            if event.type == .leftMouseDown {
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.onActivate?() }
            } else if let responder = window.firstResponder as? NSView,
                      responder === self || responder.isDescendant(of: self) {
                if self.onKey?(event) == true { return nil }
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = ThemeManager.surfaceColor.cgColor
            targetIcon.contentTintColor = ThemeManager.accentColor
            targetIcon.needsDisplay = true
        }
    }

    override func layout() {
        let required = source.fittingSize.width + scope.fittingSize.width + modes.spacing + 24
        let compact = bounds.width < required
        if (modes.orientation == .vertical) != compact {
            modes.orientation = compact ? .vertical : .horizontal
            modes.alignment = compact ? .leading : .centerY
        }
        super.layout()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 6; stack.alignment = .centerY
        stack.setHuggingPriority(.required, for: .vertical)
        return stack
    }
    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.target = self; button.action = action
        button.toolTip = label; button.setAccessibilityLabel(label)
        AppStyle.configureButton(button)
        button.isBordered = false
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }

    func focus() { window?.makeFirstResponder(self) }

    private func setVersionCaption(_ caption: String) {
        (versions.cell as? NSPopUpButtonCell)?.menuItem = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
        versions.invalidateIntrinsicContentSize()
    }

    func open(directory: URL, selectedFile: URL?, isDirectory: Bool = false) {
        stop()
        self.directory = directory; self.selectedFile = selectedFile
        selectionIsDirectory = isDirectory
        repository = nil; path = nil; entries = []
        scope.removeAllItems(); scope.addItem(withTitle: "Repository")
        source.selectedSegment = 0; contentMode.selectedSegment = 0
        versions.removeAllItems(); details.stringValue = ""
        commitTitle.stringValue = "Versionen werden geladen …"
        setVersionCaption("Version auswählen")
        updateIdentity()
        discover()
    }

    /// Repeated selection notifications must not reset a chosen historical version.
    func follow(directory: URL?, selection: URL?, isDirectory: Bool) {
        let context = FollowContext(directory: directory?.standardizedFileURL,
                                    selection: selection?.standardizedFileURL, isDirectory: isDirectory)
        guard context != followedContext else { return }
        let selectedSource = source.selectedSegment
        let selectedContent = pendingContentMode ?? contentMode.selectedSegment
        if let directory {
            open(directory: directory, selectedFile: selection, isDirectory: isDirectory)
            source.selectedSegment = selectedSource
            contentMode.selectedSegment = !isDirectory && selection != nil ? selectedContent : 0
            pendingContentMode = contentMode.selectedSegment
            updateControls()
        } else {
            stop()
            self.directory = nil; selectedFile = nil; selectionIsDirectory = false
            repository = nil; path = nil; entries = []
            scope.removeAllItems(); scope.addItem(withTitle: "Auswahl im anderen Panel")
            versions.removeAllItems(); details.stringValue = ""; details.toolTip = nil
            commitTitle.stringValue = "Keine Auswahl"
            setVersionCaption("Keine Versionen")
            updateIdentity()
            let message = "Im anderen Panel einen lokalen Ordner, eine Datei oder ein Verzeichnis auswählen."
            status.stringValue = "Folgt dem anderen Panel"
            diff.showMessage(message)
            updateControls()
        }
        followedContext = context
    }

    func refresh() {
        guard directory != nil else { return }
        if repository == nil { discover() } else { loadHistory() }
    }

    /// Invalidate every outstanding result before hiding or replacing this pane.
    func stop() {
        generation += 1; previewGeneration += 1
        loading = false
        followedContext = nil
        pendingContentMode = nil
    }

    private func discover() {
        guard let directory else { return }
        generation += 1; previewGeneration += 1
        let request = generation
        loading = true; updateControls()
        status.stringValue = "Repository wird gelesen …"
        diff.showMessage("Git-Verlauf wird geladen …")
        let selectedFile = self.selectedFile
        queue.async { [weak self] in
            let result = Result { try GitRepository(directory: directory) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.loading = false
                switch result {
                case .success(let repository):
                    self.repository = repository
                    self.path = selectedFile.flatMap { GitPanelPaths.relativePath(for: $0, in: repository.root) }
                    self.scope.removeAllItems(); self.scope.addItem(withTitle: "Repository")
                    if let path = self.path {
                        self.scope.addItem(withTitle: self.selectionIsDirectory ? "Verzeichnisverlauf" : "Dateiverlauf")
                        self.scope.lastItem?.toolTip = path
                        self.scope.selectItem(at: 1)
                    }
                    if let pending = self.pendingContentMode, self.path != nil, !self.selectionIsDirectory {
                        self.contentMode.selectedSegment = pending
                    }
                    self.pendingContentMode = nil
                    self.updateIdentity()
                    self.scope.toolTip = "Folgt der Auswahl im anderen Panel\n" + repository.root.path
                    self.loadHistory()
                case .failure(let error):
                    self.commitTitle.stringValue = "Kein Git-Repository"
                    self.status.stringValue = error.localizedDescription
                    self.diff.showMessage(error.localizedDescription)
                    self.updateControls()
                }
            }
        }
    }

    private func updateIdentity() {
        let selected = repository == nil || scopedPath != nil ? selectedFile : nil
        targetTitle.stringValue = selected?.lastPathComponent ?? repository?.root.lastPathComponent ?? directory?.lastPathComponent ?? "Git-Verlauf"
        targetTitle.toolTip = selected?.path ?? directory?.path
        let name = repository?.root.lastPathComponent ?? directory?.lastPathComponent
        sourceLabel.stringValue = name.map { $0 + " · aus dem anderen Panel" } ?? "Folgt der Auswahl im anderen Panel"
        sourceLabel.toolTip = selected?.path ?? directory?.path
        targetIcon.image = NSImage(systemSymbolName: selected == nil ? "arrow.triangle.branch" : (selectionIsDirectory ? "folder" : "doc.text"), accessibilityDescription: nil)
    }

    private var scopedPath: String? { scope.indexOfSelectedItem == 1 ? path : nil }
    private var selectedEntry: GitHistoryEntry? {
        entries.indices.contains(versions.indexOfSelectedItem) ? entries[versions.indexOfSelectedItem] : nil
    }

    private func loadHistory(preserveSelection: Bool = true) {
        guard let repository else { return }
        let selectedID = preserveSelection ? selectedEntry?.commit.id : nil
        let path = scopedPath
        let isDirectory = path != nil && selectionIsDirectory
        generation += 1; previewGeneration += 1
        let request = generation
        loading = true; updateControls()
        status.stringValue = "Versionen werden gelesen …"
        details.stringValue = ""
        commitTitle.stringValue = "Versionen werden geladen …"
        diff.showMessage("Git-Verlauf wird geladen …")
        queue.async { [weak self] in
            let result = Result { try repository.historyEntries(path: path, isDirectory: isDirectory, limit: 200) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request else { return }
                self.loading = false
                self.entries = []; self.versions.removeAllItems()
                switch result {
                case .success(let entries):
                    self.entries = entries
                    for entry in entries {
                        let commit = entry.commit
                        self.versions.addItem(withTitle: "\(commit.shortID) · \(commit.subject)")
                        self.versions.lastItem?.toolTip = commit.author + " · " + Self.dateFormatter.string(from: commit.date)
                    }
                    if let selectedID, let index = entries.firstIndex(where: { $0.commit.id == selectedID }) {
                        self.versions.selectItem(at: index)
                    }
                    self.showSelection()
                case .failure(let error):
                    self.commitTitle.stringValue = "Verlauf nicht verfügbar"
                    self.status.stringValue = error.localizedDescription
                    self.diff.showMessage(error.localizedDescription)
                    self.updateControls()
                }
            }
        }
    }

    private func updateControls() {
        let hasRepository = repository != nil && !loading
        let history = source.selectedSegment == 0
        scope.isEnabled = hasRepository && path != nil
        source.isEnabled = hasRepository
        reloadButton.isEnabled = !loading && directory != nil
        versions.isEnabled = hasRepository && history && !entries.isEmpty
        older.isEnabled = versions.isEnabled && versions.indexOfSelectedItem < entries.count - 1
        newer.isEnabled = versions.isEnabled && versions.indexOfSelectedItem > 0
        contentMode.setEnabled(hasRepository && history && scopedPath != nil && !selectionIsDirectory && selectedEntry != nil, forSegment: 1)
        if !history || scopedPath == nil || selectionIsDirectory { contentMode.selectedSegment = 0 }
        contentMode.isEnabled = hasRepository && history && selectedEntry != nil
    }

    @objc private func scopeChanged() {
        onActivate?(); contentMode.selectedSegment = 0
        updateIdentity()
        loadHistory(preserveSelection: false)
    }
    @objc private func reload() { onActivate?(); refresh() }
    @objc private func closeViewer() { onActivate?(); onClose?() }
    @objc private func previousVersion() {
        let index = versions.indexOfSelectedItem + 1
        guard entries.indices.contains(index) else { return }
        onActivate?(); versions.selectItem(at: index); showSelection()
    }
    @objc private func nextVersion() {
        let index = versions.indexOfSelectedItem - 1
        guard entries.indices.contains(index) else { return }
        onActivate?(); versions.selectItem(at: index); showSelection()
    }

    @objc private func showSelection() {
        previewGeneration += 1
        let preview = previewGeneration
        updateControls()
        guard !loading, let repository else { return }
        let selectedSource = source.selectedSegment
        let entry = selectedEntry
        let path = scopedPath
        let isDirectory = path != nil && selectionIsDirectory
        let fileContent = contentMode.selectedSegment == 1 && selectedSource == 0 && path != nil && !isDirectory
        let count = entries.count >= 200 ? "Neueste 200 Commits" : (entries.count == 1 ? "1 Commit" : "\(entries.count) Commits")
        if selectedSource == 0 {
            guard let entry else {
                details.stringValue = ""
                commitTitle.stringValue = "Noch keine Versionen"
                setVersionCaption("Keine Versionen")
                status.stringValue = "Keine Versionen · " + (path ?? repository.root.lastPathComponent)
                diff.showMessage(path == nil ? "Dieses Repository hat noch keine Commits." : "Für \(isDirectory ? "dieses Verzeichnis" : "diese Datei") gibt es noch keine Versionen.")
                return
            }
            commitTitle.stringValue = entry.commit.subject
            commitTitle.toolTip = entry.commit.subject
            details.stringValue = "\(entry.commit.shortID) · \(entry.commit.author) · \(Self.dateFormatter.string(from: entry.commit.date))"
            setVersionCaption("Version \(versions.indexOfSelectedItem + 1) von \(entries.count)")
            details.toolTip = entry.commit.id + "\n" + entry.commit.subject
            status.stringValue = "Version \(versions.indexOfSelectedItem + 1) / \(entries.count) · \(count) · Vorschau wird gelesen …"
        } else {
            commitTitle.stringValue = selectedSource == 1 ? "Änderungen der Arbeitskopie" : "Vorgemerkte Änderungen"
            commitTitle.toolTip = nil
            details.stringValue = selectedSource == 1 ? "Vergleich mit dem Index" : "Vergleich mit HEAD"
            setVersionCaption(selectedSource == 1 ? "Arbeitskopie" : "Staged")
            details.toolTip = nil
            status.stringValue = "Diff wird gelesen …"
        }
        diff.showMessage("Vorschau wird gelesen …")
        queue.async { [weak self] in
            let result = Result { () -> GitDiffDocument in
                if selectedSource == 0, let entry {
                    if fileContent {
                        let value = try repository.historyFile(entry)
                        guard !value.contains("\0") else { return .message("Binärdatei: Bitte die Diff-Ansicht verwenden.") }
                        return .message(value.isEmpty ? "[Leere Datei]" : value)
                    }
                    let patch = try repository.historyDiff(entry)
                    // Metadata is presented in the commit card. Only strip the
                    // preamble of Git's patch output, never a historical file.
                    guard let start = patch.range(of: "(?m)^diff --git ", options: .regularExpression) else {
                        return .message("Diese Version enthält keine Dateiänderungen.")
                    }
                    return GitDiffDocument(patch: String(patch[start.lowerBound...]))
                }
                let value = try repository.diff(path: path, staged: selectedSource == 2)
                if value.isEmpty, selectedSource == 1, !isDirectory, let path,
                   try repository.snapshot().files.contains(where: { $0.path == path && $0.isUntracked }) {
                    return try Self.untrackedPreview(at: repository.root.appendingPathComponent(path), path: path)
                }
                return value.isEmpty ? .message("Keine \(selectedSource == 2 ? "vorgemerkten" : "nicht vorgemerkten") Änderungen.") : GitDiffDocument(patch: value)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewGeneration == preview else { return }
                switch result {
                case .success(let document):
                    self.diff.show(document)
                    self.status.stringValue = count + " · Folgt der Auswahl im anderen Panel"
                case .failure(let error):
                    self.diff.showMessage(error.localizedDescription)
                    self.status.stringValue = error.localizedDescription
                }
            }
        }
    }

    private static func untrackedPreview(at url: URL, path: String) throws -> GitDiffDocument {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return .message("Keine reguläre Datei für die Vorschau.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 1024 * 1024
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard !data.contains(0), let value = String(data: data.prefix(limit), encoding: .utf8) else {
            return .message("Binärdatei oder Datei mit anderer Textcodierung.")
        }
        return .addedFile(name: path, content: value, truncated: data.count > limit)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
        return formatter
    }()
}

/// A quiet, opaque grouping surface that follows both the selected theme and
/// native light/dark appearance without rebuilding the controls it contains.
private final class GitHistoryCard: NSView {
    private let tint: CGFloat
    private let bordered: Bool
    private var observer: NSObjectProtocol?

    init(tint: CGFloat, bordered: Bool = true) {
        self.tint = tint; self.bordered = bordered
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        observer = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateColors()
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let surface = ThemeManager.surfaceColor.blended(withFraction: 0.25, of: .controlBackgroundColor) ?? ThemeManager.surfaceColor
            layer?.backgroundColor = (surface.blended(withFraction: tint, of: ThemeManager.accentColor) ?? surface).cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
            layer?.borderWidth = bordered ? 0.5 : 0
        }
    }
}
