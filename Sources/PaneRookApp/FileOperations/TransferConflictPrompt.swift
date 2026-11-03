import AppKit
import PaneRookCore
import PaneRookRemote

/// One instance per queued job. Only the worker waits; AppKit keeps processing
/// cancellation, background tasks and the native sheet's keyboard actions.
final class TransferConflictPrompt: @unchecked Sendable {
    private weak var parent: NSWindow?
    private var rules = TransferConflictRules()
    private let onCancel: () -> Void
    init(parent: NSWindow?, onCancel: @escaping () -> Void = {}) { self.parent = parent; self.onCancel = onCancel }

    func resolve(_ conflict: TransferConflict, cancelled: @escaping () -> Bool) throws -> TransferConflictAction {
        try resolve(source: conflict.source.path, destination: conflict.destination.path,
                    sourceInfo: Self.describe(conflict.sourceInfo), destinationInfo: Self.describe(conflict.destinationInfo),
                    allowed: conflict.allowedActions, cancelled: cancelled)
    }

    func resolve(_ conflict: RemoteTransferConflict, cancelled: @escaping () -> Bool) throws -> RemoteConflictAction {
        let allowed = conflict.allowedActions.compactMap { TransferConflictAction(rawValue: $0.rawValue) }
        let action = try resolve(source: conflict.source, destination: conflict.destination,
                                 sourceInfo: Self.describe(conflict.sourceEntry), destinationInfo: Self.describe(conflict.destinationEntry),
                                 allowed: allowed, cancelled: cancelled)
        return RemoteConflictAction(rawValue: action.rawValue)!
    }

    private func resolve(source: String, destination: String, sourceInfo: String, destinationInfo: String,
                         allowed: [TransferConflictAction], cancelled: @escaping () -> Bool) throws -> TransferConflictAction {
        precondition(!Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        var result: TransferConflictAction?
        DispatchQueue.main.async { [self] in
            guard !cancelled(), let parent else { done.signal(); return }
            if let action = rules.decision(for: allowed) { result = action; done.signal(); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Ziel existiert bereits"
            alert.informativeText = "Quelle: \(source)\n\(sourceInfo)\n\nZiel: \(destination)\n\(destinationInfo)"
            let choices = NSPopUpButton(); choices.setAccessibilityLabel("Konfliktentscheidung")
            for action in allowed { choices.addItem(withTitle: Self.title(action)) }
            let apply = NSButton(checkboxWithTitle: "Für alle passenden Konflikte dieses Auftrags", target: nil, action: nil)
            let notice = NSTextField(wrappingLabelWithString:
                "Ersetzen entfernt den bisherigen Zieleintrag einschließlich seines Inhalts erst nach vollständiger Übertragung. Zusammenführen behandelt gleichnamige Untereinträge erneut. Beim Überspringen bleibt die Quelle erhalten.\n\nBei Archiven sind nur Überspringen und Beide behalten verfügbar. Remote-Ersetzungen verwenden eine Sicherung; Server bieten keine allgemeine atomare Veröffentlichung.")
            notice.font = .systemFont(ofSize: 12); notice.textColor = .secondaryLabelColor
            // NSAlert manages its accessory's frame. A fixed-size native container
            // avoids competing stack constraints during sheet animation/layout.
            let width: CGFloat = 480
            let noticeHeight = ceil((notice.stringValue as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: notice.font!]).height) + 6
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: noticeHeight + 80))
            notice.frame = NSRect(x: 0, y: 0, width: width, height: noticeHeight)
            apply.frame = NSRect(x: 0, y: noticeHeight + 14, width: width, height: 22)
            choices.frame = NSRect(x: 0, y: noticeHeight + 48, width: width, height: 28)
            for view in [choices, apply, notice] { accessory.addSubview(view) }
            alert.accessoryView = accessory
            alert.addButton(withTitle: "Fortfahren"); alert.addButton(withTitle: "Auftrag abbrechen")
            alert.configureKeyboardShortcuts()
            var sheetParent = parent
            while let attached = sheetParent.attachedSheet { sheetParent = attached }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if cancelled(), let host = alert.window.sheetParent { host.endSheet(alert.window, returnCode: .abort) }
            }
            alert.beginSheetModal(for: sheetParent) { [self] response in
                timer.invalidate()
                if response == .alertFirstButtonReturn && !cancelled(), allowed.indices.contains(choices.indexOfSelectedItem) {
                    let action = allowed[choices.indexOfSelectedItem]
                    if apply.state == .on { rules.action = action }
                    result = action
                } else { onCancel() }
                done.signal()
            }
        }
        done.wait()
        guard let result, !cancelled() else { throw TransferError.cancelled }
        return result
    }

    private static func title(_ action: TransferConflictAction) -> String {
        switch action {
        case .skip: return "Überspringen – Ziel und Quelle behalten"
        case .keepBoth: return "Beide behalten – neuen eindeutigen Zielnamen erzeugen"
        case .replace: return "Ersetzen – bisherigen Zieleintrag vollständig ersetzen"
        case .merge: return "Ordner zusammenführen – übrige Zielinhalte behalten"
        }
    }
    private static func describe(_ info: TransferEntryInfo) -> String {
        let type: String
        switch info.kind {
        case .file: type = "Datei"
        case .directory: type = "Ordner"
        case .symbolicLink: type = "Symbolischer Link (Link selbst)"
        case .other: type = "Spezialdatei"
        }
        return describe(type: type, size: info.size, modified: info.modified)
    }
    private static func describe(_ info: RemoteEntry) -> String {
        describe(type: info.isSymbolicLink ? "Symbolischer Link" : (info.isDirectory ? "Ordner" : "Datei"), size: info.size, modified: info.modified)
    }
    private static func describe(type: String, size: Int64, modified: Date?) -> String {
        type + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            + " · geändert: " + (modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "unbekannt")
    }
}
