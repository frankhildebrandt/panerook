import AppKit
import PaneRookCore

final class SparseFileDialog: NSWindowController {
    struct Request {
        let name: String
        let logicalSize: Int64
    }
    private let name = NSTextField(string: "Sparse-Datei.img")
    private let size = NSTextField(string: "1")
    private let unit = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let directory: URL
    private let completion: (Request?) -> Void
    private var acceptedRequest: Request?

    init(directory: URL, completion: @escaping (Request?) -> Void) {
        self.directory = directory
        self.completion = completion
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 270),
                              styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Sparse-Datei erstellen"
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak self] in self?.cancel(nil) }
        panel.contentView = AppStyle.background(material: .sheet)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        let path = NSTextField(labelWithString: directory.path)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = directory.path
        stack.addArrangedSubview(path)
        stack.setCustomSpacing(14, after: path)
        func label(_ title: String) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.font = .systemFont(ofSize: 12, weight: .medium)
            return field
        }
        stack.addArrangedSubview(label("Name"))
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(label("Logische Größe"))
        unit.addItems(withTitles: SparseFileUnit.allCases.map(\.label))
        unit.selectItem(at: SparseFileUnit.allCases.firstIndex(of: .gibibytes) ?? 0)
        unit.setAccessibilityLabel("Größeneinheit")
        unit.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let sizeRow = NSStackView(views: [size, unit])
        sizeRow.spacing = 8
        stack.addArrangedSubview(sizeRow)
        name.setAccessibilityLabel("Dateiname")
        size.setAccessibilityLabel("Logische Größe")
        size.toolTip = "Speicher wird erst beim Schreiben belegt. Dezimalzahlen mit Punkt oder Komma sind möglich."
        for field in [name, size] {
            AppStyle.configureField(field)
            field.cell?.isScrollable = true
            field.cell?.sendsActionOnEndEditing = false
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            field.target = self
            field.action = #selector(confirm(_:))
        }
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityLabel("Fehler beim Erstellen")
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel(_:)))
        let create = NSButton(title: "Erstellen", target: self, action: #selector(confirm(_:)))
        for button in [cancel, create] { AppStyle.configureButton(button) }
        ContextCommands.configure(cancel, id: "dialog.cancel")
        ContextCommands.configure(create, id: "dialog.accept")
        let buttons = NSStackView(views: [NSView(), cancel, create])
        buttons.spacing = 10
        stack.addArrangedSubview(buttons)
        name.nextKeyView = size
        size.nextKeyView = unit
        unit.nextKeyView = cancel
        cancel.nextKeyView = create
        create.nextKeyView = name
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460)
        ])
        panel.setContentSize(stack.fittingSize)
        panel.initialFirstResponder = name
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in completion(acceptedRequest) }
        window.makeFirstResponder(name)
        name.selectText(nil)
    }
    @objc private func confirm(_ sender: Any?) {
        // Field focus changes must never create a file. Only an explicit Return
        // in a field or the default button can accept this dialog.
        if sender is NSTextField {
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  ContextCommands.matching(event, scope: .dialog)?.hasPrefix("dialog.accept") == true else { return }
        }
        guard acceptedRequest == nil else { return }
        do {
            try FileActions.validateName(name.stringValue)
            let bytes = try SparseFile.logicalSize(from: size.stringValue, unit: SparseFileUnit.allCases[unit.indexOfSelectedItem])
            let target = directory.appendingPathComponent(name.stringValue)
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                throw FileActionError.collision(name.stringValue)
            }
            acceptedRequest = Request(name: name.stringValue, logicalSize: bytes)
            if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: .OK) }
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            if let window, let content = window.contentView {
                content.layoutSubtreeIfNeeded()
                window.setContentSize(content.fittingSize)
            }
            NSSound.beep()
        }
    }
    @objc private func cancel(_ sender: Any?) {
        acceptedRequest = nil
        if let window, let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
    }
}
