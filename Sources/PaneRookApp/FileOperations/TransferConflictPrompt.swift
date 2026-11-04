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

    func resolve(source: String, destination: String, sourceInfo: String, destinationInfo: String,
                         allowed: [TransferConflictAction], remoteDestination: Bool = false,
                         cancelled: @escaping () -> Bool) throws -> TransferConflictAction {
        precondition(!Thread.isMainThread)
        let done = DispatchSemaphore(value: 0)
        var result: TransferConflictAction?
        DispatchQueue.main.async { [self] in
            guard !cancelled(), let parent else { done.signal(); return }
            if let action = rules.decision(for: allowed) { result = action; done.signal(); return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Ziel existiert bereits"
            alert.informativeText = "Wie soll mit dem vorhandenen Eintrag umgegangen werden?"
            let accessory = TransferConflictChoices(source: source, destination: destination,
                sourceInfo: sourceInfo, destinationInfo: destinationInfo, allowed: allowed, remoteDestination: remoteDestination)
            alert.accessoryView = accessory
            let confirm = alert.addButton(withTitle: accessory.selectedTitle)
            confirm.isEnabled = !allowed.isEmpty
            accessory.onSelection = { [weak confirm] title in
                guard let confirm else { return }
                confirm.title = title
                ContextCommands.configure(confirm, id: "dialog.accept")
            }
            alert.addButton(withTitle: "Auftrag abbrechen")
            alert.configureKeyboardShortcuts()
            var sheetParent = parent
            while let attached = sheetParent.attachedSheet { sheetParent = attached }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                if cancelled(), let host = alert.window.sheetParent { host.endSheet(alert.window, returnCode: .abort) }
            }
            alert.beginSheetModal(for: sheetParent) { [self] response in
                timer.invalidate()
                if response == .alertFirstButtonReturn && !cancelled(), allowed.contains(accessory.selectedAction) {
                    let action = accessory.selectedAction
                    if accessory.applyToMatching.state == .on { rules.action = action }
                    result = action
                } else { onCancel() }
                done.signal()
            }
        }
        done.wait()
        guard let result, !cancelled() else { throw TransferError.cancelled }
        return result
    }

    static func title(_ action: TransferConflictAction) -> String {
        switch action {
        case .skip: return "Überspringen"
        case .keepBoth: return "Beide behalten"
        case .replace: return "Ersetzen"
        case .merge: return "Ordner zusammenführen"
        }
    }
    static func describe(_ info: TransferEntryInfo) -> String {
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
    static func describe(type: String, size: Int64, modified: Date?) -> String {
        type + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            + " · geändert: " + (modified.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "unbekannt")
    }
}
