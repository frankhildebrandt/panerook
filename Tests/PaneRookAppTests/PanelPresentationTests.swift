import AppKit
import PaneRookPanels
import XCTest
@testable import PaneRookApp

final class PanelPresentationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testInspectionAndHistoryTabsNameTheirDisplayedContentAndRestoreFolderIdentity() throws {
        let folder = directory.appendingPathComponent("Ablage")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("README.md")
        try Data("Test".utf8).write(to: file)
        let source = PaneController(label: "Links", directory: directory)
        let viewer = PaneController(label: "Rechts", directory: folder)
        let group = PanelTabGroupController(panes: [viewer])
        _ = source.view; _ = group.view
        eventually { source.entries.contains { $0.name == file.lastPathComponent } }
        source.selectMatching("README.md", select: true)
        viewer.showInspection(of: file)
        viewer.setMode(.quickView)
        XCTAssertEqual(viewer.tabTitle, "Vorschau · README.md")
        XCTAssertEqual(viewer.tabLocationDescription, file.path)
        XCTAssertEqual(viewer.panelContextDescription, "README.md · folgt links")
        let header = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Panelinhalt und Herkunft" })
        XCTAssertEqual(header.stringValue, viewer.panelContextDescription)
        viewer.setMode(.info)
        XCTAssertEqual(viewer.tabTitle, "Info · README.md")
        viewer.setMode(.gitHistory)
        viewer.showGitHistory(from: source)
        XCTAssertEqual(viewer.tabTitle, "Verlauf · README.md")
        XCTAssertEqual(header.stringValue, "README.md · folgt links")
        let back = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Zur Dateiliste" })
        XCTAssertFalse(back.isHidden)
        back.performClick(nil)
        XCTAssertEqual(viewer.mode, .listing)
        XCTAssertEqual(viewer.tabTitle, "Ablage")
        XCTAssertEqual(viewer.directory, folder)
        XCTAssertTrue(back.isHidden)
    }

    func testTabCloseTargetsItsOwnPaneAndLastTabHasNoEnabledCloseAction() throws {
        let first = PaneController(label: "Links", directory: directory)
        let second = PaneController(label: "Links", directory: directory.appendingPathComponent("second"))
        try FileManager.default.createDirectory(at: second.directory, withIntermediateDirectories: true)
        let group = PanelTabGroupController(panes: [first, second], selected: second)
        _ = group.view
        var requested: PaneController?
        group.onClose = { requested = group.selected; _ = group.removeSelected() }
        let close = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Tab schließen: " + first.tabTitle })
        close.performClick(nil)
        XCTAssertTrue(requested === first)
        XCTAssertEqual(group.panes.count, 1)
        XCTAssertTrue(group.selected === second)
        let remainingClose = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel()?.hasPrefix("Tab schließen: ") == true })
        XCTAssertFalse(remainingClose.isEnabled)
    }

    func testKeyboardCyclingRevealsActiveTabAndOverflowCanSelectHiddenTabs() throws {
        let panes = try (1...8).map { index in
            let folder = directory.appendingPathComponent("Ordner-\(index)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return PaneController(label: "Links", directory: folder)
        }
        let group = PanelTabGroupController(panes: panes)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = group
        window.setContentSize(NSSize(width: 360, height: 400))
        defer { window.close() }
        group.view.layoutSubtreeIfNeeded()
        group.cycle(-1)
        group.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.selected === panes.last)
        let scroll = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSScrollView }
            .first { $0.documentView?.accessibilityLabel() == "Panel-Tabs" })
        let document = try XCTUnwrap(scroll.documentView)
        let activeTab = try XCTUnwrap(document.subviews.last)
        eventually {
            group.view.layoutSubtreeIfNeeded()
            return scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(activeTab.frame)
        }
        let overflow = try XCTUnwrap(descendants(group.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Alle Tabs" })
        let first = try XCTUnwrap(overflow.menu?.items.dropFirst().first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(first.action), to: first.target, from: first))
        group.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(group.selected === panes.first)
        XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(try XCTUnwrap(document.subviews.first).frame),
                      "Visible: \(scroll.documentVisibleRect); first tab: \(document.subviews.first!.frame)")
    }
}
