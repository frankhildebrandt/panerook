import AppKit

/// Tabs retain their controllers, including navigation generations and live shells.
/// Switching only mounts a different view; it never disconnects a connection.
final class PanelTabGroupController: NSViewController {
    private(set) var panes: [PaneController]
    private(set) var selected: PaneController
    var onSelect: ((PaneController) -> Void)?
    var onNew: (() -> Void)?
    var onClose: (() -> Void)?
    private let tabs = NSSegmentedControl()
    private let host = NSView()
    private let scroll = NSScrollView()

    init(panes: [PaneController], selected: PaneController? = nil) {
        precondition(!panes.isEmpty)
        self.panes = panes; self.selected = selected ?? panes[0]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func loadView() {
        view = NSView()
        tabs.trackingMode = .selectOne; tabs.target = self; tabs.action = #selector(selectTab)
        tabs.setAccessibilityLabel("Panel-Tabs")
        scroll.documentView = tabs; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let add = NSButton(title: "+", target: self, action: #selector(newTab))
        add.setAccessibilityLabel("Neuer Tab"); add.toolTip = "Neuer Tab"
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Tab schließen")!, target: self, action: #selector(closeTab))
        close.toolTip = "Aktiven Tab schließen"
        for button in [add, close] { AppStyle.configureButton(button); button.controlSize = .small }
        let bar = NSStackView(views: [scroll, add, close])
        bar.spacing = 4
        for item in [bar, host] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4), bar.heightAnchor.constraint(equalToConstant: 32),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 80), scroll.heightAnchor.constraint(equalToConstant: 27),
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let top = host.topAnchor.constraint(equalTo: bar.bottomAnchor)
        top.isActive = true
        mount()
    }
    func select(_ pane: PaneController, notify: Bool = true) {
        guard panes.contains(where: { $0 === pane }) else { return }
        selected.isActive = false
        selected = pane
        if isViewLoaded { mount() }
        if notify { onSelect?(pane) }
    }
    func append(_ pane: PaneController) { panes.append(pane); select(pane) }
    func removeSelected() -> PaneController? {
        guard panes.count > 1, let index = panes.firstIndex(where: { $0 === selected }) else { return nil }
        let old = selected
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
        tabs.segmentCount = panes.count
        for (index, pane) in panes.enumerated() {
            tabs.setLabel(pane.tabTitle, forSegment: index)
            tabs.setToolTip(pane.tabLocationDescription, forSegment: index)
            tabs.setWidth(150, forSegment: index)
        }
        tabs.selectedSegment = panes.firstIndex(where: { $0 === selected }) ?? 0
        tabs.frame = NSRect(x: 0, y: 0, width: max(150, CGFloat(panes.count) * 150), height: 25)
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
    @objc private func selectTab() { if panes.indices.contains(tabs.selectedSegment) { select(panes[tabs.selectedSegment]) } }
    @objc private func newTab() { onNew?() }
    @objc private func closeTab() { onClose?() }
}
