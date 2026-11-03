import AppKit
import PaneRookCore
import PaneRookRemote
import XCTest
@testable import PaneRookApp

final class CommandPaletteTests: XCTestCase {
    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    private final class Host: CommandPaletteHost {
        let commandRegistry: CommandRegistry
        var canUseMenus = true
        var canPresentCommandPalette = true
        var paletteCommandScopes: Set<CommandScope> = [.application, .panel]
        var presentationWindow: NSWindow?
        let leftPane: any PanelAccess
        let rightPane: any PanelAccess
        var activePane: any PanelAccess
        var otherPane: any PanelAccess { activePane === leftPane ? rightPane : leftPane }
        var bookmarks: [ConnectionBookmark] = []
        var archiveError: Error?
        var opened: (ConnectionBookmark, any PanelAccess)?
        init(defaults: UserDefaults) {
            commandRegistry = CommandRegistry(defaults: defaults)
            leftPane = PaneController(label: "Links", directory: URL(fileURLWithPath: "/palette/left"))
            rightPane = PaneController(label: "Rechts", directory: URL(fileURLWithPath: "/palette/right"))
            activePane = leftPane
        }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func savedBookmarks() throws -> [ConnectionBookmark] {
            if let archiveError { throw archiveError }; return bookmarks
        }
        func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess) { opened = (bookmark, pane) }
    }
    private func defaults() -> UserDefaults {
        let name = "CommandPaletteTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func entry(_ id: String, title: String, detail: String = "", enabled: @escaping () -> Bool = { true },
                       run: @escaping () -> Void = {}) -> CommandPaletteEntry {
        CommandPaletteEntry(id: id, title: title, detail: detail, enabled: enabled, run: run)
    }
    private func key(_ code: UInt16, _ text: String, window: NSWindow,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    func testFuzzyRankingUnicodeAndMultipleTermsAcrossFields() {
        let model = CommandPaletteModel()
        model.load([ClosureCommandPaletteSource(title: "Test") { [
            self.entry("fuzzy", title: "Kleine offene Projekte prüfen"),
            self.entry("prefix", title: "Kopieren …"),
            self.entry("exact", title: "Kopieren"),
            self.entry("unicode", title: "Größe ändern", detail: "Favorit · /Straße/Überblick"),
            self.entry("git", title: "Projekt", detail: "Git-Worktree · feature/palette · /code/projekt")
        ] }])
        XCTAssertEqual(model.results(for: "kopieren").map(\.id), ["exact", "prefix"])
        XCTAssertEqual(model.results(for: "kop").first?.id, "exact")
        XCTAssertTrue(model.results(for: "kopp").contains { $0.id == "fuzzy" })
        XCTAssertEqual(model.results(for: "GROSSE strasse uber").map(\.id), ["unicode"])
        XCTAssertEqual(model.results(for: "projekt palette").map(\.id), ["git"])
        XCTAssertTrue(model.results(for: "does-not-exist").isEmpty)
        XCTAssertEqual(model.results(for: " \n ").count, 5)
    }

    func testSourceFailuresDeduplicationStableOrderingAndExecutionRevalidation() {
        let model = CommandPaletteModel()
        var enabled = true, runs = 0
        let current = entry("same", title: "Favorit", enabled: { enabled }, run: { runs += 1 })
        model.load([
            ClosureCommandPaletteSource(title: "Defekt") { throw PanelFavoriteError.invalidPreferences },
            ClosureCommandPaletteSource(title: "Erste") { [current, self.entry("next", title: "Ort")] },
            ClosureCommandPaletteSource(title: "Weitere") { [self.entry("same", title: "Duplikat")] }
        ])
        XCTAssertEqual(model.results(for: "").map(\.title), ["Favorit", "Ort"])
        XCTAssertTrue(model.sourceErrors.first?.hasPrefix("Defekt:") == true)
        enabled = false
        XCTAssertEqual(model.results(for: "").map(\.id), ["next"])
        XCTAssertFalse(current.perform())
        XCTAssertEqual(runs, 0)
        enabled = true
        XCTAssertTrue(current.perform())
        XCTAssertEqual(runs, 1)
    }

    func testRegistrySourceUsesScopeEnabledPolicyAndCurrentBindings() throws {
        _ = NSApplication.shared
        let defaults = defaults(), host = Host(defaults: defaults)
        var available = true, runs = 0
        host.commandRegistry.add(.file, "Kopieren", id: "copy", order: 1, function: 5,
                                 enabled: { available }) { runs += 1 }
        for scope in [CommandScope.panel, .console, .dialog, .git, .textEditing] {
            host.commandRegistry.add(.command, scope.title, id: scope.rawValue, order: 2, scope: scope,
                                     enabled: { true }) {}
        }
        try host.commandRegistry.setBinding(.character("c", modifiers: [.command, .option]), for: "copy")
        let tools = CommandPaletteTools(owner: host, favorites: PanelFavoriteStore(defaults: defaults),
            repositories: GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults)))
        let model = CommandPaletteModel()
        model.load(tools.sources(pane: host.leftPane, scopes: [.application]))
        let copy = try XCTUnwrap(model.results(for: "copy").first)
        XCTAssertEqual(copy.shortcut, "⌥⌘C")
        XCTAssertEqual(model.results(for: "Aktion").map(\.id), ["command:copy"])
        XCTAssertTrue(copy.perform()); XCTAssertEqual(runs, 1)
        available = false
        XCTAssertFalse(copy.perform()); XCTAssertTrue(model.results(for: "copy").isEmpty)
        available = true
        host.activePane = host.rightPane
        XCTAssertFalse(copy.perform(), "A palette cannot silently retarget another panel")
        host.activePane = host.leftPane; host.canUseMenus = false
        XCTAssertFalse(copy.perform(), "Sheets and inactive windows suspend execution")
    }

    func testDestinationSourcesShareFavoritesHistoryConnectionsAndGitSnapshots() throws {
        _ = NSApplication.shared
        let defaults = defaults(), host = Host(defaults: defaults)
        defaults.set(["/palette/left", "/offline/Favorit"], forKey: "hotlist")
        host.bookmarks = [try ConnectionBookmark(name: "Entwicklung", kind: .sftp, host: "example.org", port: 22,
            user: "tester", path: "/projekt")]
        let store = GitRepositoryStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/palette/repo"), locked = URL(fileURLWithPath: "/palette/locked")
        try store.record(GitRepositoryInfo(commonDirectory: root.appendingPathComponent(".git"), worktreeRoot: root,
            worktrees: [GitWorktree(url: root, branch: "main"), GitWorktree(url: locked, branch: "feature", isLocked: true),
                GitWorktree(url: URL(fileURLWithPath: "/palette/missing"), branch: "old", isPrunable: true),
                GitWorktree(url: URL(fileURLWithPath: "/palette/bare"), branch: nil, isBare: true)]), canonicalizePaths: false)
        let tools = CommandPaletteTools(owner: host, favorites: PanelFavoriteStore(defaults: defaults),
                                      repositories: GitRepositoryCatalog(store: store))
        let model = CommandPaletteModel()
        model.load(tools.sources(pane: host.leftPane, scopes: [.application]))
        XCTAssertEqual(model.results(for: "/palette/left").count, 1, "Hotlist and history share one destination")
        XCTAssertEqual(model.results(for: "Favorit").count, 2, "Offline favorites remain searchable without probing")
        XCTAssertEqual(model.results(for: "feature locked").count, 1)
        XCTAssertTrue(model.results(for: "/palette/missing").isEmpty)
        XCTAssertTrue(model.results(for: "/palette/bare").isEmpty)
        XCTAssertEqual(model.results(for: "/palette/right").count, 1, "Both panels contribute history")
        let connection = try XCTUnwrap(model.results(for: "tester example projekt").first)
        XCTAssertTrue(connection.perform())
        XCTAssertEqual(host.opened?.0, host.bookmarks.first)
        XCTAssertTrue(host.opened?.1 === host.leftPane)
        host.archiveError = ConnectionBookmarkError.invalidArchive
        model.load(tools.sources(pane: host.leftPane, scopes: [.application]))
        XCTAssertTrue(model.sourceErrors.first?.hasPrefix("Verbindungen:") == true)
        XCTAssertFalse(model.results(for: "Favorit").isEmpty)
    }

    func testPaletteShortcutIsConflictFreeCustomizableAndPersisted() throws {
        _ = NSApplication.shared
        let defaults = defaults(), commander = CommanderController()
        let registry = commander.makeCommandRegistry(defaults: defaults)
        let binding = try XCTUnwrap(registry.bindings["commands.palette"])
        XCTAssertEqual(binding, .character("p", modifiers: [.command, .shift]))
        XCTAssertNil(registry.conflicts(for: binding, assigningTo: "commands.palette"))
        try registry.setBinding(.character("p", modifiers: [.command, .option]), for: "commands.palette")
        XCTAssertEqual(commander.makeCommandRegistry(defaults: defaults).bindings["commands.palette"]?.label, "⌥⌘P")
        try registry.setBinding(nil, for: "commands.palette")
        XCTAssertNil(commander.makeCommandRegistry(defaults: defaults).bindings["commands.palette"])
    }

    func testFavoriteNavigationUsesCapturedPanelAndExistingAsyncNavigation() throws {
        _ = NSApplication.shared
        let defaults = defaults(), host = Host(defaults: defaults)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Palette-\(UUID())")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        defaults.set([destination.path], forKey: "hotlist")
        let tools = CommandPaletteTools(owner: host, favorites: PanelFavoriteStore(defaults: defaults),
            repositories: GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults)))
        let model = CommandPaletteModel()
        model.load(tools.sources(pane: host.leftPane, scopes: []))
        let favorite = try XCTUnwrap(model.results(for: destination.lastPathComponent).first)
        XCTAssertTrue(favorite.perform())
        host.activePane = host.rightPane
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.leftPane.directory.standardizedFileURL.path == destination.standardizedFileURL.path
        }, object: nil)], timeout: 5)
        XCTAssertEqual(host.rightPane.directory.path, "/palette/right")
        XCTAssertTrue(host.activePane === host.rightPane, "A late navigation completion must not steal focus")
    }

    func testNativeOverlayKeyboardDispatchAndFocusRestoration() throws {
        _ = NSApplication.shared
        let commander = CommanderController()
        commander.commandRegistry = commander.makeCommandRegistry(defaults: defaults())
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = commander
        window.setContentSize(NSSize(width: 1100, height: 700))
        defer { commander.commandPalette.dismiss(); window.close() }
        commander.activate(commander.left)
        let origin = window.firstResponder
        // The palette's menu item must stay available during native menu tracking.
        // The keyboard dispatcher still yields menu navigation to AppKit.
        commander.menuIsTracking = { true }
        XCTAssertTrue(commander.commandRegistry["commands.palette"]!.enabled())
        commander.menuIsTracking = nil
        var runs = 0, restoredBeforeExecution = false
        commander.commandRegistry.add(.command, "Paletten-Testaktion", id: "test.palette", order: 0,
            enabled: { commander.canUseMenus }) {
                restoredBeforeExecution = window.firstResponder === origin && !commander.commandPalette.isPresented
                runs += 1
            }
        XCTAssertTrue(commander.commandRegistry["commands.palette"]!.perform())
        let palette = try XCTUnwrap(commander.commandPalette.controller)
        XCTAssertFalse(commander.canHandleMainKeys)
        palette.search.stringValue = "Paletten-Testaktion"; palette.reload()
        XCTAssertEqual(palette.results.count, 1)
        window.contentView?.layoutSubtreeIfNeeded()
        palette.table.enclosingScrollView?.tile()
        XCTAssertGreaterThan(palette.table.visibleRect.height, 0)
        XCTAssertTrue(try commander.handleGlobalKey(key(96, AppKeyBinding.function(5).characters, window: window)))
        XCTAssertEqual(runs, 0)
        XCTAssertTrue(try commander.handleGlobalKey(key(36, "\r", window: window)))
        XCTAssertEqual(runs, 1); XCTAssertTrue(restoredBeforeExecution)
        XCTAssertFalse(commander.commandPalette.isPresented)
        commander.commandPalette.show()
        let reopened = try XCTUnwrap(commander.commandPalette.controller)
        XCTAssertEqual(reopened.table.selectedRow, 0)
        XCTAssertTrue(try commander.handleGlobalKey(key(125, functionKey(NSDownArrowFunctionKey), window: window)))
        XCTAssertEqual(reopened.table.selectedRow, 1)
        XCTAssertTrue(try commander.handleGlobalKey(key(119, functionKey(NSEndFunctionKey), window: window)))
        XCTAssertEqual(reopened.table.selectedRow, reopened.results.count - 1)
        reopened.search.stringValue = "kein-treffer-xyz"; reopened.reload()
        XCTAssertTrue(reopened.results.isEmpty)
        XCTAssertTrue(try commander.handleGlobalKey(key(36, "\r", window: window)))
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(try commander.handleGlobalKey(key(53, "\u{1b}", window: window)))
        XCTAssertFalse(commander.commandPalette.isPresented)
        XCTAssertTrue(window.firstResponder === origin)
    }

    func testStaleEntryAndUnrelatedDialogCannotExecute() throws {
        _ = NSApplication.shared
        let defaults = defaults(), host = Host(defaults: defaults)
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; host.presentationWindow = window
        let tools = CommandPaletteTools(owner: host, favorites: PanelFavoriteStore(defaults: defaults),
                                      repositories: GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults)))
        defer { tools.dismiss(); window.close() }
        var enabled = true, runs = 0
        host.commandRegistry.add(.command, "Testaktion", id: "test", order: 0, enabled: { enabled }) { runs += 1 }
        tools.show()
        let palette = try XCTUnwrap(tools.controller)
        palette.search.stringValue = "Testaktion"; palette.reload()
        enabled = false
        palette.executeSelection()
        XCTAssertEqual(runs, 0); XCTAssertTrue(palette.results.isEmpty)
        tools.dismiss()
        let sheet = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        tools.show()
        XCTAssertFalse(tools.isPresented)
        window.endSheet(sheet)
        KeyboardCaptureState.isRecording = true
        defer { KeyboardCaptureState.isRecording = false }
        tools.show()
        XCTAssertFalse(tools.isPresented)
    }

    func testClosingRestoresTheOriginalFieldEditorAndSelection() throws {
        _ = NSApplication.shared
        let defaults = defaults(), host = Host(defaults: defaults)
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; host.presentationWindow = window
        let path = NSTextField(frame: NSRect(x: 20, y: 20, width: 600, height: 24))
        path.stringValue = "/ursprung/ordner"
        window.contentView?.addSubview(path)
        path.selectText(nil)
        let editor = try XCTUnwrap(path.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        let tools = CommandPaletteTools(owner: host, favorites: PanelFavoriteStore(defaults: defaults),
            repositories: GitRepositoryCatalog(store: GitRepositoryStore(defaults: defaults)))
        defer { tools.dismiss(); window.close() }
        tools.show()
        XCTAssertNotNil(tools.controller?.search.currentEditor())
        tools.controller?.search.stringValue = "Suchtext"
        tools.dismiss()
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate === path)
        XCTAssertEqual(path.stringValue, "/ursprung/ordner")
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 2, length: 3))
    }
}
