import AppKit
import PaneRookCore
import PaneRookRemote
import PaneRookTasks

/// Owned by TaskCenter. Only typed transfer documents can be restored, and only on explicit request.
final class RecoverableTransfers {
    static var applicationStore: TransferStore {
        TransferStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaneRook/Transfers", isDirectory: true))
    }
    let store: TransferStore
    private(set) var records: [UUID: RecoverableTransfer] = [:]
    private var remotes: [TransferEndpoint: RemoteFileSystem] = [:]
    private var completions: [UUID: () -> Void] = [:]
    var onResume: ((RecoverableTransfer, TransferFileAccess, @escaping () -> Void) -> Void)?
    var onRestore: ((RecoverableTransfer) -> Void)?
    var onError: ((Error) -> Void)?
    var onRestoredCompletion: (() -> Void)?

    init(store: TransferStore) { self.store = store }
    func restore() {
        do {
            for record in try store.load() { records[record.id] = record; onRestore?(record) }
        } catch { onError?(error) }
    }
    func submit(_ record: RecoverableTransfer, remotes: [RemoteFileSystem], completion: @escaping () -> Void) throws {
        try store.save(record)
        records[record.id] = record
        for fs in remotes { self.remotes[TransferEndpoint(fs.connection)] = fs }
        completions[record.id] = completion
        start(record)
    }
    private func start(_ record: RecoverableTransfer) {
        onResume?(record, TransferFileAccess(remotes: remotes), { [weak self] in
            guard let self else { return }
            if let completion = self.completions.removeValue(forKey: record.id) { completion() }
            else { self.onRestoredCompletion?() }
        })
    }
    func cancelledBeforeStart(_ id: UUID) throws {
        guard var record = records[id], record.state != .cancelled else { return }
        record.state = .cancelled
        try store.save(record); records[id] = record
    }
    func updated(_ record: RecoverableTransfer) { records[record.id] = record }
    func remove(_ id: UUID) throws { try store.remove(id); records.removeValue(forKey: id); completions.removeValue(forKey: id) }
    func resume(_ id: UUID, on window: NSWindow?) {
        guard let record = records[id] else { return }
        let endpoints = Set(record.roots.flatMap { [$0.source.endpoint, $0.destination.endpoint] }).filter { $0 != .local }
        authenticate(Array(endpoints), record: record, window: window)
    }
    private func authenticate(_ endpoints: [TransferEndpoint], record: RecoverableTransfer, window: NSWindow?) {
        guard let endpoint = endpoints.first else { start(record); return }
        guard let kind = RemoteProtocol(rawValue: endpoint.scheme) else { onError?(RemoteError.invalidConnection); return }
        // Ask again on every retry so an expired password can be replaced. Endpoint identity stays fixed.
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Transfer fortsetzen: Anmeldung"
        alert.informativeText = "\(endpoint.scheme)://\(endpoint.user)@\(endpoint.host):\(endpoint.port)\nQuellen und abgeschlossene Ziele werden erneut gelesen und geprüft."
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        password.placeholderString = "Passwort (bleibt nur im Arbeitsspeicher)"
        if kind.provider.usesPassword { alert.accessoryView = password; alert.window.initialFirstResponder = password }
        alert.addButton(withTitle: "Fortsetzen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                let connection = try RemoteConnection(kind: kind, host: endpoint.host, port: endpoint.port,
                    user: endpoint.user, password: password.stringValue, identityFile: endpoint.identityFile)
                self.remotes[endpoint] = RemoteFileSystem(connection: connection)
                DispatchQueue.main.async { self.authenticate(Array(endpoints.dropFirst()), record: record, window: window) }
            } catch { self.onError?(error) }
        }
    }
}
