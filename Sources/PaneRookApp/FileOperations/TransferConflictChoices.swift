import AppKit
import PaneRookCore

/// Visible choices keep the consequence of confirmation legible without opening a menu.
final class TransferConflictChoices: NSView {
    private(set) var selectedAction: TransferConflictAction
    var selectedTitle: String { TransferConflictPrompt.title(selectedAction) }
    var onSelection: ((String) -> Void)?
    let applyToMatching = NSButton(checkboxWithTitle: "Für weitere Konflikte dieses Auftrags übernehmen", target: nil, action: nil)
    private let allowed: [TransferConflictAction]
    private let remoteDestination: Bool
    private var choices: [NSButton] = []
    private let consequence = NSTextField(wrappingLabelWithString: "")

    init(source: String, destination: String, sourceInfo: String, destinationInfo: String,
         allowed: [TransferConflictAction], remoteDestination: Bool) {
        self.allowed = allowed
        self.remoteDestination = remoteDestination
        selectedAction = allowed.first ?? .skip
        let height = CGFloat(allowed.count) * 30 + 218
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        func comparison(_ title: String, path: String, info: String, x: CGFloat) {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.frame = NSRect(x: x, y: height - 24, width: 250, height: 20)
            let name = NSTextField(labelWithString: (path as NSString).lastPathComponent)
            name.font = .systemFont(ofSize: 14, weight: .semibold)
            name.lineBreakMode = .byTruncatingMiddle
            name.frame = NSRect(x: x, y: height - 50, width: 250, height: 22)
            let location = NSTextField(labelWithString: path)
            location.font = .systemFont(ofSize: 11)
            location.lineBreakMode = .byTruncatingMiddle
            location.textColor = .secondaryLabelColor
            location.frame = NSRect(x: x, y: height - 72, width: 250, height: 18)
            location.toolTip = path
            let metadata = NSTextField(wrappingLabelWithString: info)
            metadata.font = .systemFont(ofSize: 11)
            metadata.frame = NSRect(x: x, y: height - 116, width: 250, height: 40)
            for field in [heading, name, location, metadata] { field.isSelectable = true; addSubview(field) }
        }
        comparison("Quelle", path: source, info: sourceInfo, x: 0)
        comparison("Vorhanden am Ziel", path: destination, info: destinationInfo, x: 270)
        for (index, action) in allowed.enumerated() {
            let button = NSButton(radioButtonWithTitle: TransferConflictPrompt.title(action), target: self, action: #selector(choose(_:)))
            button.tag = index
            button.identifier = .init("conflict." + action.rawValue)
            button.frame = NSRect(x: 0, y: height - 150 - CGFloat(index) * 30, width: 520, height: 26)
            choices.append(button); addSubview(button)
        }
        consequence.font = .systemFont(ofSize: 12)
        consequence.textColor = .secondaryLabelColor
        consequence.frame = NSRect(x: 0, y: 33, width: 520, height: 48)
        addSubview(consequence)
        applyToMatching.font = .systemFont(ofSize: 12)
        applyToMatching.toolTip = "Gilt nur für diesen Auftrag und nur, wenn die gewählte Aktion verfügbar ist."
        applyToMatching.frame = NSRect(x: 0, y: 0, width: 520, height: 26)
        addSubview(applyToMatching)
        updateSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    @objc private func choose(_ sender: NSButton) {
        guard allowed.indices.contains(sender.tag) else { return }
        selectedAction = allowed[sender.tag]
        updateSelection()
        onSelection?(selectedTitle)
    }
    private func updateSelection() {
        for (index, button) in choices.enumerated() { button.state = allowed[index] == selectedAction ? .on : .off }
        switch selectedAction {
        case .skip: consequence.stringValue = "Dieser Eintrag wird nicht übertragen. Quelle und vorhandenes Ziel bleiben erhalten."
        case .keepBoth: consequence.stringValue = "Die übertragene Kopie erhält einen freien Namen. Der vorhandene Zieleintrag bleibt erhalten."
        case .replace:
            consequence.stringValue = "Der vorhandene Zieleintrag wird einschließlich seines Inhalts ersetzt. Dies lässt sich nicht mit Widerrufen rückgängig machen."
            if remoteDestination { consequence.stringValue += " Auf dem Server wird eine Sicherung angelegt." }
        case .merge: consequence.stringValue = "Die Ordner werden zusammengeführt. Andere Zielinhalte bleiben erhalten; weitere Namenskonflikte werden erneut geprüft."
        }
    }
}
