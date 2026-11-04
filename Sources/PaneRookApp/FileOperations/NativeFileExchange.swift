import AppKit
import PaneRookCore

protocol NativeFileExchangeHost: PanelPresenting, ErrorPresenting {
    var fileOperations: FileOperations { get }
}

enum NativeFileExchangeError: LocalizedError {
    case fileURLsRequired, virtualFiles, unavailableDestination, cannotWriteClipboard
    var errorDescription: String? {
        switch self {
        case .fileURLsRequired: return "Die Auswahl muss ausschließlich lokale Datei-URLs enthalten. Text und Datei-Versprechen werden nicht als Dateien eingefügt."
        case .virtualFiles: return "Remote- und Archivinhalte zuerst mit F5 in einen lokalen Ordner kopieren. Für den nativen Dateiaustausch sind noch keine Datei-Versprechen verfügbar."
        case .unavailableDestination: return "Bitte eine geladene lokale Dateiliste oder einen erreichbaren Ordner als Ziel verwenden."
        case .cannotWriteClipboard: return "Die Dateien konnten nicht in die Zwischenablage geschrieben werden."
        }
    }
}

/// File URLs only: never publish virtual archive paths or temporary preview copies as originals.
enum NativeFileURLs {
    static func validate(_ urls: [URL]) throws {
        guard !urls.isEmpty, urls.allSatisfy({ url in
            url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
                && url.path.hasPrefix("/") && !url.path.contains("\0") && url.query == nil && url.fragment == nil
        }) else { throw NativeFileExchangeError.fileURLsRequired }
        guard !urls.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) else {
            throw NativeFileExchangeError.virtualFiles
        }
    }

    static func read(from pasteboard: NSPasteboard) throws -> [URL] {
        // Reject mixed payloads instead of silently transferring only the readable subset.
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            throw NativeFileExchangeError.fileURLsRequired
        }
        let urls = try items.map { item -> URL in
            guard let value = item.string(forType: .fileURL), let url = URL(string: value) else {
                throw NativeFileExchangeError.fileURLsRequired
            }
            return url
        }
        try validate(urls)
        return urls
    }

    static func plan(sources: [URL], destination: URL, kind: TransferKind, allowsConflicts: Bool = false) throws -> TransferPlan {
        try validate(sources)
        try validate([destination])
        guard ArchiveFileSystem.location(for: destination) == nil else { throw NativeFileExchangeError.virtualFiles }
        // Validate paths and ancestry; user-facing transfers defer collisions to the shared conflict workflow.
        return try TransferPlan(sources: sources, destination: destination, kind: kind, allowsConflicts: allowsConflicts)
    }

    static func dragOperation(sources: [URL], destination: URL, allowed: NSDragOperation,
                              modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        if modifiers.contains([.command, .option]) { return [] } // Link creation is a different action.
        if modifiers.contains(.option) { return allowed.contains(.copy) ? .copy : [] }
        if modifiers.contains(.command) { return allowed.contains(.move) ? .move : [] }
        let targetVolume = try? destination.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let sameVolume = targetVolume != nil && sources.allSatisfy { source in
            let volume = try? source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
            return (volume as? NSObject)?.isEqual(targetVolume) == true
        }
        let preferred: NSDragOperation = sameVolume ? .move : .copy
        if allowed.contains(preferred) { return preferred }
        if allowed.contains(.copy) { return .copy }
        return allowed.contains(.move) ? .move : []
    }
}

/// Routes AppKit exchange to the existing dialog, TransferPlan and serial task queue.
final class NativeFileExchange {
    private unowned let owner: any NativeFileExchangeHost
    let pasteboard: NSPasteboard
    init(owner: any NativeFileExchangeHost, pasteboard: NSPasteboard = .general) {
        self.owner = owner
        self.pasteboard = pasteboard
    }

    func registerCommands(in registry: CommandRegistry) {
        // Cmd-C/V retain their existing editing.* IDs and native responder-chain routing.
        registry.add(.file, "Dateien in Zwischenablage kopieren", id: "files.clipboard.copy", order: 51,
            scope: .panel, enabled: { self.canCopy(from: self.owner.activePane) }
        ) { self.copy(from: self.owner.activePane) }
        registry.add(.file, "Dateien einsetzen …", id: "files.clipboard.paste", order: 52,
            scope: .panel, enabled: { self.canPaste(into: self.owner.activePane) }
        ) { self.paste(into: self.owner.activePane, kind: .copy) }
        registry.add(.file, "Dateien hierher bewegen …", id: "files.clipboard.move", order: 53,
            key: "v", modifiers: [.command, .option], scope: .panel,
            enabled: { self.canPaste(into: self.owner.activePane) }
        ) { self.paste(into: self.owner.activePane, kind: .move) }
    }

    func canCopy(from pane: any PanelAccess) -> Bool {
        owner.canUseMenus && pane.hasFileListKeyboardFocus && pane.canExportNativeFiles
            && !pane.selectedFiles.isEmpty
    }
    func canPaste(into pane: any PanelAccess) -> Bool {
        owner.canUseMenus && pane.hasFileListKeyboardFocus && pane.fileExchangeDirectory != nil
            && (try? NativeFileURLs.read(from: pasteboard)) != nil
    }
    func copy(from pane: any PanelAccess) {
        guard canCopy(from: pane) else { return }
        do {
            let sources = pane.selectedFiles
            try NativeFileURLs.validate(sources)
            pasteboard.clearContents()
            guard pasteboard.writeObjects(sources.map { $0 as NSURL }) else {
                throw NativeFileExchangeError.cannotWriteClipboard
            }
        } catch { owner.showError(error) }
    }
    func paste(into pane: any PanelAccess, kind: TransferKind) {
        guard owner.canUseMenus, pane.hasFileListKeyboardFocus else { return }
        do {
            guard let destination = pane.fileExchangeDirectory else { throw NativeFileExchangeError.unavailableDestination }
            try requestTransfer(sources: NativeFileURLs.read(from: pasteboard), destination: destination, kind: kind, pane: pane)
        } catch { owner.showError(error) }
    }

    func validateDrop(sources: [URL], destination: URL, pane: any PanelAccess,
                      allowed: NSDragOperation, modifiers: NSEvent.ModifierFlags) -> NSDragOperation {
        guard let window = owner.presentationWindow, window.attachedSheet == nil, pane.canExportNativeFiles,
              let _ = try? NativeFileURLs.plan(sources: sources, destination: destination, kind: .copy, allowsConflicts: true) else { return [] }
        return NativeFileURLs.dragOperation(sources: sources, destination: destination, allowed: allowed, modifiers: modifiers)
    }

    @discardableResult func acceptDrop(sources: [URL], destination: URL, pane: any PanelAccess,
                                      operation: NSDragOperation) -> Bool {
        guard pane.canExportNativeFiles, operation == .copy || operation == .move else { return false }
        do {
            try requestTransfer(sources: sources, destination: destination, kind: operation == .move ? .move : .copy, pane: pane)
            return true
        } catch { owner.showError(error); return false }
    }

    private func requestTransfer(sources: [URL], destination: URL, kind: TransferKind, pane: any PanelAccess) throws {
        guard let window = owner.presentationWindow, window.attachedSheet == nil else {
            throw NativeFileExchangeError.unavailableDestination
        }
        _ = try NativeFileURLs.plan(sources: sources, destination: destination, kind: kind, allowsConflicts: true)
        owner.activate(pane)
        // Clipboard and drag payloads may contain files from different source directories.
        // Absolute destination plus an exact source array avoid depending on the active panel.
        owner.fileOperations.confirmTransfer(sources: sources, sourceDirectory: sources[0].deletingLastPathComponent(),
            destination: destination, kind: kind, focusPane: pane, window: window)
    }
}
