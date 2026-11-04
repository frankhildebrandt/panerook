import AppKit
import PaneRookCore

final class TransferDialog: NSWindowController {
    private let mask = NSTextField(string: "*")
    private let destination = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let sources: [URL]
    private let sourceDirectory: URL
    private let kind: TransferKind
    private var acceptedPlan: TransferPlan?
    private let completion: (TransferPlan?) -> Void

    init(sources: [URL], sourceDirectory: URL, destinationDirectory: URL, kind: TransferKind,
         completion: @escaping (TransferPlan?) -> Void) {
        self.sources = sources
        self.sourceDirectory = sourceDirectory
        self.kind = kind
        self.completion = completion
        let panel = TransferPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 385),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = kind == .copy ? "Kopieren" : "Verschieben / Umbenennen"
        panel.onCancel = { [weak self] in self?.cancel(nil) }
        panel.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            return label
        }
        func hint(_ title: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        }
        let selection = NSTextField(wrappingLabelWithString: sources.count == 1
            ? sources[0].lastPathComponent : "\(sources.count) ausgewählte Einträge")
        selection.font = .systemFont(ofSize: 18, weight: .semibold)
        selection.maximumNumberOfLines = 2
        selection.lineBreakMode = .byTruncatingMiddle
        let parents = Set(sources.map { $0.deletingLastPathComponent().path })
        let source = hint(parents.count > 1 ? "Aus \(parents.count) Ordnern" : "Aus: \(sourceDirectory.path)")
        source.toolTip = sources.map(\.path).joined(separator: "\n")
        source.maximumNumberOfLines = 2
        source.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(selection)
        stack.addArrangedSubview(source)
        stack.setCustomSpacing(16, after: source)
        stack.addArrangedSubview(label("Quellmaske"))
        mask.setAccessibilityLabel("Quellmaske")
        mask.toolTip = "Filtert die Auswahl: * für alle, z. B. *.txt oder Bild?.png."
        stack.addArrangedSubview(mask)
        stack.addArrangedSubview(label("Nach"))
        destination.stringValue = destinationDirectory.path + (destinationDirectory.path == "/" ? "" : "/")
        destination.setAccessibilityLabel("Zielpfad")
        destination.toolTip = "Ordner oder neuer Name für einen Eintrag. Relative Pfade gelten ab dem Quellordner."
        stack.addArrangedSubview(destination)
        stack.addArrangedSubview(hint("Bei bestehenden Zielen fragt PaneRook während des Auftrags nach: Überspringen, beide behalten, ersetzen oder Ordner zusammenführen."))

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.isHidden = true
        errorLabel.setAccessibilityLabel("Fehler im Kopierdialog")
        stack.addArrangedSubview(errorLabel)
        let buttons = NSStackView()
        buttons.spacing = 10
        buttons.addArrangedSubview(NSView())
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel(_:)))
        AppStyle.configureButton(cancel)
        ContextCommands.configure(cancel, id: "dialog.cancel")
        let submit = NSButton(title: kind == .copy ? "Kopieren" : "Verschieben", target: self, action: #selector(confirm(_:)))
        AppStyle.configureButton(submit)
        ContextCommands.configure(submit, id: "dialog.accept")
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(submit)
        stack.addArrangedSubview(buttons)
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        for field in [mask, destination] {
            AppStyle.configureField(field)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.cell?.isScrollable = true
            field.target = self
            field.action = #selector(confirm(_:))
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        }
        mask.nextKeyView = destination
        destination.nextKeyView = cancel
        cancel.nextKeyView = submit
        submit.nextKeyView = mask
        panel.contentView = AppStyle.background(material: .sheet)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560)
        ])
        panel.setContentSize(stack.fittingSize)
        panel.initialFirstResponder = destination
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in
            completion(acceptedPlan)
        }
        window.makeFirstResponder(destination)
        destination.selectText(nil)
    }
    @objc private func confirm(_ sender: Any?) {
        if sender is NSTextField {
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  ContextCommands.matching(event, scope: .dialog)?.hasPrefix("dialog.accept") == true else { return }
        }
        do {
            acceptedPlan = try TransferPlan(sources: sources, sourcePattern: mask.stringValue,
                destinationPath: destination.stringValue, relativeTo: sourceDirectory, kind: kind, allowsConflicts: true)
            if let parent = window?.sheetParent, let window { parent.endSheet(window, returnCode: .OK) }
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
        acceptedPlan = nil
        if let parent = window?.sheetParent, let window { parent.endSheet(window, returnCode: .cancel) }
    }
}
