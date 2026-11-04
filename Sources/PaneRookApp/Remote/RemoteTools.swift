import PaneRookRemote
import PaneRookTasks
import AppKit
import PaneRookCore

/// Connections occupy their originating panel and transfer to the opposite panel.
final class RemoteTools {
    unowned let owner: any RemoteHost
    private var browsers: [RemoteBrowser] {
        owner.allPanes.compactMap { $0.remoteContent as? RemoteBrowser }
    }
    private let bookmarkStore = ConnectionBookmarkStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PaneRook/connections.json"))
    private var connectionDialog: ConnectionEditorDialog?
    private var archiveDialog: ConnectionArchiveController?
    init(owner: any RemoteHost) { self.owner = owner }
    func savedBookmarks() throws -> [ConnectionBookmark] { try bookmarkStore.load() }
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess) {
        guard !owner.isPerformingOperation, owner.presentationWindow?.attachedSheet == nil else { return }
        owner.activate(pane)
        if bookmark.kind.provider.usesPassword { showConnection(bookmark.kind, pane: pane, bookmark: bookmark) }
        else {
            do {
                let timeout = UserDefaults.standard.object(forKey: "remoteTimeout") as? Int ?? 20
                openBrowser(try bookmark.connection(timeout: timeout), directory: bookmark.path, pane: pane, bookmark: bookmark)
            } catch { owner.showError(error) }
        }
    }
    func closeAll() { browsers.forEach { $0.disconnect() } }

    func connect(_ kind: RemoteProtocol, pane: any PanelAccess) {
        guard owner.canUseMenus else { return }
        showConnection(kind, pane: pane)
    }

    private func showConnection(_ kind: RemoteProtocol, pane: any PanelAccess, bookmark: ConnectionBookmark? = nil) {
        guard !owner.isPerformingOperation, let window = owner.presentationWindow, window.attachedSheet == nil else { return }
        var bookmarks: [ConnectionBookmark] = []
        var archiveError: String?
        do { bookmarks = try bookmarkStore.load() }
        catch { archiveError = "Archiv konnte nicht geladen werden: " + error.localizedDescription }
        let dialog = ConnectionEditorDialog(kind: kind, bookmark: bookmark, bookmarks: bookmarks,
            purpose: .connection, archiveError: archiveError, allowsArchive: true,
            saveBookmark: { [bookmarkStore] in _ = try bookmarkStore.upsert($0) }) { [weak self, weak pane] outcome in
            guard let self, let pane else { return }
            self.connectionDialog = nil
            // AppKit finishes detaching the old sheet after its completion returns.
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.owner.presentationWindow?.makeKeyAndOrderFront(nil)
                self.owner.activate(pane)
                switch outcome {
                case .connect(let connection, let path): self.openBrowser(connection, directory: path, pane: pane, bookmark: bookmark)
                case .archive: self.showArchive(pane: pane, kind: kind)
                default: break
                }
            }
        }
        connectionDialog = dialog
        dialog.begin(on: window)
    }

    func showArchive(pane: any PanelAccess, kind: RemoteProtocol? = nil) {
        guard !owner.isPerformingOperation, let window = owner.presentationWindow, window.attachedSheet == nil else { return }
        let dialog = ConnectionArchiveController(store: bookmarkStore, initialKind: kind) { [weak self, weak pane] bookmark in
            guard let self, let pane else { return }
            self.archiveDialog = nil
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.owner.presentationWindow?.makeKeyAndOrderFront(nil)
                self.owner.activate(pane)
                guard let bookmark else { return }
                self.openSavedBookmark(bookmark, pane: pane)
            }
        }
        archiveDialog = dialog
        dialog.begin(on: window)
    }

    func openBrowser(_ connection: RemoteConnection, directory: String, pane: any PanelAccess, bookmark: ConnectionBookmark? = nil,
                     runner: @escaping RemoteFileSystem.Runner = RemoteFileSystem.run) {
        let peer = owner.oppositePane(for: pane)
        let browser = RemoteBrowser(connection: connection, peer: peer, tasks: owner.tasks, runner: runner)
        browser.connectionBookmark = bookmark
        browser.onActivate = { [weak pane] in pane?.activate() }
        browser.onClose = { [weak pane, weak browser] in
            guard let pane, let browser, pane.remoteContent === browser else { return }
            pane.showRemoteContent(nil)
        }
        browser.onStateChanged = { [weak pane] in pane?.remoteStateDidChange() }
        pane.showRemoteContent(browser)
        owner.activate(pane)
        browser.show(directory: directory)
    }

    func showConnections() {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let alert = NSAlert(); alert.messageText = "Aktive VFS-Verbindungen"
        let entries = browsers.sorted { $0.displayName < $1.displayName }
        if entries.isEmpty {
            alert.informativeText = "Keine Verbindung geöffnet."
            alert.addButton(withTitle: "Schließen"); alert.configureKeyboardShortcuts(); alert.beginSheetModal(for: window)
            return
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        popup.addItems(withTitles: entries.map(\.displayName))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Anzeigen"); alert.addButton(withTitle: "Trennen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { response in
            guard entries.indices.contains(popup.indexOfSelectedItem) else { return }
            let browser = entries[popup.indexOfSelectedItem]
            DispatchQueue.main.async {
                if response == .alertFirstButtonReturn { browser.onActivate?(); browser.focus() }
                else if response == .alertSecondButtonReturn { browser.disconnect() }
            }
        }
    }

    func settingsChanged() {
        browsers.forEach { $0.refresh() }
    }
}


protocol RemoteHost: PanelPresenting, PanelPairProviding, ErrorPresenting, TaskProviding {
    var isPerformingOperation: Bool { get }
}
