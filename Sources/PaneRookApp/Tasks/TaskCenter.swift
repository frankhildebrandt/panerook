import PaneRookTasks
import AppKit
import PaneRookCore

/// Owns progress windows independently of the panels and the workers' captured paths.
final class TaskCenter {
    private let parentWindow: () -> NSWindow?
    private let restoreFocus: () -> Void
    private let queue = BackgroundTaskQueue()
    private var details: [UUID: TaskProgressWindow] = [:]
    private var resultActions: [UUID: () -> Void] = [:]
    private var foreground: UUID?
    private var pendingPresentation = Set<UUID>()
    private var presentationIntent = Set<UUID>()
    private var queueWindow: TaskQueueWindow?
    private var idleHandler: (() -> Void)?
    var onChange: (() -> Void)?

    init(parentWindow: @escaping () -> NSWindow?, restoreFocus: @escaping () -> Void) {
        self.parentWindow = parentWindow
        self.restoreFocus = restoreFocus
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
        if tasks.isEmpty { return "Keine Aufgaben" }
        let failed = tasks.filter { $0.state == .failed }.count
        return failed > 0 ? "\(failed) Aufgaben mit Fehlern" : "Alle Aufgaben beendet"
    }

    @discardableResult
    func submit<Value>(title: String, detail: String = "", cancellation: @escaping () -> Void = {},
                       work: @escaping (@escaping (OperationProgress) -> Void) throws -> Value,
                       onReveal: (() -> Void)? = nil,
                       completion: @escaping (Result<Value, Error>) -> Void) -> UUID {
        var id: UUID!
        id = queue.submit(title: title, detail: detail, cancellation: cancellation, work: work) { [weak self] result in
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
    func cancel(_ id: UUID) { queue.cancel(id) }
    func cancelAll() { queue.cancelAll() }
    func cancelAll(whenFinished completion: @escaping () -> Void) {
        idleHandler = completion
        queue.cancelAll()
        if !hasActiveTasks { idleHandler = nil; completion() }
    }
    func showQueue() {
        if queueWindow == nil {
            queueWindow = TaskQueueWindow()
            queueWindow?.onOpen = { [weak self] id in self?.showTask(id) }
            queueWindow?.onCancel = { [weak self] id in self?.queue.cancel(id) }
            queueWindow?.onClear = { [weak self] in
                guard let self else { return }
                let finished = self.queue.snapshots.filter { !$0.state.isActive }.map(\.id)
                for id in finished {
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
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 320),
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
        for button in [cancel, background, reveal] { AppStyle.configureButton(button) }
        let footer = NSStackView(views: [NSView(), reveal, cancel, background]); footer.spacing = 8
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
            case "tasks.reveal" where !self.reveal.isHidden && self.reveal.isEnabled: self.revealResult()
            default: return false
            }
            return true
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func update(_ snapshot: BackgroundTaskSnapshot, canReveal: Bool) {
        window?.title = snapshot.title; heading.stringValue = snapshot.title
        detail.stringValue = snapshot.detail; detail.toolTip = snapshot.detail
        path.stringValue = snapshot.progress.currentPath ?? ""; path.toolTip = snapshot.progress.currentPath
        status.stringValue = snapshot.state.label + (snapshot.error.map { " · " + $0 } ?? "")
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
    @objc private func revealResult() { onReveal?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onBackground?(); return false }
}

private final class TaskQueueWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onOpen: ((UUID) -> Void)?
    var onCancel: ((UUID) -> Void)?
    var onClear: (() -> Void)?
    private let table = NSTableView()
    private let open = NSButton(title: "Details anzeigen", target: nil, action: nil)
    private let cancel = NSButton(title: "Abbrechen", target: nil, action: nil)
    private let clear = NSButton(title: "Beendete entfernen", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var snapshots: [BackgroundTaskSnapshot] = []

    init() {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 400),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Aufgaben-Queue"; panel.minSize = NSSize(width: 620, height: 260)
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
        for button in [open, cancel, clear] { AppStyle.configureButton(button) }
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [status, NSView(), clear, cancel, open]); footer.spacing = 8
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
        clear.isEnabled = snapshots.contains { !$0.state.isActive }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    @objc private func openTask() { if let selectedTask { onOpen?(selectedTask.id) } }
    @objc private func cancelTask() { if let selectedTask { onCancel?(selectedTask.id) } }
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
        let text = tableColumn?.identifier.rawValue == "state" ? task.state.label : task.title
        let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = task.error ?? task.detail
        return field
    }
}
