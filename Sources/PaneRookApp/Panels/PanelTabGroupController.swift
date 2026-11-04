import AppKit
import PaneRookPanels

/// Tabs retain their controllers, including navigation generations and live shells.
/// Switching only mounts a different view; it never disconnects a connection.
final class PanelTabGroupController: NSViewController {
    private(set) var panes: [PaneController]
    private(set) var selected: PaneController
    var onSelect: ((PaneController) -> Void)?
    var onNew: (() -> Void)?
    var onClose: (() -> Void)?
    private let tabs = NSView()
    private var tabViews: [PanelTabView] = []
    private let host = NSView()
    private let scroll = NSScrollView()
    private let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    private let modeSelector = NSPopUpButton()
    private let context = NSTextField(labelWithString: "")
    private let returnToFiles = NSButton()
    private var themeObserver: NSObjectProtocol?
    private let modes: [(String, PanelMode)] = [
        ("Dateiliste", .listing), ("Vorschau", .quickView), ("Informationen", .info),
        ("Ordnerbaum", .tree), ("Netzwerk", .network), ("Git-Verlauf", .gitHistory), ("Terminal", .terminal)
    ]

    init(panes: [PaneController], selected: PaneController? = nil) {
        precondition(!panes.isEmpty)
        self.panes = panes; self.selected = selected ?? panes[0]
        super.init(nibName: nil, bundle: nil)
        for pane in panes { observePresentation(of: pane) }
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.tabViews.forEach { $0.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    override func loadView() {
        view = NSView()
        tabs.setAccessibilityLabel("Panel-Tabs")
        scroll.documentView = tabs
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .none
        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Neuer Tab")!, target: self, action: #selector(newTab))
        add.toolTip = "Neuer Tab"
        AppStyle.configureButton(add); add.controlSize = .small
        overflow.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Alle Tabs")
        overflow.imagePosition = .imageOnly
        (overflow.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        overflow.setAccessibilityLabel("Alle Tabs")
        overflow.toolTip = "Alle Tabs anzeigen"
        overflow.isBordered = false
        overflow.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let bar = NSStackView(views: [scroll, overflow, add]); bar.spacing = 4

        for (title, _) in modes { modeSelector.addItem(withTitle: title) }
        modeSelector.target = self; modeSelector.action = #selector(selectPanelMode)
        modeSelector.setAccessibilityLabel("Panelansicht")
        modeSelector.controlSize = .small
        modeSelector.widthAnchor.constraint(equalToConstant: 126).isActive = true
        context.font = .systemFont(ofSize: 11)
        context.textColor = .secondaryLabelColor
        context.lineBreakMode = .byTruncatingMiddle
        context.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.setAccessibilityLabel("Panelinhalt und Herkunft")
        returnToFiles.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Zur Dateiliste")
        returnToFiles.target = self; returnToFiles.action = #selector(showFiles)
        returnToFiles.toolTip = "Zur Dateiliste"
        returnToFiles.setAccessibilityLabel("Zur Dateiliste")
        returnToFiles.isBordered = false
        returnToFiles.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let header = NSStackView(views: [modeSelector, context, returnToFiles])
        header.spacing = 8
        for item in [bar, header, host] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), bar.heightAnchor.constraint(equalToConstant: 32),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 80), scroll.heightAnchor.constraint(equalToConstant: 28),
            header.topAnchor.constraint(equalTo: bar.bottomAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), header.heightAnchor.constraint(equalToConstant: 30),
            host.topAnchor.constraint(equalTo: header.bottomAnchor), host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        mount()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        revealSelectedTab()
    }
    private func observePresentation(of pane: PaneController) {
        pane.onPresentationChanged = { [weak self] in self?.updateTitles() }
    }
    func select(_ pane: PaneController, notify: Bool = true) {
        guard panes.contains(where: { $0 === pane }) else { return }
        selected.isActive = false
        selected = pane
        if isViewLoaded { mount() }
        if notify { onSelect?(pane) }
    }
    func append(_ pane: PaneController) { observePresentation(of: pane); panes.append(pane); select(pane) }
    func removeSelected() -> PaneController? {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === selected }) else { return nil }
        let old = selected
        old.onPresentationChanged = nil
        panes.remove(at: index)
        select(panes[min(index, panes.count - 1)])
        return old
    }
    func cycle(_ offset: Int) {
        guard let index = panes.firstIndex(where: { $0 === selected }) else { return }
        select(panes[(index + offset + panes.count) % panes.count])
    }
    func updateTitles() {
        guard isViewLoaded else { return }
        if tabViews.count != panes.count {
            for tab in tabViews { tab.removeFromSuperview() }
            tabViews = panes.map { _ in let tab = PanelTabView(); tabs.addSubview(tab); return tab }
        }
        var x: CGFloat = 0
        for (index, pane) in panes.enumerated() {
            let tab = tabViews[index]
            tab.configure(title: pane.tabTitle, location: pane.tabLocationDescription,
                          selected: pane === selected, canClose: panes.count > 1)
            tab.onSelect = { [weak self, weak pane] in if let pane { self?.select(pane) } }
            tab.onClose = { [weak self, weak pane] in
                guard let self, let pane, self.panes.count > 1 else { return }
                self.select(pane); self.onClose?()
            }
            let titleWidth = (pane.tabTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
            let width = min(240, max(110, ceil(titleWidth) + 48))
            tab.frame = NSRect(x: x, y: 0, width: width, height: 28)
            x += width + 4
        }
        tabs.frame = NSRect(x: 0, y: 0, width: max(0, x - 4), height: 28)
        overflow.removeAllItems(); overflow.addItem(withTitle: "Alle Tabs")
        overflow.item(at: 0)?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Alle Tabs")
        for (index, pane) in panes.enumerated() {
            let item = NSMenuItem(title: pane.tabTitle, action: #selector(selectOverflowTab(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = pane === selected ? .on : .off
            item.toolTip = pane.tabLocationDescription
            overflow.menu?.addItem(item)
        }
        modeSelector.selectItem(at: modes.firstIndex { $0.1 == selected.mode } ?? 0)
        for (index, mode) in modes.enumerated() { modeSelector.item(at: index)?.isEnabled = selected.canSelectPanelMode(mode.1) }
        modeSelector.menu?.autoenablesItems = false
        modeSelector.isEnabled = selected.remoteContent == nil
        context.stringValue = selected.panelContextDescription
        context.toolTip = selected.tabLocationDescription
        returnToFiles.isHidden = selected.mode == .listing || selected.remoteContent != nil
        revealSelectedTab()
    }
    private func revealSelectedTab() {
        guard let index = panes.firstIndex(where: { $0 === selected }), tabViews.indices.contains(index) else { return }
        let rect = tabViews[index].frame
        let visible = scroll.documentVisibleRect
        guard visible.width > 0 else { return }
        var x = visible.minX
        if rect.minX < visible.minX { x = rect.minX }
        else if rect.maxX > visible.maxX { x = rect.maxX - visible.width }
        x = min(max(0, x), max(0, tabs.bounds.width - visible.width))
        if abs(x - visible.minX) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: x, y: visible.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    private func mount() {
        for child in children { child.view.removeFromSuperview(); child.removeFromParent() }
        // A workspace can be mounted in another group container after restoration.
        selected.view.removeFromSuperview(); selected.removeFromParent()
        addChild(selected)
        let content = selected.view
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        updateTitles()
    }
    @objc private func selectOverflowTab(_ sender: NSMenuItem) { if panes.indices.contains(sender.tag) { select(panes[sender.tag]) } }
    @objc private func selectPanelMode() {
        let index = modeSelector.indexOfSelectedItem
        guard modes.indices.contains(index), selected.canSelectPanelMode(modes[index].1) else { return }
        selected.activate(); selected.setMode(modes[index].1)
        updateTitles()
    }
    @objc private func showFiles() { selected.activate(); selected.setMode(.listing); updateTitles() }
    @objc private func newTab() { onNew?() }
}

private final class PanelTabView: NSView {
    private let title = NSButton()
    private let close = NSButton()
    private var selected = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingMiddle
        title.isBordered = false
        title.target = self; title.action = #selector(selectTab)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Tab schließen")
        close.isBordered = false; close.controlSize = .small
        close.target = self; close.action = #selector(closeTab)
        for item in [title, close] { item.translatesAutoresizingMaskIntoConstraints = false; addSubview(item) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), title.topAnchor.constraint(equalTo: topAnchor),
            title.bottomAnchor.constraint(equalTo: bottomAnchor), title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 20), close.heightAnchor.constraint(equalToConstant: 22)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func configure(title text: String, location: String, selected: Bool, canClose: Bool) {
        title.title = text; title.toolTip = location
        title.setAccessibilityLabel("Tab: " + text)
        title.setAccessibilityValue(selected ? "Ausgewählt" : "")
        close.setAccessibilityLabel("Tab schließen: " + text)
        close.toolTip = canClose ? "Tab schließen: " + text : "Der letzte Tab bleibt geöffnet"
        close.isEnabled = canClose
        self.selected = selected
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 5, yRadius: 5)
        (selected ? ThemeManager.accentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (selected ? ThemeManager.accentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1; path.stroke()
    }
    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { if close.isEnabled { onClose?() } }
}
