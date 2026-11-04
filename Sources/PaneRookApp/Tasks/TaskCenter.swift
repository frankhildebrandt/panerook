import PaneRookTasks
import AppKit
import PaneRookCore
import PaneRookRemote

/// Owns progress windows independently of the panels and the workers' captured paths.
final class TaskCenter {
    private let parentWindow: () -> NSWindow?
    private let restoreFocus: () -> Void
    private let queue = BackgroundTaskQueue()
    private let transfers: RecoverableTransfers
    private let moveJournal: RecoverableTransferJournal?
    private var transferJournals: [UUID: RecoverableTransferJournal] = [:]
    private var transferLoadError: Error?
    private var details: [UUID: TaskProgressWindow] = [:]
    private var resultActions: [UUID: () -> Void] = [:]
    private var foreground: UUID?
    private var pendingPresentation = Set<UUID>()
    private var presentationIntent = Set<UUID>()
    private var queueWindow: TaskQueueWindow?
    private var idleHandler: (() -> Void)?
    var onChange: (() -> Void)?

    init(parentWindow: @escaping () -> NSWindow?, restoreFocus: @escaping () -> Void, transferStore: TransferStore? = nil, restoredTransferCompletion: @escaping () -> Void = {}, transferJournal: FileOperationJournal? = nil) {
        moveJournal = transferJournal.map(RecoverableTransferJournal.init)
        transfers = RecoverableTransfers(store: transferStore ?? TransferStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-Transfers-" + UUID().uuidString)))
        self.parentWindow = parentWindow
        self.restoreFocus = restoreFocus
        transfers.onRestoredCompletion = restoredTransferCompletion
        transfers.onRestore = { [weak self] in self?.queue.restoreTransfer($0) }
        transfers.onError = { [weak self] in self?.transferLoadError = $0 }
        transfers.onResume = { [weak self] record, access, completion in self?.executeTransfer(record, access: access, completion: completion) }
        transfers.restore()
        queue.onChange = { [weak self] snapshots in
            guard let self else { return }
            for snapshot in snapshots { self.details[snapshot.id]?.update(snapshot, canReveal: self.resultActions[snapshot.id] != nil) }
            self.queueWindow?.update(snapshots)
            self.onChange?()
            if !snapshots.contains(where: { $0.state.isActive }), let handler = self.idleHandler {
                self.idleHandler = nil
                handler()
            }
        }
    }
    var hasActiveTasks: Bool { queue.snapshots.contains { $0.state.isActive } }
    var summary: String {
        let tasks = queue.snapshots, waiting = tasks.filter { $0.state == .queued }.count
        if let current = tasks.first(where: { $0.state == .running || $0.state == .cancelling }) {
            let percent = current.progress.fraction.map { " · \(Int($0 * 100)) %" } ?? ""
            return "\(current.title)\(percent)" + (waiting > 0 ? " · \(waiting) wartend" : "")
        }
        if waiting > 0 { return "\(waiting) Aufgaben wartend" }
        if transferLoadError != nil { return "Transferaufträge konnten nicht geladen werden" }
        if tasks.isEmpty { return "Keine Aufgaben" }
        let open = tasks.filter { $0.canResume }.count
        if open > 0 { return "\(open) Transferaufträge fortsetzbar" }
        let failed = tasks.filter { $0.state == .failed }.count
        return failed > 0 ? "\(failed) Aufgaben mit Fehlern" : "Alle Aufgaben beendet"
    }

    @discardableResult
    func submit<Value>(id taskID: UUID = UUID(), recoverable: Bool = false, title: String, detail: String = "", cancellation: @escaping () -> Void = {},
                       work: @escaping (@escaping (OperationProgress) -> Void) throws -> Value,
                       onReveal: (() -> Void)? = nil,
                       completion: @escaping (Result<Value, Error>) -> Void) -> UUID {
        var id: UUID!
        id = queue.submit(id: taskID, recoverable: recoverable, title: title, detail: detail, cancellation: cancellation, work: work) { [weak self] result in
            guard let self else { completion(result); return }
            let wasForeground = self.presentationIntent.contains(id)
            if case .success = result {
                self.pendingPresentation.remove(id)
                if wasForeground { self.background(id) }
            }
            completion(result)
            if wasForeground, case .success = result { onReveal?() }
        }
        pendingPresentation.insert(id)
        presentationIntent.insert(id)
        if let onReveal { resultActions[id] = onReveal }
        // Alerts submitting a task are allowed to finish their sheet dismissal first.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPresentation.remove(id) != nil else { return }
            self.showTask(id)
        }
        return id
    }
    @discardableResult
    func submitTransfer(_ record: RecoverableTransfer, remotes: [RemoteFileSystem] = [], journal: FileOperationJournal? = nil, completion: @escaping () -> Void) -> UUID? {
        if let journal { transferJournals[record.id] = RecoverableTransferJournal(journal) }
        do { try transfers.submit(record, remotes: remotes, completion: completion); return record.id }
        catch { showTransferError(error); return nil }
    }
    private func executeTransfer(_ record: RecoverableTransfer, access: TransferFileAccess, completion: @escaping () -> Void) {
        guard !queue.snapshots.contains(where: { $0.id == record.id && $0.state.isActive }) else { return }
        let store = transfers.store, moveJournal = transferJournals[record.id] ?? moveJournal
        submit(id: record.id, recoverable: true, title: record.title, detail: record.detail, cancellation: { access.cancel() }, work: { [weak self] report in
            var current = record
            defer { moveJournal?.record(current) }
            func save(_ record: RecoverableTransfer) throws {
                let value = access.sanitized(record)
                try store.save(value)
                self?.queue.updateDetail(value.id, detail: value.detail)
                DispatchQueue.main.async { [weak self] in self?.transfers.updated(value) }
            }
            current.state = .running; current.error = nil
            try save(current)
            do {
                try RecoverableTransferWorker.run(&current, access: access, checkpoint: save, progress: report)
                current.state = .completed
                try save(current)
            } catch {
                current.state = access.localToken.isCancelled || access.remoteToken.isCancelled ? .cancelled : .failed
                current.error = error.localizedDescription
                try save(current)
                throw error
            }
        }, completion: { [weak self] result in
            if case .failure(BackgroundTaskError.cancelled) = result {
                do { try self?.transfers.cancelledBeforeStart(record.id) }
                catch { self?.showTransferError(error) }
            }
            completion()
        })
    }
    var snapshots: [BackgroundTaskSnapshot] { queue.snapshots }
    func resumeTransfer(_ id: UUID) {
        guard queue.snapshots.first(where: { $0.id == id })?.canResume == true else { return }
        background(id)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queue.snapshots.first(where: { $0.id == id })?.canResume == true else { return }
            self.transfers.resume(id, on: self.queueWindow?.window ?? self.parentWindow())
        }
    }
    private func showTransferError(_ error: Error) {
        transferLoadError = error
        onChange?()
        // The transfer dialog may still be detaching its sheet in this completion.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.queueWindow?.window ?? self.parentWindow(), window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.messageText = "Transferauftrag konnte nicht gespeichert oder geladen werden"
            alert.informativeText = error.localizedDescription; alert.configureKeyboardShortcuts()
            self.transferLoadError = nil
            alert.beginSheetModal(for: window)
        }
    }
    private func discardTransfer(_ id: UUID) {
        guard queue.snapshots.first(where: { $0.id == id })?.canResume == true, let window = queueWindow?.window else { return }
        let alert = NSAlert(); alert.messageText = "Offenen Transferauftrag verwerfen?"
        alert.informativeText = "Bereits übertragene Dateien bleiben erhalten. Nur der gespeicherte Auftrag wird entfernt."
        alert.addButton(withTitle: "Verwerfen"); alert.addButton(withTitle: "Abbrechen"); alert.configureKeyboardShortcuts()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do { try self.transfers.remove(id); self.queue.removeInactive(id); self.background(id); self.details.removeValue(forKey: id) }
            catch { self.showTransferError(error) }
        }
    }
    func cancel(_ id: UUID) { queue.cancel(id) }
    func cancelAll() { queue.cancelAll() }
    func cancelAll(whenFinished completion: @escaping () -> Void) {
        idleHandler = completion
        queue.cancelAll()
        if !hasActiveTasks { idleHandler = nil; completion() }
    }
    func showQueue() {
        if let error = transferLoadError { showTransferError(error) }
        if queueWindow == nil {
            queueWindow = TaskQueueWindow()
            queueWindow?.onResume = { [weak self] in self?.resumeTransfer($0) }
            queueWindow?.onDiscard = { [weak self] in self?.discardTransfer($0) }
            queueWindow?.onOpen = { [weak self] id in self?.showTask(id) }
            queueWindow?.onCancel = { [weak self] id in self?.queue.cancel(id) }
            queueWindow?.onClear = { [weak self] in
                guard let self else { return }
                let finished = self.queue.snapshots.filter { !$0.state.isActive && !$0.canResume }.map(\.id)
                for id in finished {
                    if self.transfers.records[id] != nil {
                        do { try self.transfers.remove(id) } catch { self.showTransferError(error); return }
                    }
                    self.background(id); self.details.removeValue(forKey: id); self.resultActions.removeValue(forKey: id)
                }
                self.queue.clearFinished()
            }
        }
        queueWindow?.update(queue.snapshots)
        queueWindow?.showWindow(nil); queueWindow?.window?.makeKeyAndOrderFront(nil)
    }
    private func showTask(_ id: UUID) {
        guard let snapshot = queue.snapshots.first(where: { $0.id == id }) else { return }
        let controller: TaskProgressWindow
        if let existing = details[id] { controller = existing }
        else {
            controller = TaskProgressWindow()
            controller.onResume = { [weak self] in self?.resumeTransfer(id) }
            controller.onBackground = { [weak self] in self?.background(id) }
            controller.onCancel = { [weak self] in self?.queue.cancel(id) }
            controller.onReveal = { [weak self] in self?.background(id); self?.resultActions[id]?() }
            details[id] = controller
        }
        presentationIntent.insert(id)
        controller.update(snapshot, canReveal: resultActions[id] != nil)
        guard let window = controller.window else { return }
        if let existing = foreground, existing != id { background(existing) }
        if window.sheetParent != nil { window.makeKeyAndOrderFront(nil); return }
        if snapshot.state.isActive, let parent = parentWindow(), parent.attachedSheet == nil {
            foreground = id
            parent.makeKeyAndOrderFront(nil)
            parent.beginSheet(window)
        } else {
            controller.showWindow(nil); window.makeKeyAndOrderFront(nil)
        }
    }
    private func background(_ id: UUID) {
        pendingPresentation.remove(id)
        presentationIntent.remove(id)
        guard let window = details[id]?.window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        if foreground == id {
            foreground = nil
            parentWindow()?.makeKeyAndOrderFront(nil)
            restoreFocus()
        }
    }
}

private extension BackgroundTaskState {
    var label: String {
        switch self {
        case .queued: return "Wartet"
        case .running: return "Läuft"
        case .cancelling: return "Wird abgebrochen …"
        case .completed: return "Abgeschlossen"
        case .failed: return "Fehler"
        case .cancelled: return "Abgebrochen"
        case .interrupted: return "Offen · fortsetzbar"
        }
    }
}

private func progressText(_ progress: OperationProgress) -> String {
    var parts: [String] = []
    if let total = progress.totalBytes {
        parts.append("\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
    }
    if let total = progress.totalItems { parts.append("\(progress.completedItems) / \(total) Einträge") }
    else if progress.completedItems > 0 { parts.append("\(progress.completedItems) Einträge geprüft") }
    if let fraction = progress.fraction { parts.append("\(Int(fraction * 100)) %") }
    return parts.joined(separator: " · ")
}

private final class TaskProgressWindow: NSWindowController, NSWindowDelegate {
    var onBackground: (() -> Void)?
    var onCancel: (() -> Void)?
    var onReveal: (() -> Void)?
    var onResume: (() -> Void)?
    private let entryDetails = NSTextView()
    private let resume = NSButton(title: "Wiederholen / Fortsetzen", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let total = NSProgressIndicator()
    private let current = NSProgressIndicator()
    private let counts = NSTextField(labelWithString: "")
    private let currentLabel = NSTextField(labelWithString: "Aktuelle Datei")
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let background = NSButton(title: "In den Hintergrund", target: nil, action: nil)
    private let reveal = NSButton(title: "Ergebnis anzeigen", target: nil, action: nil)
    private var active = true

    init() {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false; panel.delegate = self; panel.center()
        panel.contentView = AppStyle.background(material: .sheet)
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor)
        ])
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        for field in [detail, path, status, counts, currentLabel] {
            field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingMiddle
        }
        status.lineBreakMode = .byWordWrapping; status.maximumNumberOfLines = 3
        for bar in [total, current] { bar.style = .bar; bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 1 }
        total.setAccessibilityLabel("Gesamtfortschritt"); current.setAccessibilityLabel("Fortschritt der aktuellen Datei")
        for view in [heading, detail, status, path, total, counts, currentLabel, current] {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        cancel.target = self; cancel.action = #selector(cancelTask); ContextCommands.configure(cancel, id: "tasks.cancel")
        background.target = self; background.action = #selector(backgroundTask)
        ContextCommands.configure(background, id: "tasks.background")
        reveal.target = self; reveal.action = #selector(revealResult); ContextCommands.configure(reveal, id: "tasks.reveal")
        resume.target = self; resume.action = #selector(resumeTask); ContextCommands.configure(resume, id: "tasks.resume")
        let entriesScroll = NSScrollView(); entriesScroll.documentView = entryDetails; entriesScroll.hasVerticalScroller = true
        entryDetails.frame = NSRect(x: 0, y: 0, width: 700, height: 120)
        entryDetails.isRichText = false
        entryDetails.isEditable = false; entryDetails.isSelectable = true; entryDetails.font = .systemFont(ofSize: 11)
        entryDetails.isVerticallyResizable = true; entryDetails.autoresizingMask = [.width]
        entryDetails.textContainer?.widthTracksTextView = true
        entryDetails.setAccessibilityLabel("Transfer-Einträge und Fehler")
        root.addArrangedSubview(entriesScroll)
        entriesScroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        entriesScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        for button in [cancel, background, reveal, resume] { AppStyle.configureButton(button) }
        let footer = NSStackView(views: [NSView(), resume, reveal, cancel, background]); footer.spacing = 8
        root.addArrangedSubview(NSView()); root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.active { self.onCancel?() } else { self.onBackground?() }
        }
        panel.configureCommands(scope: .tasks) { [weak self] id in
            guard let self else { return false }
            switch id {
            case "tasks.background": self.backgroundTask()
            case "tasks.cancel" where !self.cancel.isHidden && self.cancel.isEnabled: self.cancelTask()
            case "tasks.resume" where self.resume.isEnabled: self.resumeTask()
            case "tasks.reveal" where !self.reveal.isHidden && self.reveal.isEnabled: self.revealResult()
            default: return false
            }
            return true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(_ snapshot: BackgroundTaskSnapshot, canReveal: Bool) {
        window?.title = snapshot.title; heading.stringValue = snapshot.title
        entryDetails.string = snapshot.detail
        resume.isHidden = !snapshot.canResume; resume.isEnabled = snapshot.canResume
        detail.stringValue = snapshot.detail.components(separatedBy: "\n").first ?? ""; detail.toolTip = snapshot.detail
        path.stringValue = snapshot.progress.currentPath ?? ""; path.toolTip = snapshot.progress.currentPath
        status.stringValue = snapshot.state.label + (snapshot.canResume ? " · fortsetzbar" : "") + (snapshot.error.map { " · " + $0 } ?? "")
        status.toolTip = status.stringValue
        counts.stringValue = progressText(snapshot.progress)
        active = snapshot.state.isActive
        let fraction = snapshot.state == .completed ? 1 : snapshot.progress.fraction
        total.isIndeterminate = fraction == nil && active
        if total.isIndeterminate { total.startAnimation(nil) }
        else { total.stopAnimation(nil); total.doubleValue = fraction ?? 0 }
        let fileTotal = snapshot.progress.currentFileTotalBytes
        currentLabel.isHidden = fileTotal == nil; current.isHidden = fileTotal == nil
        if let fileTotal {
            current.doubleValue = fileTotal > 0 ? min(1, Double(snapshot.progress.currentFileBytes) / Double(fileTotal)) : 1
            currentLabel.stringValue = "Aktuelle Datei · \(ByteCountFormatter.string(fromByteCount: snapshot.progress.currentFileBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: fileTotal, countStyle: .file))"
        }
        cancel.isHidden = !active; cancel.isEnabled = snapshot.state != .cancelling
        background.title = active ? "In den Hintergrund" : "Schließen"
        reveal.isHidden = !canReveal || snapshot.state.isActive
    }
    @objc private func cancelTask() { onCancel?() }
    @objc private func backgroundTask() { onBackground?() }
    @objc private func resumeTask() { onResume?() }
    @objc private func revealResult() { onReveal?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onBackground?(); return false }
}

private final class TaskQueueWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onClear: (() -> Void)?
    var onResume: ((UUID) -> Void)?
    var onDiscard: ((UUID) -> Void)?
    private let resume = NSButton(title: "Wiederholen / Fortsetzen", target: nil, action: nil)
    private let discard = NSButton(title: "Verwerfen", target: nil, action: nil)
    private let table = NSTableView()
    private let open = NSButton(title: "Details anzeigen", target: nil, action: nil)
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let clear = NSButton(title: "Beendete entfernen", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var snapshots: [BackgroundTaskSnapshot] = []

    init() {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 400),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Aufgaben-Queue"; panel.minSize = NSSize(width: 960, height: 260)
        panel.isReleasedWhenClosed = false; panel.center(); panel.contentView = AppStyle.background()
        table.style = .inset; table.rowHeight = 30; table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(openTask)
        for (id, title, width) in [("title", "Aufgabe", 280.0), ("state", "Status", 140.0), ("progress", "Fortschritt", 330.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "title" ? 160 : 110
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
        open.target = self; open.action = #selector(openTask); ContextCommands.configure(open, id: "tasks.details")
        cancel.target = self; cancel.action = #selector(cancelTask); ContextCommands.configure(cancel, id: "tasks.cancel")
        clear.target = self; clear.action = #selector(clearTasks); ContextCommands.configure(clear, id: "tasks.clear")
        resume.target = self; resume.action = #selector(resumeTask); ContextCommands.configure(resume, id: "tasks.resume")
        discard.target = self; discard.action = #selector(discardTask); ContextCommands.configure(discard, id: "tasks.discardTransfer")
        for button in [open, cancel, clear, resume, discard] { AppStyle.configureButton(button) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [status, NSView(), clear, discard, resume, cancel, open]); footer.spacing = 8
        let root = NSStackView(views: [scroll, footer]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: panel.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -20), footer.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        panel.onCancel = { [weak self] in self?.close() }; panel.initialFirstResponder = table
        panel.configureCommands(scope: .tasks) { [weak self] id in
            guard let self else { return false }
            switch id {
            case "tasks.details" where self.open.isEnabled: self.openTask()
            case "tasks.cancel" where self.cancel.isEnabled: self.cancelTask()
            case "tasks.resume" where self.resume.isEnabled: self.resumeTask()
            case "tasks.discardTransfer" where self.discard.isEnabled: self.discardTask()
            case "tasks.clear" where self.clear.isEnabled: self.clearTasks()
            default: return false
            }
            return true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(_ snapshots: [BackgroundTaskSnapshot]) {
        let selected = selectedTask?.id
        self.snapshots = snapshots; table.reloadData()
        if let selected, let row = snapshots.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !snapshots.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        status.stringValue = snapshots.isEmpty ? "Keine Aufgaben" : "\(snapshots.filter { $0.state.isActive }.count) aktiv · \(snapshots.count) gesamt"
        updateButtons()
    }
    private var selectedTask: BackgroundTaskSnapshot? { snapshots.indices.contains(table.selectedRow) ? snapshots[table.selectedRow] : nil }
    private func updateButtons() {
        open.isEnabled = selectedTask != nil
        cancel.isEnabled = selectedTask.map { $0.state == .queued || $0.state == .running } ?? false
        clear.isEnabled = snapshots.contains { !$0.state.isActive && !$0.canResume }
        resume.isEnabled = selectedTask?.canResume == true
        discard.isEnabled = selectedTask?.canResume == true
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    @objc private func openTask() { if let selectedTask { onOpen?(selectedTask.id) } }
    @objc private func cancelTask() { if let selectedTask { onCancel?(selectedTask.id) } }
    @objc private func resumeTask() { if let selectedTask { onResume?(selectedTask.id) } }
    @objc private func discardTask() { if let selectedTask { onDiscard?(selectedTask.id) } }
    @objc private func clearTasks() { onClear?() }
    func numberOfRows(in tableView: NSTableView) -> Int { snapshots.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard snapshots.indices.contains(row) else { return nil }
        let task = snapshots[row]
        if tableColumn?.identifier.rawValue == "progress" {
            let bar = NSProgressIndicator(); bar.style = .bar; bar.minValue = 0; bar.maxValue = 1
            bar.isIndeterminate = task.state == .running && task.progress.fraction == nil
            bar.doubleValue = task.state == .completed ? 1 : task.progress.fraction ?? 0
            if bar.isIndeterminate { bar.startAnimation(nil) }
            bar.toolTip = task.error ?? progressText(task.progress)
            bar.setAccessibilityLabel("\(task.title): \(progressText(task.progress))")
            return bar
        }
        let text = tableColumn?.identifier.rawValue == "state" ? task.state.label + (task.canResume ? " · fortsetzbar" : "") : task.title
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = task.error ?? task.detail
        return field
    }
}
