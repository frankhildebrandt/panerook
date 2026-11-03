import AppKit
import PaneRookCore
import PaneRookPanels
import XCTest

@testable import PaneRookApp

final class GitHistoryPaneTests: XCTestCase {
    private var temporary: URL!
    private var repository: URL!
    private var ordinary: URL!
    private var file: URL { repository.appendingPathComponent("versioned file.txt") }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PaneRook-history-ui-" + UUID().uuidString)
        repository = temporary.appendingPathComponent("repository", isDirectory: true)
        ordinary = temporary.appendingPathComponent("ordinary", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: false)
        try Data("own pane selection\n".utf8).write(to: ordinary.appendingPathComponent("own.txt"))
        try git(["init", "-b", "main"])
        try Data("one\n".utf8).write(to: file)
        try git(["add", "."])
        try git(["commit", "-m", "First version"])
        try Data("two\n".utf8).write(to: file)
        try git(["add", "."])
        try git(["commit", "-m", "Second version"])
        try Data("staged\n".utf8).write(to: file)
        try git(["add", "."])
        try Data("working\n".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = repository
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
            "-c", "user.name=PaneRook Tests", "-c", "user.email=tests@panerook.invalid"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError(String(decoding: data, as: UTF8.self)) }
    }

    private func eventually(timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard condition() else {
            XCTFail("Git history pane did not reach the expected state", file: file, line: line)
            throw GitError("Git history UI test timed out")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func control<T: NSView>(_ type: T.Type, label: String, in view: NSView) throws -> T {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
    }

    private func showsCommit(_ subject: String, in viewer: GitHistoryView, text: NSTextView) -> Bool {
        let heading = descendants(of: viewer).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Commit-Nachricht" }
        return heading?.stringValue == subject && text.string.hasPrefix("diff --git ")
    }

    private func invoke(_ control: NSControl) {
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
    }

    private func choose(_ control: NSSegmentedControl, _ index: Int) {
        control.selectedSegment = index
        invoke(control)
    }

    private func loadAndSelectFile(in pane: PaneController) throws {
        try select(file.lastPathComponent, in: pane)
        XCTAssertEqual(pane.selectedFiles.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
    }

    private func select(_ name: String, in pane: PaneController) throws {
        _ = pane.view
        try eventually { pane.entries.contains { $0.name == name } }
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == name })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func connect(_ viewer: PaneController, to source: PaneController) {
        viewer.onGitHistoryRequested = { [weak viewer, weak source] in
            guard let viewer, let source else { return }
            viewer.showGitHistory(from: source)
        }
        source.onSelectionChanged = { [weak viewer, weak source] _ in
            guard let viewer, let source else { return }
            viewer.showGitHistory(from: source)
        }
    }

    private func historyView(in pane: PaneController) throws -> GitHistoryView {
        try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? GitHistoryView }.first)
    }
}

extension GitHistoryPaneTests {
    func testPaneShowsFileVersionsAndWorkingStagedDiffsWithoutChangingGit() throws {
        let gitRepository = try GitRepository(directory: repository)
        let before = try gitRepository.snapshot()
        let sourcePane = PaneController(label: "Files", directory: repository)
        let pane = PaneController(label: "History", directory: ordinary)
        try loadAndSelectFile(in: sourcePane)
        try select("own.txt", in: pane)
        connect(pane, to: sourcePane)
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        pane.setMode(.gitHistory)
        XCTAssertEqual(pane.mode, .gitHistory)
        XCTAssertTrue(pane.selectedFiles.isEmpty)
        XCTAssertTrue(pane.selectedEntries.isEmpty)
        XCTAssertFalse(pane.canApplyTaskResult(in: ordinary))
        let viewer = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? GitHistoryView }.first)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository, Datei oder Verzeichnis", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let source = try control(NSSegmentedControl.self, label: "Git-Version, Arbeitskopie oder Staged-Diff", in: viewer)
        let content = try control(NSSegmentedControl.self, label: "Commit-Diff oder Datei dieser Version", in: viewer)
        let older = try control(NSButton.self, label: "Ältere Version", in: viewer)
        let newer = try control(NSButton.self, label: "Neuere Version", in: viewer)
        try eventually { text.string.contains("+two") && versions.numberOfItems == 2 }
        XCTAssertEqual(scope.indexOfSelectedItem, 1)
        let title = try control(NSTextField.self, label: "Git-Auswahl", in: viewer)
        XCTAssertEqual(title.stringValue, file.lastPathComponent)
        XCTAssertTrue(older.isEnabled)
        XCTAssertFalse(newer.isEnabled)

        choose(content, 1)
        try eventually { text.string == "two\n" }
        invoke(older)
        try eventually { text.string == "one\n" }
        XCTAssertFalse(older.isEnabled)
        XCTAssertTrue(newer.isEnabled)
        let selectedCommit = versions.titleOfSelectedItem
        viewer.refresh()
        try eventually { versions.isEnabled && text.string == "one\n" }
        XCTAssertEqual(versions.titleOfSelectedItem, selectedCommit)
        invoke(newer)
        try eventually { text.string == "two\n" }
        choose(content, 0)
        try eventually { text.string.contains("-one") && text.string.contains("+two") }

        choose(source, 1)
        try eventually { text.string.contains("-staged") && text.string.contains("+working") }
        XCTAssertFalse(versions.isEnabled)
        XCTAssertFalse(older.isEnabled)
        choose(source, 2)
        try eventually { text.string.contains("-two") && text.string.contains("+staged") }
        choose(source, 0)
        try eventually { showsCommit("Second version", in: viewer, text: text) && text.string.contains("+two") }

        let close = try XCTUnwrap(descendants(of: viewer).compactMap { $0 as? NSButton }.first { $0.title == "Dateiliste" })
        invoke(close)
        XCTAssertEqual(pane.mode, .listing)
        XCTAssertTrue(viewer.isHidden)
        XCTAssertEqual(pane.selectedFiles.map { $0.resolvingSymlinksInPath() },
            [ordinary.appendingPathComponent("own.txt").resolvingSymlinksInPath()])
        XCTAssertEqual(pane.directory, ordinary)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        let after = try gitRepository.snapshot()
        XCTAssertEqual(after.head, before.head)
        XCTAssertEqual(after.files, before.files)
        XCTAssertEqual(try String(contentsOf: file), "working\n")
    }

    func testOtherPaneSelectionDrivesFileDirectoryAndRepositoryHistory() throws {
        try git(["reset", "--hard", "HEAD"])
        let component = repository.appendingPathComponent("component", isDirectory: true)
        try FileManager.default.createDirectory(at: component, withIntermediateDirectories: false)
        let nested = component.appendingPathComponent("nested.txt")
        try Data("directory one\n".utf8).write(to: nested)
        try git(["add", "component"])
        try git(["commit", "-m", "Directory first"])
        try Data("unrelated sibling\n".utf8).write(to: repository.appendingPathComponent("sibling.txt"))
        try git(["add", "sibling.txt"])
        try git(["commit", "-m", "Sibling only"])
        try Data("directory two\n".utf8).write(to: nested)
        try git(["add", "component"])
        try git(["commit", "-m", "Directory second"])

        let commander = CommanderController()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = commander
        defer { window.close() }
        commander.left.navigate(to: ordinary)
        commander.right.navigate(to: repository)
        try eventually { commander.left.directory == self.ordinary && commander.right.directory == self.repository }
        try select("own.txt", in: commander.left)
        try loadAndSelectFile(in: commander.right)
        XCTAssertTrue(try XCTUnwrap(commander.commandRegistry["left.mode.5"]).perform())
        let viewer = try historyView(in: commander.left)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let older = try control(NSButton.self, label: "Ältere Version", in: viewer)
        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository, Datei oder Verzeichnis", in: viewer)
        let content = try control(NSSegmentedControl.self, label: "Commit-Diff oder Datei dieser Version", in: viewer)
        try eventually { text.string.contains("+two") && versions.numberOfItems == 2 }
        XCTAssertEqual(commander.left.directory, ordinary)
        XCTAssertEqual(commander.left.pathField.stringValue, commander.right.selectedFiles.first?.path)
        XCTAssertEqual(commander.right.mode, .listing)
        invoke(older)
        try eventually { showsCommit("First version", in: viewer, text: text) }
        let oldVersion = versions.titleOfSelectedItem
        commander.right.onSelectionChanged?(commander.right.selectedFiles.first)
        XCTAssertEqual(versions.titleOfSelectedItem, oldVersion)
        XCTAssertTrue(showsCommit("First version", in: viewer, text: text))
        commander.right.refresh()
        try eventually {
            commander.right.canApplyTaskResult(in: self.repository)
                && commander.right.selectedFiles.first?.lastPathComponent == self.file.lastPathComponent
        }
        XCTAssertEqual(versions.titleOfSelectedItem, oldVersion)
        XCTAssertTrue(showsCommit("First version", in: viewer, text: text))

        try select("component", in: commander.right)
        try eventually { showsCommit("Directory second", in: viewer, text: text) && versions.numberOfItems == 2 }
        XCTAssertTrue(scope.titleOfSelectedItem?.contains("Verzeichnis") == true)
        XCTAssertEqual(commander.left.pathField.stringValue, commander.right.selectedFiles.first?.path)
        XCTAssertFalse(content.isEnabled(forSegment: 1))
        XCTAssertFalse(versions.itemTitles.contains { $0.contains("Sibling only") })
        XCTAssertTrue(text.string.contains("+directory two"))
        XCTAssertFalse(text.string.contains("unrelated sibling"))
        invoke(older)
        try eventually { showsCommit("Directory first", in: viewer, text: text) && text.string.contains("+directory one") }

        // Selecting the parent entry falls back to the other pane's current repository.
        try select("..", in: commander.right)
        try eventually { versions.numberOfItems == 5 && showsCommit("Directory second", in: viewer, text: text) }
        XCTAssertEqual(scope.indexOfSelectedItem, 0)
        XCTAssertEqual(try control(NSTextField.self, label: "Git-Auswahl", in: viewer).stringValue,
            repository.lastPathComponent)
        XCTAssertEqual(commander.left.pathField.stringValue, commander.right.directory.path)

        let sourceMode = try control(NSSegmentedControl.self,
            label: "Git-Version, Arbeitskopie oder Staged-Diff", in: viewer)
        choose(sourceMode, 1)
        try Data("sibling working copy\n".utf8).write(to: repository.appendingPathComponent("sibling.txt"))
        try select("sibling.txt", in: commander.right)
        try eventually { text.string.contains("+sibling working copy") }
        XCTAssertEqual(sourceMode.selectedSegment, 1)
        XCTAssertTrue(versions.itemTitles.contains { $0.contains("Sibling only") })
        XCTAssertEqual(commander.left.pathField.stringValue, commander.right.selectedFiles.first?.path)
        try loadAndSelectFile(in: commander.right)
        try eventually { text.string.contains("Keine nicht vorgemerkten Änderungen") }
        XCTAssertEqual(sourceMode.selectedSegment, 1)
        choose(sourceMode, 0)
        try eventually { showsCommit("Second version", in: viewer, text: text) }

        // Navigation into a different repository replaces the captured root as well.
        let firstRepository = repository!
        let otherRepository = temporary.appendingPathComponent("another repository", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRepository, withIntermediateDirectories: false)
        repository = otherRepository
        try git(["init", "-b", "main"])
        try Data("another repository\n".utf8).write(to: otherRepository.appendingPathComponent("other.txt"))
        try git(["add", "."])
        try git(["commit", "-m", "Other repository version"])
        repository = firstRepository
        commander.right.navigate(to: otherRepository)
        try eventually { commander.right.directory == otherRepository && showsCommit("Other repository version", in: viewer, text: text) }
        XCTAssertEqual(versions.numberOfItems, 1)
        XCTAssertFalse(showsCommit("Directory second", in: viewer, text: text))

        commander.right.navigate(to: ordinary)
        try eventually { commander.right.directory == self.ordinary && text.string.contains("keinem Git-Repository") }
        XCTAssertEqual(versions.numberOfItems, 0)
        XCTAssertEqual(commander.left.pathField.stringValue, commander.right.directory.path)
        XCTAssertEqual(commander.left.mode, .gitHistory)
        XCTAssertTrue(try XCTUnwrap(commander.commandRegistry["left.mode.0"]).perform())
        XCTAssertEqual(commander.left.directory, ordinary)
        XCTAssertEqual(commander.left.selectedFiles.map { $0.resolvingSymlinksInPath() },
            [ordinary.appendingPathComponent("own.txt").resolvingSymlinksInPath()])
        XCTAssertFalse(window.isVisible)
    }

    func testReplacingAnOutstandingRepositoryReadWithAnOrdinaryDirectoryRejectsStaleResults() throws {
        let viewer = GitHistoryView(frame: .zero)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let source = try control(NSSegmentedControl.self, label: "Git-Version, Arbeitskopie oder Staged-Diff", in: viewer)
        viewer.open(directory: repository, selectedFile: file)
        viewer.stop()
        viewer.open(directory: ordinary, selectedFile: nil)
        try eventually { text.string.contains("keinem Git-Repository") }
        XCTAssertEqual(versions.numberOfItems, 0)
        XCTAssertFalse(source.isEnabled)
        XCTAssertFalse(versions.isEnabled)
        viewer.refresh()
        try eventually { text.string.contains("keinem Git-Repository") }

        viewer.open(directory: repository, selectedFile: nil)
        try eventually { showsCommit("Second version", in: viewer, text: text) && versions.numberOfItems == 2 }
        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository, Datei oder Verzeichnis", in: viewer)
        XCTAssertEqual(scope.indexOfSelectedItem, 0)
        XCTAssertFalse(scope.isEnabled)
    }

    func testUnavailableOtherPaneClearsThePreviousRepositoryImmediately() throws {
        let viewer = GitHistoryView(frame: .zero)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let source = try control(NSSegmentedControl.self, label: "Git-Version, Arbeitskopie oder Staged-Diff", in: viewer)
        viewer.follow(directory: repository, selection: file, isDirectory: false)
        try eventually { showsCommit("Second version", in: viewer, text: text) }
        viewer.follow(directory: nil, selection: nil, isDirectory: false)
        XCTAssertTrue(text.string.contains("Im anderen Panel"))
        XCTAssertEqual(versions.numberOfItems, 0)
        XCTAssertFalse(source.isEnabled)
        viewer.refresh()
        XCTAssertTrue(text.string.contains("Im anderen Panel"))
        viewer.follow(directory: repository, selection: file, isDirectory: false)
        try eventually { showsCommit("Second version", in: viewer, text: text) && versions.numberOfItems == 2 }
    }

    func testOpeningHistoryDuringOtherPaneNavigationFollowsTheCompletedDirectory() throws {
        let source = PaneController(label: "Files", directory: repository)
        let pane = PaneController(label: "History", directory: ordinary)
        try loadAndSelectFile(in: source)
        _ = pane.view
        connect(pane, to: source)
        source.navigate(to: ordinary)
        pane.setMode(.gitHistory)
        let viewer = try historyView(in: pane)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        try eventually { source.directory == self.ordinary && text.string.contains("keinem Git-Repository") }
        XCTAssertEqual(pane.mode, .gitHistory)
        XCTAssertEqual(pane.directory, ordinary)
        XCTAssertEqual(pane.pathField.stringValue, source.directory.path)
    }

    func testShortViewerKeepsAllControlsReachableByScrolling() throws {
        let viewer = GitHistoryView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        let window = NSWindow(contentRect: viewer.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewer
        defer { window.close() }
        viewer.open(directory: repository, selectedFile: file)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        try eventually { versions.isEnabled }
        viewer.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(viewer.subviews.first as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height)
        XCTAssertEqual(document.bounds.width, scroll.contentSize.width, accuracy: 1)
        let close = try XCTUnwrap(descendants(of: viewer).compactMap { $0 as? NSButton }.first { $0.title == "Dateiliste" })
        document.scrollToVisible(close.convert(close.bounds, to: document))
        XCTAssertTrue(scroll.contentView.documentVisibleRect.contains(close.convert(close.bounds, to: document)))
        XCTAssertFalse(window.isVisible)
    }

    func testStructuredCommitHeaderAndAppearanceChangesKeepThePatchReadable() throws {
        let viewer = GitHistoryView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        let window = NSWindow(contentRect: viewer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = viewer
        defer { window.close() }
        viewer.open(directory: repository, selectedFile: file)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let title = try control(NSTextField.self, label: "Git-Auswahl", in: viewer)
        let subtitle = try control(NSTextField.self, label: "Git-Quelle", in: viewer)
        let details = try control(NSTextField.self, label: "Ausgewählte Git-Version", in: viewer)
        try eventually { showsCommit("Second version", in: viewer, text: text) }
        XCTAssertEqual(title.stringValue, file.lastPathComponent)
        XCTAssertTrue(subtitle.stringValue.contains(repository.lastPathComponent))
        XCTAssertTrue(details.stringValue.contains("PaneRook Tests"))
        let entry = try XCTUnwrap(GitRepository(directory: repository).historyEntries(path: file.lastPathComponent).first)
        XCTAssertTrue(details.stringValue.contains(entry.commit.shortID))
        XCTAssertFalse(text.string.contains("AuthorDate:"))
        XCTAssertFalse(text.string.contains("PaneRook Tests"))
        XCTAssertFalse(versions.titleOfSelectedItem?.contains("PaneRook Tests") == true)
        XCTAssertFalse(text.isEditable)

        let patch = text.string
        let selectedVersion = versions.titleOfSelectedItem
        let oldTheme = ThemeManager.theme
        let oldScheme = ThemeManager.colorScheme
        let suite = "PaneRookGitDesign-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.set(oldTheme.rawValue, forKey: "appTheme")
            defaults.set(oldScheme.rawValue, forKey: "appearance")
            ThemeManager.apply(defaults: defaults)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(AppTheme.iris.rawValue, forKey: "appTheme")
        for (name, scheme) in [("light", AppColorScheme.light), ("dark", .dark)] {
            defaults.set(scheme.rawValue, forKey: "appearance")
            ThemeManager.apply(defaults: defaults)
            viewer.layoutSubtreeIfNeeded()
            viewer.displayIfNeeded()
            XCTAssertEqual(text.string, patch)
            XCTAssertEqual(versions.titleOfSelectedItem, selectedVersion)
            XCTAssertTrue(showsCommit("Second version", in: viewer, text: text))
            if let directory = ProcessInfo.processInfo.environment["PANEROOK_GIT_DESIGN_SNAPSHOT_DIR"] {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(viewer.bitmapImageRepForCachingDisplay(in: viewer.bounds))
                viewer.cacheDisplay(in: viewer.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: destination.appendingPathComponent("git-pane-\(name).png"))
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    func testHistoricalFileContentThatResemblesAPatchIsPreservedVerbatim() throws {
        try git(["reset", "--hard", "HEAD"])
        let content = "commit literal source text\nAuthor: literal\n\ndiff --git this is actual file content\n+keep this\n"
        try Data(content.utf8).write(to: file)
        try git(["add", "--", file.lastPathComponent])
        try git(["commit", "-m", "Patch-like source content"])
        let viewer = GitHistoryView(frame: .zero)
        viewer.open(directory: repository, selectedFile: file)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let contentMode = try control(NSSegmentedControl.self, label: "Commit-Diff oder Datei dieser Version", in: viewer)
        try eventually { showsCommit("Patch-like source content", in: viewer, text: text) }
        choose(contentMode, 1)
        try eventually { text.string == content }
    }
}

extension GitHistoryPaneTests {
    func testViewerKeepsNavigationAndDiffUsableAtMinimumAndWiderPaneSizes() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewer = GitHistoryView(frame: NSRect(x: 0, y: 0, width: 450, height: 500))
        window.contentView = viewer
        viewer.open(directory: repository, selectedFile: file)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        try eventually { showsCommit("Second version", in: viewer, text: text) }
        let diff = try XCTUnwrap(descendants(of: viewer).compactMap { $0 as? GitDiffView }.first)
        let controls = descendants(of: viewer).compactMap { $0 as? NSControl }.filter {
            ($0 is NSButton || $0 is NSSegmentedControl) && !($0 is NSPopUpButton)
        }
        let popups = descendants(of: viewer).compactMap { $0 as? NSPopUpButton }
        for size in [NSSize(width: 320, height: 400), NSSize(width: 450, height: 500), NSSize(width: 700, height: 700)] {
            window.setContentSize(size)
            viewer.layoutSubtreeIfNeeded()
            let description = "at \(Int(size.width)) × \(Int(size.height))"
            let scroll = try XCTUnwrap(viewer.subviews.first as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertGreaterThanOrEqual(diff.bounds.height, 150, description)
            XCTAssertEqual(diff.bounds.width, viewer.bounds.width - 24, accuracy: 1, description)
            for item in controls + popups {
                guard !item.isHiddenOrHasHiddenAncestor else { continue }
                let frame = item.convert(item.bounds, to: document)
                XCTAssertGreaterThanOrEqual(frame.minX, -1, description + ": " + (item.accessibilityLabel() ?? "control"))
                XCTAssertLessThanOrEqual(frame.maxX, document.bounds.maxX + 1, description + ": " + (item.accessibilityLabel() ?? "control"))
                XCTAssertGreaterThanOrEqual(frame.minY, -1, description)
                XCTAssertLessThanOrEqual(frame.maxY, document.bounds.maxY + 1, description)
                if item is NSSegmentedControl || (item as? NSButton)?.title == "Dateiliste" {
                    XCTAssertGreaterThanOrEqual(item.bounds.width + 1, item.fittingSize.width,
                        description + ": " + (item.accessibilityLabel() ?? "Dateiliste"))
                }
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    private final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    func testPanelModeCommandUsesItsPaneAndDisablesFileActionsDuringHistory() throws {
        let commander = CommanderController()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = commander
        defer { window.close() }
        commander.left.navigate(to: ordinary)
        commander.right.navigate(to: repository)
        try eventually { commander.left.directory == self.ordinary && commander.right.directory == self.repository }
        try select("own.txt", in: commander.left)
        try loadAndSelectFile(in: commander.right)
        commander.activate(commander.left)
        let registry = commander.commandRegistry
        let history = try XCTUnwrap(registry["left.mode.5"])
        let rightHistory = try XCTUnwrap(registry["right.mode.5"])
        let listing = try XCTUnwrap(registry["left.mode.0"])
        XCTAssertTrue(history.enabled())
        XCTAssertTrue(rightHistory.enabled())
        XCTAssertTrue(try XCTUnwrap(registry["copy"]).enabled())
        XCTAssertTrue(try XCTUnwrap(registry["trash"]).enabled())
        XCTAssertTrue(history.perform())
        XCTAssertEqual(commander.left.mode, .gitHistory)
        XCTAssertEqual(commander.right.mode, .listing)
        XCTAssertTrue(history.checked())
        XCTAssertFalse(rightHistory.checked())
        XCTAssertFalse(commander.canUseSelection)
        XCTAssertFalse(commander.canUseLocalDirectory)
        for id in ["copy", "move", "trash", "files.rename", "mkdir"] {
            XCTAssertFalse(try XCTUnwrap(registry[id]).enabled(), id)
        }
        XCTAssertTrue(listing.perform())
        XCTAssertEqual(commander.left.mode, .listing)
        XCTAssertEqual(commander.left.selectedFiles.map { $0.resolvingSymlinksInPath() },
            [ordinary.appendingPathComponent("own.txt").resolvingSymlinksInPath()])
        XCTAssertTrue(try XCTUnwrap(registry["copy"]).enabled())
        XCTAssertTrue(try XCTUnwrap(registry["trash"]).enabled())
        XCTAssertFalse(window.isVisible)
    }
}
