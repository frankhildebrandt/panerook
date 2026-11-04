import AppKit

/// Contextual actions are listed even before their window has been opened.
struct ContextCommandDefinition {
    let id: String
    let title: String
    let scope: CommandScope
    let defaultBinding: AppKeyBinding?
    init(id: String, title: String, scope: CommandScope, defaultBinding: AppKeyBinding? = nil) {
        self.id = id; self.title = title; self.scope = scope; self.defaultBinding = defaultBinding
    }
}

enum ContextCommands {
    static let definitions: [ContextCommandDefinition] = {
        var items: [ContextCommandDefinition] = []
        func add(_ scope: CommandScope, _ id: String, _ title: String, _ binding: AppKeyBinding? = nil) {
            items.append(.init(id: id, title: title, scope: scope, defaultBinding: binding))
        }
        add(.dialog, "dialog.accept", "Dialog bestätigen", .physical(36, characters: "\r"))
        add(.dialog, "dialog.accept.keypad", "Dialog bestätigen (Ziffernblock)", .physical(76, characters: "\u{3}"))
        add(.dialog, "dialog.cancel", "Dialog oder Menü abbrechen", .physical(53, characters: "\u{1b}"))
        add(.dialog, "dialog.cancel.function", "Dialog oder Menü abbrechen (Funktionstaste)", .function(10))
        add(.dialog, "dialog.cancel.control", "Dialog oder Menü abbrechen (Alternative)", .character("g", modifiers: .control))
        // Embedded remote panes use the shared main actions by default (copy, mkdir, trash and navigation).
        // Explicit remote-specific overrides remain available under their persistent IDs.
        add(.remote, "remote.focusPath", "Remote-Pfad bearbeiten")
        add(.remote, "remote.open", "Remote-Auswahl öffnen")
        add(.remote, "remote.open.keypad", "Remote-Auswahl öffnen (Ziffernblock)")
        add(.remote, "remote.parent", "Remote: übergeordneter Ordner")
        add(.remote, "remote.parent.delete", "Remote: übergeordneter Ordner (Entfernen)")
        add(.remote, "remote.download", "Remote-Auswahl herunterladen")
        add(.remote, "remote.upload", "Lokale Auswahl hochladen …")
        add(.remote, "remote.mkdir", "Remote-Ordner anlegen …")
        add(.remote, "remote.delete", "Remote-Auswahl löschen …")
        add(.remote, "remote.refresh", "Remote-Verzeichnis aktualisieren")
        add(.remote, "remote.close", "Remote-Verbindung trennen oder Vorgang abbrechen", .function(10))
        add(.connections, "connections.new", "Verbindung anlegen …", .character("n"))
        add(.connections, "connections.edit", "Verbindung bearbeiten …", .character("e"))
        add(.connections, "connections.remove", "Verbindung entfernen", .physical(51, characters: "\u{8}", modifiers: .command))
        add(.connections, "connections.undo", "Entfernte Verbindung wiederherstellen", .character("z"))
        add(.connections, "connections.connect", "Mit ausgewählter Verbindung verbinden", .physical(36, characters: "\r"))
        add(.connections, "connections.connect.keypad", "Verbinden (Ziffernblock)", .physical(76, characters: "\u{3}"))
        add(.connections, "connections.search", "Verbindungen durchsuchen")
        for (id, title) in [
            ("refresh", "Repository aktualisieren"), ("stage", "Auswahl stagen"), ("unstage", "Auswahl unstagen"),
            ("commit", "Vorgemerkte Änderungen committen …"), ("watch", "Auswahl beobachten"),
            ("branch.new", "Branch anlegen …"), ("branch.switch", "Ausgewählten Branch oder Tag auschecken"),
            ("branch.merge", "Ausgewählten Branch mergen …"), ("branch.delete", "Ausgewählten Branch löschen …"),
            ("tag", "Tag anlegen …"), ("fetch", "Fetch"), ("pull", "Pull (nur Fast-Forward)"), ("push", "Push …"),
            ("checkout", "Ausgewählte Version auschecken …"), ("historicFile", "Datei der ausgewählten Version anzeigen"),
            ("stash.save", "Stash anlegen …"), ("stash.apply", "Ausgewählten Stash anwenden"),
            ("stash.pop", "Ausgewählten Stash anwenden und entfernen …"), ("stash.drop", "Ausgewählten Stash löschen …"),
            ("mode.files", "Git-Dateien anzeigen"), ("mode.history", "Git-Verlauf anzeigen"), ("mode.stashes", "Git-Stashes anzeigen"),
            ("diff.working", "Diff der Arbeitskopie anzeigen"), ("diff.staged", "Staged-Diff anzeigen"),
            ("diff.unified", "Unified Diff anzeigen"), ("diff.sideBySide", "Side-by-Side Diff anzeigen"),
            ("search", "Git-Einträge durchsuchen"), ("historyPath", "Dateipfad für Git-Verlauf bearbeiten")
        ] { add(.git, "git." + id, title) }
        for (index, title) in ["Alle", "Changed", "Staged", "Untracked", "Conflicted", "Stashed", "Watched", "Tracked", "Ignored"].enumerated() {
            add(.git, "git.filter.\(index)", "Git-Filter: " + title)
        }
        add(.table, "table.home", "Ersten Listeneintrag auswählen", .physical(115, characters: functionKey(NSHomeFunctionKey)))
        add(.table, "table.end", "Letzten Listeneintrag auswählen", .physical(119, characters: functionKey(NSEndFunctionKey)))
        add(.table, "table.pageUp", "Eine Seite nach oben", .physical(116, characters: functionKey(NSPageUpFunctionKey)))
        add(.table, "table.pageDown", "Eine Seite nach unten", .physical(121, characters: functionKey(NSPageDownFunctionKey)))
        for (id, title) in [("addCurrent", "Aktuellen Ordner als Favorit hinzufügen"), ("addFolder", "Ordner als Favorit hinzufügen …"),
                            ("remove", "Ordnerfavoriten entfernen …"), ("connections", "Verbindungsarchiv öffnen …"),
                            ("refreshRepositories", "Git-Worktrees aktualisieren")] {
            add(.favorites, "favorites." + id, title)
        }
        for (kind, title) in [("iCloudDrive", "iCloud Drive"), ("protonDrive", "Proton Drive"), ("dropbox", "Dropbox")] {
            add(.favorites, "favorites.cloud.choose." + kind, title + "-Ordner auswählen …")
            add(.favorites, "favorites.cloud.reset." + kind, title + "-Ordner automatisch erkennen")
        }
        add(.tasks, "tasks.details", "Details der ausgewählten Aufgabe anzeigen", .physical(36, characters: "\r"))
        add(.tasks, "tasks.cancel", "Ausgewählte Aufgabe abbrechen")
        add(.tasks, "tasks.clear", "Beendete Aufgaben entfernen")
        add(.tasks, "tasks.background", "Aufgabe in den Hintergrund / Fortschritt schließen", .character("b", modifiers: .option))
        add(.tasks, "tasks.resume", "Transfer wiederholen / fortsetzen")
        add(.tasks, "tasks.discardTransfer", "Offenen Transferauftrag verwerfen")
        add(.tasks, "tasks.reveal", "Aufgabenergebnis anzeigen")
        for (id, title) in [("open", "Arbeitskopie im Editor öffnen"), ("upload", "Remote-Änderungen hochladen / wiederholen"),
                            ("cancel", "Remote-Upload abbrechen"), ("stop", "Beobachtung beenden …"),
                            ("reveal", "Arbeitskopien im Finder zeigen")] {
            add(.remoteEdit, "remoteEdit." + id, title)
        }
        add(.results, "results.reveal", "Ausgewählten Treffer im Panel zeigen", .physical(36, characters: "\r"))
        add(.results, "results.panelize", "Treffer ins Panel übernehmen")
        for (id, title) in [("preview", "Synchronisationsvorschau erstellen"), ("execute", "Synchronisation bestätigen …"),
                            ("selectAll", "Alle Sync-Aktionen auswählen"), ("selectNone", "Keine Sync-Aktionen auswählen"),
                            ("profile.save", "Synchronisationsprofil speichern"), ("profile.remove", "Synchronisationsprofil entfernen")] {
            add(.results, "sync." + id, title)
        }
        add(.network, "network.open", "Ausgewählten Netzwerkserver öffnen", .physical(36, characters: "\r"))
        add(.network, "network.open.keypad", "Netzwerkserver öffnen (Ziffernblock)", .physical(76, characters: "\u{3}"))
        add(.network, "network.connect", "Mit Netzwerkserver verbinden …")
        add(.network, "network.refresh", "Netzwerk aktualisieren")
        return items
    }()

    static func binding(for id: String, defaults: UserDefaults = .standard) -> AppKeyBinding? {
        let registry = CommandRegistry(defaults: defaults)
        registry.addContextDefinitions()
        return registry.bindings[id]
    }
    static func matching(_ event: NSEvent, scope: CommandScope, defaults: UserDefaults = .standard) -> String? {
        guard !KeyboardCaptureState.isRecording else { return nil }
        let registry = CommandRegistry(defaults: defaults)
        registry.addContextDefinitions()
        let bindings = registry.bindings
        return definitions.first { $0.scope == scope && bindings[$0.id]?.matches(event) == true }?.id
    }
    static func matches(_ id: String, _ event: NSEvent) -> Bool {
        !KeyboardCaptureState.isRecording && binding(for: id)?.matches(event) == true
    }
    static func isCancellation(_ event: NSEvent) -> Bool {
        guard let id = matching(event, scope: .dialog) else { return false }
        return id.hasPrefix("dialog.cancel")
    }
    /// Printable unmodified shortcuts yield to text fields, including inside dialogs.
    static func preservesTextInput(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextView, text.isEditable,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy {
            $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value)
        }
    }
    static func canHandle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard !KeyboardCaptureState.isRecording, window.attachedSheet == nil else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable {
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
            return !flags.isEmpty || (UInt32(NSF1FunctionKey)...UInt32(NSF35FunctionKey)).contains(scalar)
        }
        return true
    }
    static func button(in view: NSView?, id: String) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
        return view.subviews.compactMap { button(in: $0, id: id) }.first
    }
    static func configure(_ button: NSButton, id: String) {
        // Events are dispatched against the current mapping by the window monitor.
        button.keyEquivalent = ""
        button.identifier = NSUserInterfaceItemIdentifier(id)
        if let binding = binding(for: id) { button.toolTip = button.title + " · " + binding.label }
    }
}
