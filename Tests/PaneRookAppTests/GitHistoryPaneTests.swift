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

    private func invoke(_ control: NSControl) {
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
    }

    private func choose(_ control: NSSegmentedControl, _ index: Int) {
        control.selectedSegment = index
        invoke(control)
    }

    private func loadAndSelectFile(in pane: PaneController) throws {
        _ = pane.view
        try eventually { pane.entries.contains { $0.name == self.file.lastPathComponent } }
        let row = try XCTUnwrap(pane.entries.firstIndex { $0.name == file.lastPathComponent })
        pane.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(pane.selectedFiles.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
    }
}

extension GitHistoryPaneTests {
    func testPaneShowsFileVersionsAndWorkingStagedDiffsWithoutChangingGit() throws {
        let gitRepository = try GitRepository(directory: repository)
        let before = try gitRepository.snapshot()
        let pane = PaneController(label: "History", directory: repository)
        try loadAndSelectFile(in: pane)
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        pane.setMode(.gitHistory)
        XCTAssertEqual(pane.mode, .gitHistory)
        XCTAssertTrue(pane.selectedFiles.isEmpty)
        XCTAssertTrue(pane.selectedEntries.isEmpty)
        XCTAssertFalse(pane.canApplyTaskResult(in: repository))
        let viewer = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? GitHistoryView }.first)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository oder Datei", in: viewer)
        let versions = try control(NSPopUpButton.self, label: "Git-Version auswählen", in: viewer)
        let source = try control(NSSegmentedControl.self, label: "Git-Version, Arbeitskopie oder Staged-Diff", in: viewer)
        let content = try control(NSSegmentedControl.self, label: "Commit-Diff oder Datei dieser Version", in: viewer)
        let older = try control(NSButton.self, label: "Ältere Version", in: viewer)
        let newer = try control(NSButton.self, label: "Neuere Version", in: viewer)
        try eventually { text.string.contains("+two") && versions.numberOfItems == 2 }
        XCTAssertEqual(scope.indexOfSelectedItem, 1)
        XCTAssertTrue(scope.titleOfSelectedItem?.contains(file.lastPathComponent) == true)
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
        try eventually { text.string.contains("Second version") && text.string.contains("+two") }

        let close = try XCTUnwrap(descendants(of: viewer).compactMap { $0 as? NSButton }.first { $0.title == "Dateiliste" })
        invoke(close)
        XCTAssertEqual(pane.mode, .listing)
        XCTAssertTrue(viewer.isHidden)
        XCTAssertEqual(pane.selectedFiles.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
        let after = try gitRepository.snapshot()
        XCTAssertEqual(after.head, before.head)
        XCTAssertEqual(after.files, before.files)
        XCTAssertEqual(try String(contentsOf: file), "working\n")
    }

    func testTwoPanesKeepIndependentVersionSelectionsAndRepositoryScope() throws {
        let left = PaneController(label: "Left", directory: repository)
        let right = PaneController(label: "Right", directory: repository)
        try loadAndSelectFile(in: left)
        try loadAndSelectFile(in: right)
        left.setMode(.gitHistory)
        right.setMode(.gitHistory)
        func viewer(in pane: PaneController) throws -> GitHistoryView {
            try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? GitHistoryView }.first)
        }
        let leftView = try viewer(in: left)
        let rightView = try viewer(in: right)
        let leftText = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: leftView)
        let rightText = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: rightView)
        let older = try control(NSButton.self, label: "Ältere Version", in: leftView)
        try eventually { leftText.string.contains("Second version") && rightText.string.contains("Second version") }
        invoke(older)
        try eventually { leftText.string.contains("First version") }
        XCTAssertTrue(rightText.string.contains("Second version"))

        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository oder Datei", in: leftView)
        scope.selectItem(at: 0)
        invoke(scope)
        try eventually { leftText.string.contains("Second version") }
        let content = try control(NSSegmentedControl.self, label: "Commit-Diff oder Datei dieser Version", in: leftView)
        XCTAssertFalse(content.isEnabled(forSegment: 1))
        XCTAssertTrue(rightText.string.contains("Second version"))
        right.setMode(.listing)
        XCTAssertFalse(leftView.isHidden)
        XCTAssertEqual(left.mode, .gitHistory)
        XCTAssertEqual(right.selectedFiles.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
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
        try eventually { text.string.contains("Second version") && versions.numberOfItems == 2 }
        let scope = try control(NSPopUpButton.self, label: "Git-Verlauf: Repository oder Datei", in: viewer)
        XCTAssertEqual(scope.indexOfSelectedItem, 0)
        XCTAssertFalse(scope.isEnabled)
    }

    func testOpeningHistoryDuringNavigationFollowsTheCompletedDirectory() throws {
        let pane = PaneController(label: "History", directory: repository)
        try loadAndSelectFile(in: pane)
        pane.navigate(to: ordinary)
        pane.setMode(.gitHistory)
        let viewer = try XCTUnwrap(descendants(of: pane.view).compactMap { $0 as? GitHistoryView }.first)
        let text = try control(NSTextView.self, label: "Git-Diff und Versionsvorschau", in: viewer)
        try eventually { pane.directory == self.ordinary && text.string.contains("keinem Git-Repository") }
        XCTAssertEqual(pane.mode, .gitHistory)
        XCTAssertEqual(pane.pathField.stringValue, ordinary.path)
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
        try eventually { text.string.contains("Second version") }
        let diff = try XCTUnwrap(descendants(of: viewer).compactMap { $0 as? GitDiffView }.first)
        let controls = descendants(of: viewer).compactMap { $0 as? NSControl }.filter {
            ($0 is NSButton || $0 is NSSegmentedControl) && !($0 is NSPopUpButton)
        }
        let popups = descendants(of: viewer).compactMap { $0 as? NSPopUpButton }
        for size in [NSSize(width: 320, height: 400), NSSize(width: 450, height: 500), NSSize(width: 700, height: 700)] {
            window.setContentSize(size)
            viewer.layoutSubtreeIfNeeded()
            let description = "at \(Int(size.width)) × \(Int(size.height))"
            XCTAssertGreaterThanOrEqual(diff.bounds.height, 150, description)
            XCTAssertEqual(diff.bounds.width, viewer.bounds.width - 16, accuracy: 1, description)
            for item in controls + popups {
                guard !item.isHiddenOrHasHiddenAncestor else { continue }
                let frame = item.convert(item.bounds, to: viewer)
                XCTAssertGreaterThanOrEqual(frame.minX, -1, description + ": " + (item.accessibilityLabel() ?? "control"))
                XCTAssertLessThanOrEqual(frame.maxX, viewer.bounds.maxX + 1, description + ": " + (item.accessibilityLabel() ?? "control"))
                XCTAssertGreaterThanOrEqual(frame.minY, -1, description)
                XCTAssertLessThanOrEqual(frame.maxY, viewer.bounds.maxY + 1, description)
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
        commander.left.navigate(to: repository)
        commander.right.navigate(to: ordinary)
        try eventually { commander.left.directory == self.repository && commander.right.directory == self.ordinary }
        try loadAndSelectFile(in: commander.left)
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
        XCTAssertEqual(commander.left.selectedFiles.map { $0.resolvingSymlinksInPath() }, [file.resolvingSymlinksInPath()])
        XCTAssertTrue(try XCTUnwrap(registry["copy"]).enabled())
        XCTAssertTrue(try XCTUnwrap(registry["trash"]).enabled())
        XCTAssertFalse(window.isVisible)
    }
}
