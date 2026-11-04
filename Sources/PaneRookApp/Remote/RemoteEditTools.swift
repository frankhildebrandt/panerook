import AppKit
import PaneRookRemote
import PaneRookTasks

/// App lifetime owner: panel navigation and disconnect never end editing sessions.
final class RemoteEditTools {
    unowned let owner: any PreviewHost
    let root: URL
    private(set) var sessions: [RemoteEditSession] = []
    private var pending = Set<String>()
    private var jobs: [ObjectIdentifier: UUID] = [:]
    private var window: RemoteEditWindow?
    private var timer: Timer?
    private let polling = DispatchQueue(label: "app.panerook.remote-edit.poll", qos: .utility)
    private var isPolling = false
    private let defaults: UserDefaults
    static let editorPreferenceKey = "preferredEditorApplicationPath"

    init(owner: any PreviewHost, root: URL? = nil, defaults: UserDefaults = .standard) {
        self.owner = owner; self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaneRook/RemoteEdits", isDirectory: true)
    }
    deinit { timer?.invalidate() }
    var editorURL: URL {
        URL(fileURLWithPath: defaults.string(forKey: Self.editorPreferenceKey) ?? "/System/Applications/TextEdit.app")
    }
    func openEditor(_ urls: [URL]) {
        NSWorkspace.shared.open(urls, withApplicationAt: editorURL, configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.owner.showError(error, detail: "Die Arbeitskopien bleiben erhalten. Über Datei → Bevorzugten Editor wählen … eine installierte App auswählen.") } }
        }
    }
    func chooseEditor() {
        guard let parent = owner.presentationWindow else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Bevorzugten Editor wählen"; chooser.prompt = "Editor verwenden"
        chooser.allowedContentTypes = [.applicationBundle]; chooser.directoryURL = URL(fileURLWithPath: "/Applications")
        chooser.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .OK, let url = chooser.url else { return }
            self.defaults.set(url.path, forKey: Self.editorPreferenceKey)
        }
    }
    func registerCommands(in registry: CommandRegistry) {
        registry.add(.file, "Remote-Arbeitskopien …", id: "remoteEdit.sessions", order: 43, group: 0,
                     enabled: { self.owner.canUseMenus }) { self.showSessions() }
        registry.add(.file, "Bevorzugten Editor wählen …", id: "editor.choose", order: 46, group: 0,
                     enabled: { self.owner.canUseMenus }) { self.chooseEditor() }
    }
    func edit(_ requests: [RemoteEditRequest]) {
        guard !requests.isEmpty else { NSSound.beep(); return }
        showSessions()
        for request in requests {
            guard let identity = try? RemoteEditIdentity(connection: request.fileSystem.connection, path: request.path) else { continue }
            if let existing = sessions.first(where: { $0.identity == identity }) { openEditor([existing.workingURL]); continue }
            let key = request.fileSystem.connection.displayName + request.path
            guard pending.insert(key).inserted else { continue }
            let token = RemoteCancellation(), root = self.root
            owner.tasks.submit(title: "Remote-Arbeitskopie laden", detail: key, cancellation: { token.cancel() }, work: { report in
                report(OperationProgress(currentPath: request.path))
                let session = try RemoteEditSession.prepare(fileSystem: request.fileSystem, path: request.path, root: root, cancellation: token)
                report(OperationProgress(completedItems: 1, totalItems: 1, currentPath: request.path))
                return session
            }, completion: { [weak self] result in
                guard let self else { return }
                self.pending.remove(key)
                switch result {
                case .success(let session):
                    self.sessions.append(session); self.startPolling(); self.refreshWindow()
                    // Wait for TaskCenter to dismiss its progress sheet.
                    DispatchQueue.main.async { self.openEditor([session.workingURL]) }
                case .failure(let error):
                    self.owner.showError(error, detail: "Vorhandene Arbeitskopien bleiben in " + root.path + " erhalten.")
                }
            })
        }
    }
    func showSessions() {
        if window == nil {
            window = RemoteEditWindow(root: root)
            window?.onUpload = { [weak self] session in self?.upload(session) }
            window?.onOpen = { [weak self] session in self?.openEditor([session.workingURL]) }
            window?.onCancel = { [weak self] session in
                guard let self, let id = self.jobs[ObjectIdentifier(session)] else { return }
                self.owner.tasks.cancel(id)
            }
            window?.onStop = { [weak self] session in self?.stop(session) }
        }
        refreshWindow(); window?.showWindow(nil); window?.window?.makeKeyAndOrderFront(nil)
    }
    private func refreshWindow() { window?.update(sessions, pending: Set(jobs.keys)) }
    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        let captured = sessions
        polling.async { [weak self] in
            for session in captured { try? session.pollChanges() }
            DispatchQueue.main.async { [weak self] in self?.isPolling = false; self?.refreshWindow() }
        }
    }
    private func upload(_ session: RemoteEditSession, approving revision: RemoteEditRevision? = nil) {
        let key = ObjectIdentifier(session)
        guard jobs[key] == nil else { return }
        if revision == nil, let conflict = session.snapshot.conflict {
            resolveConflict(session, revision: conflict); return
        }
        let token = RemoteCancellation()
        jobs[key] = owner.tasks.submit(title: "Remote-Änderungen hochladen", detail: session.identity.path,
            cancellation: { token.cancel() }, work: { report in
                try session.upload(approving: revision, cancellation: token) { stage in
                    report(OperationProgress(currentPath: session.identity.path + " · " + stage))
                }
            }, completion: { [weak self] result in
                guard let self else { return }
                self.jobs.removeValue(forKey: key); self.refreshWindow()
                if case .success(.conflict(let current)) = result {
                    DispatchQueue.main.async { self.resolveConflict(session, revision: current) }
                }
                // Failure details remain in TaskCenter and the session row. A
                // retry never discards the captured baseline or skips preflight.
            })
        refreshWindow()
    }
    private func resolveConflict(_ session: RemoteEditSession, revision: RemoteEditRevision) {
        guard let parent = window?.window, parent.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Die Serverdatei wurde geändert."
        alert.informativeText = session.identity.path + "\nDie lokale Arbeitskopie bleibt erhalten. Beim Ersetzen wird die gerade erkannte Serverversion erneut geprüft und als Serversicherung behalten. Weitere Serveränderungen lösen erneut einen Konflikt aus."
        alert.addButton(withTitle: "Arbeitskopie behalten")
        alert.addButton(withTitle: revision.digest == nil ? "Fehlende Serverdatei neu anlegen" : "Geprüfte Serverversion ersetzen")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: parent) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.upload(session, approving: revision) }
        }
    }
    private func stop(_ session: RemoteEditSession) {
        guard jobs[ObjectIdentifier(session)] == nil, !session.snapshot.isBusy, let parent = window?.window else { return }
        let alert = NSAlert(); alert.messageText = "Beobachtung beenden?"
        alert.informativeText = "Vorher die Datei im Editor schließen. Die Arbeitskopie bleibt dauerhaft unter \(session.workingURL.path) erhalten. Es wird nichts hochgeladen oder gelöscht. F4 auf derselben Serverdatei nimmt diese Arbeitskopie später wieder auf."
        alert.addButton(withTitle: "Weiter beobachten"); alert.addButton(withTitle: "Beobachtung beenden")
        alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.sessions.removeAll { $0 === session }; self.refreshWindow()
        }
    }
    func confirmTermination() -> Bool {
        guard !sessions.isEmpty || !pending.isEmpty else { return true }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Remote-Dateien sind noch zur Bearbeitung geöffnet."
        alert.informativeText = "Ungesendete Änderungen werden nicht automatisch hochgeladen. Alle Arbeitskopien bleiben unter \(root.path) erhalten. Nach dem Neustart neu verbinden und F4 auf derselben Datei drücken. Vor dem Beenden im Editor speichern und die Dateien schließen."
        alert.addButton(withTitle: "Weiterarbeiten"); alert.addButton(withTitle: "Arbeitskopien behalten und beenden")
        alert.configureKeyboardShortcuts()
        return alert.runModal() == .alertSecondButtonReturn
    }
    func showRecoveryNoticeIfNeeded() {
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil), !items.isEmpty else { return }
        // Retained clean copies are intentional too. Do not infer that they can
        // be deleted: an external editor may have saved after the previous quit.
        DispatchQueue.main.async { [weak self] in self?.showSessions() }
    }
}
