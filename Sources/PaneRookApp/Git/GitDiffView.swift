import AppKit

/// Both presentations share one parsed patch. Changing presentation never reads Git again.
final class GitDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let presentation = NSSegmentedControl(labels: ["Unified Diff", "Side-by-Side Diff"],
        trackingMode: .selectOne, target: nil, action: nil)
    private let unified = NSTextView()
    private let unifiedScroll = NSScrollView()
    private let sideBySide = NSView()
    private let leftScroll = NSScrollView()
    private let rightScroll = NSScrollView()
    private let leftTable = DiffTableView()
    private let rightTable = DiffTableView()
    private let toolbarSurface = NSView()
    private let toolbarDivider = NSBox()
    private var document = GitDiffDocument.message("")
    private var observers: [NSObjectProtocol] = []
    private var synchronizingScroll = false
    private var synchronizingSelection = false
    private var leftCodeWidth: CGFloat = 300
    private var rightCodeWidth: CGFloat = 300
    private var gutterWidth: CGFloat = 44
    private var codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var paneStyle = false
    private var presentationTop: NSLayoutConstraint?
    private var presentationLeading: NSLayoutConstraint?
    private var contentGap: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        presentation.selectedSegment = 0
        presentation.controlSize = .small
        presentation.setContentHuggingPriority(.required, for: .vertical)
        presentation.target = self
        presentation.action = #selector(presentationChanged)
        presentation.setAccessibilityLabel("Diff-Darstellung")

        unified.isEditable = false
        unified.isSelectable = true
        unified.isRichText = false
        unified.font = codeFont
        unified.textContainerInset = NSSize(width: 10, height: 10)
        unified.autoresizingMask = [.width]
        unified.isVerticallyResizable = true
        unified.isHorizontallyResizable = false
        unified.textContainer?.widthTracksTextView = true
        unified.setAccessibilityLabel("Git-Diff und Versionsvorschau")
        unifiedScroll.documentView = unified
        unifiedScroll.hasVerticalScroller = true
        unifiedScroll.borderType = .bezelBorder

        configure(leftTable, scroll: leftScroll, title: "Vorher", accessibility: "Git-Diff: Vorher")
        configure(rightTable, scroll: rightScroll, title: "Nachher", accessibility: "Git-Diff: Nachher")
        leftTable.copyRows = { [weak self] rows in self?.copiedText(rows: rows, left: true) ?? "" }
        rightTable.copyRows = { [weak self] rows in self?.copiedText(rows: rows, left: false) ?? "" }

        // Keep the unified text view first for native text navigation and accessibility.
        for child in [presentation, unifiedScroll, sideBySide] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.setContentHuggingPriority(.defaultLow, for: .vertical)
        for child in [leftScroll, divider, rightScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            sideBySide.addSubview(child)
        }
        let presentationLeading = presentation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        let presentationTop = presentation.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        let contentGap = unifiedScroll.topAnchor.constraint(equalTo: presentation.bottomAnchor, constant: 4)
        self.presentationLeading = presentationLeading
        self.presentationTop = presentationTop
        self.contentGap = contentGap
        NSLayoutConstraint.activate([
            presentationLeading,
            presentationTop,
            presentation.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            contentGap,
            unifiedScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            unifiedScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            unifiedScroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            sideBySide.topAnchor.constraint(equalTo: unifiedScroll.topAnchor),
            sideBySide.leadingAnchor.constraint(equalTo: leadingAnchor),
            sideBySide.trailingAnchor.constraint(equalTo: trailingAnchor),
            sideBySide.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftScroll.leadingAnchor.constraint(equalTo: sideBySide.leadingAnchor),
            leftScroll.topAnchor.constraint(equalTo: sideBySide.topAnchor),
            leftScroll.bottomAnchor.constraint(equalTo: sideBySide.bottomAnchor),
            leftScroll.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: sideBySide.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sideBySide.bottomAnchor),
            rightScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            rightScroll.trailingAnchor.constraint(equalTo: sideBySide.trailingAnchor),
            rightScroll.topAnchor.constraint(equalTo: sideBySide.topAnchor),
            rightScroll.bottomAnchor.constraint(equalTo: sideBySide.bottomAnchor),
            leftScroll.widthAnchor.constraint(equalTo: rightScroll.widthAnchor)
        ])
        toolbarSurface.translatesAutoresizingMaskIntoConstraints = false
        toolbarSurface.wantsLayer = true
        toolbarSurface.isHidden = true
        addSubview(toolbarSurface, positioned: .below, relativeTo: presentation)
        toolbarDivider.boxType = .separator
        toolbarDivider.translatesAutoresizingMaskIntoConstraints = false
        toolbarDivider.isHidden = true
        addSubview(toolbarDivider)
        NSLayoutConstraint.activate([
            toolbarSurface.topAnchor.constraint(equalTo: topAnchor),
            toolbarSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarSurface.bottomAnchor.constraint(equalTo: unifiedScroll.topAnchor),
            toolbarDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarDivider.topAnchor.constraint(equalTo: unifiedScroll.topAnchor),
            toolbarDivider.heightAnchor.constraint(equalToConstant: 1)
        ])
        sideBySide.isHidden = true
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                    guard let self, let scroll else { return }
                    self.synchronizeScroll(from: scroll)
                })
        }
        observers.append(NotificationCenter.default.addObserver(forName: ThemeManager.didChange,
            object: nil, queue: .main) { [weak self] _ in self?.updatePaneColors() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePaneColors()
    }

    /// Pane-specific reading treatment. The repository workspace keeps its existing layout.
    func usePaneStyle() {
        guard !paneStyle else { return }
        paneStyle = true
        codeFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        presentation.controlSize = .regular
        presentation.font = .systemFont(ofSize: 12, weight: .medium)
        presentation.setLabel("Unified", forSegment: 0)
        presentation.setLabel("Nebeneinander", forSegment: 1)
        presentationTop?.constant = 10
        presentationLeading?.constant = 12
        contentGap?.constant = 10
        unified.font = codeFont
        unified.textContainerInset = NSSize(width: 16, height: 14)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        toolbarSurface.isHidden = false
        toolbarDivider.isHidden = false
        for scroll in [unifiedScroll, leftScroll, rightScroll] { scroll.borderType = .noBorder }
        for table in [leftTable, rightTable] { table.rowHeight = 22 }
        updatePaneColors()
        // Recalculate widths for the larger code font without changing presentation.
        show(document)
    }

    private func updatePaneColors() {
        guard paneStyle else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let surface = ThemeManager.surfaceColor
            layer?.backgroundColor = surface.cgColor
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
            toolbarSurface.layer?.backgroundColor = (surface.blended(withFraction: 0.035,
                of: ThemeManager.accentColor) ?? surface).cgColor
            unified.backgroundColor = surface
            unified.insertionPointColor = .labelColor
            for scroll in [unifiedScroll, leftScroll, rightScroll] {
                scroll.backgroundColor = surface
                scroll.contentView.backgroundColor = surface
            }
            for table in [leftTable, rightTable] { table.backgroundColor = surface }
            let selected = unified.selectedRanges
            renderUnified(document.unified)
            unified.selectedRanges = selected
            // Cell labels and row backgrounds carry semantic colors and must be rebuilt
            // when the accent palette changes while this view is already open.
            synchronizingSelection = true
            for table in [leftTable, rightTable] {
                let rows = table.selectedRowIndexes
                table.reloadData()
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
            synchronizingSelection = false
        }
    }

    override func layout() {
        super.layout()
        updateColumns(leftTable, in: leftScroll, codeWidth: leftCodeWidth)
        updateColumns(rightTable, in: rightScroll, codeWidth: rightCodeWidth)
    }

    func show(_ document: GitDiffDocument) {
        self.document = document
        renderUnified(document.unified)
        let advance = ("M" as NSString).size(withAttributes: [.font: codeFont]).width
        leftCodeWidth = codeWidth(for: document.rows.compactMap(\.left), advance: advance)
        rightCodeWidth = codeWidth(for: document.rows.compactMap(\.right), advance: advance)
        let greatestNumber = document.rows.flatMap { [$0.left?.number, $0.right?.number] }.compactMap { $0 }.max() ?? 1
        gutterWidth = max(44, ceil(CGFloat(String(greatestNumber).count) * advance) + 16)
        synchronizingSelection = true
        for table in [leftTable, rightTable] {
            table.deselectAll(nil)
            table.reloadData()
        }
        synchronizingSelection = false
        needsLayout = true
        resetScrollPositions()
    }

    func showMessage(_ message: String) { show(.message(message)) }

    private func configure(_ table: NSTableView, scroll: NSScrollView, title: String, accessibility: String) {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autoresizingMask = []
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.setAccessibilityLabel(accessibility)
        let number = NSTableColumn(identifier: .init("line"))
        number.title = "Zeile"
        number.width = gutterWidth
        number.minWidth = 0
        number.maxWidth = .greatestFiniteMagnitude
        number.resizingMask = []
        let code = NSTableColumn(identifier: .init("code"))
        code.title = title
        code.width = 300
        code.minWidth = 0
        code.maxWidth = .greatestFiniteMagnitude
        code.resizingMask = []
        table.addTableColumn(number)
        table.addTableColumn(code)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
    }

    private func updateColumns(_ table: NSTableView, in scroll: NSScrollView, codeWidth: CGFloat) {
        let width = max(scroll.contentSize.width, gutterWidth + codeWidth)
        if table.tableColumns[0].width != gutterWidth { table.tableColumns[0].width = gutterWidth }
        let available = width - gutterWidth
        if table.tableColumns[1].width != available { table.tableColumns[1].width = available }
        if table.frame.width != width {
            var frame = table.frame
            frame.size.width = width
            table.frame = frame
        }
    }

    func setPresentation(_ index: Int) {
        guard (0...1).contains(index) else { return }
        presentation.selectedSegment = index
        presentationChanged()
    }

    @objc private func presentationChanged() {
        let side = presentation.selectedSegment == 1
        unifiedScroll.isHidden = side
        sideBySide.isHidden = !side
        needsLayout = true
    }

    private func renderUnified(_ text: String) {
        var attributes: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: NSColor.labelColor]
        if paneStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 22
            paragraph.maximumLineHeight = 22
            attributes[.paragraphStyle] = paragraph
        }
        let value = NSMutableAttributedString(string: text, attributes: attributes)
        var inHunk = false
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, enclosing, _ in
            guard let line else { return }
            let range = NSRange(enclosing, in: text)
            if line.hasPrefix("diff --") { inHunk = false }
            if line.hasPrefix("@@") {
                inHunk = true
                value.addAttribute(.foregroundColor, value: self.paneStyle ? ThemeManager.accentColor : NSColor.systemBlue, range: range)
                if self.paneStyle {
                    value.addAttribute(.backgroundColor, value: ThemeManager.accentColor.withAlphaComponent(0.07), range: range)
                }
            } else if inHunk && line.hasPrefix("+") {
                value.addAttributes([.foregroundColor: NSColor.systemGreen,
                                     .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.09)], range: range)
            } else if inHunk && line.hasPrefix("-") {
                value.addAttributes([.foregroundColor: NSColor.systemRed,
                                     .backgroundColor: NSColor.systemRed.withAlphaComponent(0.09)], range: range)
            } else if self.paneStyle && line.hasPrefix("diff --") {
                value.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                                     .foregroundColor: NSColor.labelColor], range: range)
            } else if !inHunk {
                value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            }
        }
        unified.textStorage?.setAttributedString(value)
    }

    private func resetScrollPositions() {
        unified.scrollToBeginningOfDocument(nil)
        synchronizingScroll = true
        for scroll in [leftScroll, rightScroll] {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        synchronizingScroll = false
    }

    private func synchronizeScroll(from source: NSScrollView) {
        guard !synchronizingScroll else { return }
        synchronizingScroll = true
        defer { synchronizingScroll = false }
        let target = source === leftScroll ? rightScroll : leftScroll
        var origin = target.contentView.bounds.origin
        origin.y = source.contentView.bounds.origin.y
        target.contentView.scroll(to: origin)
        target.reflectScrolledClipView(target.contentView)
    }

    private func expanded(_ text: String) -> String { text.replacingOccurrences(of: "\t", with: "    ") }

    private func codeWidth(for lines: [GitDiffLine], advance: CGFloat) -> CGFloat {
        let width = lines.reduce(CGFloat(0)) { maximum, line in
            let text = expanded(line.text)
            // Fallback glyphs such as CJK characters can be wider than one
            // monospace cell. Measure those lines so horizontal scrolling can
            // reach their complete content.
            let rendered = text.utf8.allSatisfy { $0 < 128 }
                ? CGFloat(text.utf8.count) * advance
                : (text as NSString).size(withAttributes: [.font: codeFont]).width
            return max(maximum, rendered)
        }
        return max(300, ceil(width) + 16)
    }

    private func copiedText(rows: IndexSet, left: Bool) -> String {
        rows.compactMap { index -> String? in
            guard document.rows.indices.contains(index) else { return nil }
            let row = document.rows[index]
            return (left ? row.left : row.right)?.text
        }.joined(separator: "\n")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { document.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard document.rows.indices.contains(row) else { return nil }
        let item = document.rows[row]
        let line = tableView === leftTable ? item.left : item.right
        let number = tableColumn?.identifier.rawValue == "line"
        let label = NSTextField(labelWithString: number ? line?.number.map(String.init) ?? "" : expanded(line?.text ?? ""))
        label.font = codeFont
        label.textColor = number || item.kind == .metadata ? .secondaryLabelColor : .labelColor
        if paneStyle && item.kind == .metadata && line?.text.hasPrefix("@@") == true {
            label.textColor = ThemeManager.accentColor
        }
        label.alignment = number ? .right : .left
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.isSelectable = !number
        label.toolTip = line?.text
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard document.rows.indices.contains(row) else { return nil }
        let item = document.rows[row]
        let left = tableView === leftTable
        let line = left ? item.left : item.right
        let color: NSColor
        if line == nil { color = .quaternaryLabelColor.withAlphaComponent(0.15) }
        else if item.kind == .change { color = (left ? NSColor.systemRed : .systemGreen).withAlphaComponent(0.12) }
        else if paneStyle && item.kind == .metadata && line?.text.hasPrefix("@@") == true {
            color = ThemeManager.accentColor.withAlphaComponent(0.07)
        }
        else if item.kind == .metadata { color = .separatorColor.withAlphaComponent(paneStyle ? 0.05 : 0.1) }
        else { color = .clear }
        return DiffRowView(color: color)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !synchronizingSelection, let source = notification.object as? NSTableView else { return }
        synchronizingSelection = true
        let target = source === leftTable ? rightTable : leftTable
        target.selectRowIndexes(source.selectedRowIndexes, byExtendingSelection: false)
        synchronizingSelection = false
    }
}

private final class DiffRowView: NSTableRowView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        color.setFill()
        bounds.fill()
    }
}

private final class DiffTableView: NSTableView {
    var copyRows: ((IndexSet) -> String)?
    @objc func copy(_ sender: Any?) {
        guard !selectedRowIndexes.isEmpty, let text = copyRows?(selectedRowIndexes) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
