import AppKit

final class ClosureAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

final class ToolPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if ((event.keyCode == 53 || event.keyCode == 109) && flags.isEmpty)
            || (event.keyCode == 5 && flags == .control) {
            onCancel?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum ToolUI {
    static func field(_ text: String = "", width: CGFloat = 440) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        field.stringValue = text
        AppStyle.configureField(field)
        return field
    }
    static func form(_ rows: [(String, NSView)], width: CGFloat = 440) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for (label, control) in rows {
            if !label.isEmpty {
                let title = NSTextField(labelWithString: label)
                title.font = .systemFont(ofSize: 12)
                stack.addArrangedSubview(title)
                control.setAccessibilityLabel(label)
            }
            stack.addArrangedSubview(control)
            control.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        return stack
    }
    static func prompt(owner: any PanelPresenting, title: String, label: String, value: String = "",
                       accept: String = "OK", completion: @escaping (String) -> Void) {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let pane = owner.activePane
        let alert = NSAlert()
        alert.messageText = title
        let input = field(value)
        alert.accessoryView = form([(label, input)])
        alert.addButton(withTitle: accept)
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak owner] result in
            owner?.activate(pane)
            if result == .alertFirstButtonReturn { completion(input.stringValue) }
        }
    }
    static func choose(owner: any PanelPresenting, title: String, labels: [String],
                       accept: String = "Öffnen", extra: String? = nil,
                       completion: @escaping (Int, Bool) -> Void) {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let pane = owner.activePane
        let alert = NSAlert()
        alert.messageText = title
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 28))
        popup.addItems(withTitles: labels.isEmpty ? ["Keine Einträge"] : labels)
        popup.isEnabled = !labels.isEmpty
        alert.accessoryView = popup
        alert.addButton(withTitle: accept).isEnabled = !labels.isEmpty
        if let extra { alert.addButton(withTitle: extra) }
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        alert.window.initialFirstResponder = popup
        alert.beginSheetModal(for: window) { [weak owner] result in
            owner?.activate(pane)
            if result == .alertFirstButtonReturn { completion(popup.indexOfSelectedItem, false) }
            else if extra != nil && result == .alertSecondButtonReturn { completion(popup.indexOfSelectedItem, true) }
        }
    }
}

final class TextResultWindow: NSWindowController {
    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let stop = NSButton(title: "Abbrechen", target: nil, action: nil)
    private var stopAction: ClosureAction?
    var onCancel: (() -> Void)?
    init(title: String, content: String = "") {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 540),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 460, height: 260)
        panel.center()
        let root = NSStackView()
        root.orientation = .vertical; root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = AppStyle.background()
        panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        text.isEditable = false; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        root.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -24).isActive = true
        let footer = NSStackView(views: [status, NSView(), stop])
        footer.spacing = 12
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        stopAction = ClosureAction { [weak self] in
            guard let self else { return }
            if let onCancel = self.onCancel { onCancel() } else { self.close() }
        }
        stop.target = stopAction; stop.action = #selector(ClosureAction.invoke(_:))
        AppStyle.configureButton(stop)
        panel.onCancel = { [weak self] in self?.stop.performClick(nil) }
        setContent(content, status: "", running: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setContent(_ value: String, status label: String, running: Bool) {
        text.string = value
        status.stringValue = label
        stop.title = running ? "Abbrechen" : "Schließen"
        if !running { onCancel = nil }
    }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
