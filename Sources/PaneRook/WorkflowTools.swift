import AppKit
import PaneRookCore
import Darwin

private struct CommandTaskFailure: LocalizedError {
    let status: Int32
    var errorDescription: String? { "Befehl beendet mit Exit \(status)." }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CommandResult?
    func store(_ result: CommandResult) { lock.lock(); value = result; lock.unlock() }
    var result: CommandResult? { lock.lock(); defer { lock.unlock() }; return value }
}

final class WorkflowTools {
    private unowned let owner: CommanderController
    private var results: [TextResultWindow] = []
    private var fileHistory: [URL] = []
    private var invalidConfigurations: [String: Data] = [:]
    private let defaults = UserDefaults.standard
    init(owner: CommanderController) { self.owner = owner }
    func cancelAll() { owner.tasks.cancelAll() }
    private var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PaneRook", isDirectory: true)
    }
    private func load<T: Decodable>(_ name: String, fallback: T) -> T {
        guard let data = try? Data(contentsOf: configDirectory.appendingPathComponent(name)) else { return fallback }
        do {
            let value = try JSONDecoder().decode(T.self, from: data)
            invalidConfigurations.removeValue(forKey: name)
            return value
        } catch {
            if invalidConfigurations[name] != data {
                invalidConfigurations[name] = data
                DispatchQueue.main.async { [weak self] in
                    self?.owner.showError(NSError(domain: "PaneRook", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "\(name) ist keine gültige Konfiguration."]), detail: error.localizedDescription)
                }
            }
            return fallback
        }
    }
    private let defaultCommands = [
        UserCommand(title: "Ordnerinhalt", command: "/bin/ls -lah"),
        UserCommand(title: "Speicherbelegung", command: "/usr/bin/du -sh ."),
        UserCommand(title: "Git-Status", command: "/usr/bin/git status --short")
    ]
    func userMenu() {
        guard owner.canUseMenus else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveCommandError); return }
        let commands = load("menu.json", fallback: defaultCommands)
        ToolUI.choose(owner: owner, title: "Benutzermenü", labels: commands.map(\.title), accept: "Ausführen", extra: "Befehl eingeben …") { [weak self] index, extra in
            guard let self else { return }
            if extra { self.commandPrompt() }
            else if commands.indices.contains(index) { self.execute(commands[index].command, title: commands[index].title) }
        }
    }
    func commandPrompt(initial: String = "") {
        guard owner.canUseMenus else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveCommandError); return }
        ToolUI.prompt(owner: owner, title: "Befehl ausführen", label: "Shell-Befehl · aktueller Panelordner", value: initial, accept: "Ausführen") { [weak self] command in
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self?.execute(command, title: command)
        }
    }
    func runCommand(_ command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        execute(command, title: command)
    }
    func filteredView() {
        guard owner.canUseMenus else { return }
        guard !owner.active.isArchiveDirectory else { owner.showError(archiveCommandError); return }
        guard let source = owner.active.selectedFiles.first else { return }
        ToolUI.prompt(owner: owner, title: "Gefilterte Ansicht", label: "Filter · Datei steht in $PANEROOK_FILE",
                      value: "/usr/bin/sed -n '1,200p' \"$PANEROOK_FILE\"", accept: "Anzeigen") { [weak self] command in
            self?.execute(command, title: source.lastPathComponent, selection: [source])
        }
    }
    func panelize(external: Bool = true, pane: PaneController? = nil) {
        let target = pane ?? owner.active!
        guard !target.isArchiveDirectory else { owner.showError(archiveCommandError); return }
        ToolUI.prompt(owner: owner, title: external ? "Externes Anordnen" : "Anordnen", label: "Befehl mit einem Dateipfad pro Ausgabezeile",
                      value: "/usr/bin/find . -maxdepth 1 -type f -print", accept: "Anordnen") { [weak self, weak target] command in
            guard let self, let target else { return }
            let base = target.directory
            self.execute(command, title: "Anordnen", directory: base) { output in
                let urls = output.split(separator: "\n").map(String.init).map {
                    $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : base.appendingPathComponent($0).standardizedFileURL
                }.filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }
                guard target.canApplyTaskResult(in: base) else { return }
                target.panelize(Array(Set(urls)))
            }
        }
    }
    private func execute(_ command: String, title: String, selection: [URL]? = nil,
                         directory: URL? = nil, success: ((String) -> Void)? = nil) {
        let cwd = directory ?? owner.active.directory
        let files = selection ?? owner.active.selectedFiles
        guard ArchiveFileSystem.location(for: cwd) == nil,
              !files.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) else {
            owner.showError(archiveCommandError); return
        }
        let environment = ["PANEROOK_FILE": files.first?.path ?? "", "PANEROOK_DIRECTORY": cwd.path,
                           "PANEROOK_OTHER_DIRECTORY": owner.other.directory.path,
                           "PANEROOK_SELECTION_JSON": String(data: (try? JSONEncoder().encode(files.map(\.path))) ?? Data(), encoding: .utf8) ?? "[]"]
        if defaults.object(forKey: "rememberCommands") as? Bool ?? true {
            var history = defaults.stringArray(forKey: "commandHistory") ?? []
            history.removeAll { $0 == command }; history.insert(command, at: 0)
            defaults.set(Array(history.prefix(100)), forKey: "commandHistory")
        }
        let task = CommandExecution()
        let output = CommandOutput()
        let window = TextResultWindow(title: title)
        results.append(window)
        owner.tasks.submit(title: title, detail: "\(command)\n\(cwd.path)", cancellation: { task.cancel() },
            work: { report in
                // Arbitrary shell commands do not expose a reliable total.
                report(OperationProgress(currentPath: cwd.path))
                let value = try task.run(command, in: cwd, environment: environment)
                output.store(value)
                guard value.status == 0 || value.wasCancelled else { throw CommandTaskFailure(status: value.status) }
                return value
            }, onReveal: { window.present() }, completion: { [weak self] result in
                if let value = output.result {
                    let text = value.output + (value.errorOutput.isEmpty ? "" : "\n" + value.errorOutput)
                    let status = value.wasCancelled ? "Abgebrochen" : "Exit \(value.status)" + (value.truncated ? " · Ausgabe gekürzt" : "")
                    window.setContent(text, status: status, running: false)
                    if case .success = result, value.status == 0 && !value.wasCancelled && !value.truncated { success?(value.output) }
                } else if case .failure(let error) = result {
                    window.setContent(error.localizedDescription, status: "Fehler", running: false)
                }
                self?.owner.refreshAfterTask()
            })
    }
    private var archiveCommandError: NSError {
        NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Shell-Befehle benötigen einen lokalen Ordner. Bitte Archiveinträge zuerst dorthin kopieren."])
    }
    func backgroundJobs() { owner.tasks.showQueue() }
    func commandHistory() {
        let history = defaults.stringArray(forKey: "commandHistory") ?? []
        ToolUI.choose(owner: owner, title: "Befehlschronik", labels: history, accept: "Bearbeiten …", extra: "Chronik leeren") { [weak self] index, extra in
            if extra { self?.defaults.removeObject(forKey: "commandHistory") }
            else if history.indices.contains(index) { self?.commandPrompt(initial: history[index]) }
        }
    }
    func recordFiles(_ urls: [URL]) {
        for url in urls { fileHistory.removeAll { $0 == url }; fileHistory.insert(url, at: 0) }
        fileHistory = Array(fileHistory.prefix(100))
        defaults.set(fileHistory.map(\.path), forKey: "fileHistory")
    }
    func showFileHistory() {
        if fileHistory.isEmpty { fileHistory = (defaults.stringArray(forKey: "fileHistory") ?? []).map { URL(fileURLWithPath: $0) } }
        ToolUI.choose(owner: owner, title: "Angezeigte/bearbeitete Dateien", labels: fileHistory.map(\.path), accept: "Anzeigen", extra: "Chronik leeren") { [weak self] index, extra in
            guard let self else { return }
            if extra { self.fileHistory = []; self.defaults.removeObject(forKey: "fileHistory") }
            else if self.fileHistory.indices.contains(index) {
                self.owner.previewFiles([self.fileHistory[index]])
            }
        }
    }
    func hotlist() {
        let stored = defaults.stringArray(forKey: "hotlist") ?? []
        let visited = owner.active.visitedDirectories.map(\.path).filter { !stored.contains($0) }
        let paths = stored + visited
        ToolUI.choose(owner: owner, title: "Verzeichnis-Hotlist", labels: paths, extra: "Aktuellen Ordner merken") { [weak self] index, add in
            guard let self else { return }
            if add {
                let path = self.owner.active.directory.path
                self.defaults.set(stored.contains(path) ? stored : stored + [path], forKey: "hotlist")
            } else if paths.indices.contains(index) { self.owner.active.navigate(to: URL(fileURLWithPath: paths[index])) }
        }
    }
    func manageHotlist() {
        let paths = defaults.stringArray(forKey: "hotlist") ?? []
        ToolUI.choose(owner: owner, title: "Hotlist bearbeiten", labels: paths, accept: "Entfernen") { [weak self] index, _ in
            guard paths.indices.contains(index) else { return }
            self?.defaults.set(paths.enumerated().filter { $0.offset != index }.map(\.element), forKey: "hotlist")
        }
    }
    func screenList() {
        let windows = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil && !$0.title.isEmpty }
        ToolUI.choose(owner: owner, title: "Bildschirmliste", labels: windows.map(\.title)) { index, _ in
            guard windows.indices.contains(index) else { return }
            windows[index].makeKeyAndOrderFront(nil)
        }
    }
    func editConfiguration(_ kind: String) {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let url = configDirectory.appendingPathComponent(kind + ".json")
            if !FileManager.default.fileExists(atPath: url.path) {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data: Data
                switch kind {
                case "menu": data = try encoder.encode(defaultCommands)
                case "extensions": data = try encoder.encode([ExtensionAction(pattern: "*.txt", application: "/System/Applications/TextEdit.app")])
                default: data = try encoder.encode([HighlightRule(pattern: "*.swift", color: "blue"), HighlightRule(pattern: "*.md", color: "green")])
                }
                try data.write(to: url, options: .atomic)
            }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: .init()) { [weak self] _, error in
                if let error { DispatchQueue.main.async { self?.owner.showError(error) } }
            }
        } catch { owner.showError(error) }
    }
    func openUsingExtension(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else { return false }
        let rules = load("extensions.json", fallback: [ExtensionAction]())
        guard let rule = rules.first(where: { fnmatch($0.pattern, url.lastPathComponent, 0) == 0 }) else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: (rule.application as NSString).expandingTildeInPath), configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.owner.showError(error) } }
        }
        return true
    }
    func applyHighlights() {
        let colors: [String: NSColor] = ["blue": .systemBlue, "green": .systemGreen, "orange": .systemOrange,
            "red": .systemRed, "purple": .systemPurple, "gray": .secondaryLabelColor]
        let rules = load("highlight.json", fallback: [HighlightRule]()).compactMap { rule -> (pattern: String, color: NSColor)? in
            guard let color = colors[rule.color.lowercased()] else { return nil }
            return (rule.pattern, color)
        }
        owner.left.applyHighlights(rules); owner.right.applyHighlights(rules)
    }
}
