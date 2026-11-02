import AppKit
import XCTest

@testable import PaneRookApp

final class GitDiffViewTests: XCTestCase {
    private let patch = """
    diff --git a/file.swift b/file.swift
    --- a/file.swift
    +++ b/file.swift
    @@ -1,3 +1,4 @@
     unchanged
    -let old = "ä";
    +let new = "😀";
    +extra
     end
    """

    override func setUp() { _ = NSApplication.shared }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func control(in view: GitDiffView) throws -> NSSegmentedControl {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Diff-Darstellung" })
    }

    private func tables(in view: GitDiffView) throws -> (NSTableView, NSTableView) {
        let tables = descendants(of: view).compactMap { $0 as? NSTableView }
        return (try XCTUnwrap(tables.first { $0.accessibilityLabel() == "Git-Diff: Vorher" }),
                try XCTUnwrap(tables.first { $0.accessibilityLabel() == "Git-Diff: Nachher" }))
    }

    private func isVisible(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let item = current {
            if item.isHidden { return false }
            current = item.superview
        }
        return true
    }

    func testSwitchingPresentationUsesSameDocumentAndAlignedLineNumbers() throws {
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        let document = GitDiffDocument(patch: patch)
        view.show(document)
        view.layoutSubtreeIfNeeded()
        let unified = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        let selector = try control(in: view)
        let (left, right) = try tables(in: view)
        XCTAssertEqual(selector.label(forSegment: 0), "Unified Diff")
        XCTAssertEqual(selector.label(forSegment: 1), "Side-by-Side Diff")
        XCTAssertEqual(unified.string, patch)
        XCTAssertFalse(unified.isEditable)
        XCTAssertTrue(unified.isSelectable)
        XCTAssertTrue(isVisible(unified))
        XCTAssertFalse(isVisible(left))

        selector.selectedSegment = 1
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(isVisible(unified))
        XCTAssertTrue(isVisible(left))
        XCTAssertTrue(isVisible(right))
        XCTAssertEqual(left.numberOfRows, document.rows.count)
        XCTAssertEqual(right.numberOfRows, document.rows.count)
        let change = try XCTUnwrap(document.rows.firstIndex { $0.kind == .change })
        let oldCode = left.delegate?.tableView?(left, viewFor: left.tableColumns[1], row: change) as? NSTextField
        let newCode = right.delegate?.tableView?(right, viewFor: right.tableColumns[1], row: change) as? NSTextField
        XCTAssertEqual(oldCode?.stringValue, "let old = \"ä\";")
        XCTAssertEqual(newCode?.stringValue, "let new = \"😀\";")
        let oldNumber = left.delegate?.tableView?(left, viewFor: left.tableColumns[0], row: change) as? NSTextField
        let newNumber = right.delegate?.tableView?(right, viewFor: right.tableColumns[0], row: change) as? NSTextField
        XCTAssertEqual(oldNumber?.stringValue, "2")
        XCTAssertEqual(newNumber?.stringValue, "2")
        left.selectRowIndexes(IndexSet(integer: change), byExtendingSelection: false)
        XCTAssertEqual(right.selectedRowIndexes, left.selectedRowIndexes)

        selector.selectedSegment = 0
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        XCTAssertTrue(isVisible(unified))
        XCTAssertEqual(unified.string, patch)
    }

    func testSideBySideFillsAvailableSpaceWithEqualPanesWhenResized() throws {
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        view.show(GitDiffDocument(patch: patch))
        let selector = try control(in: view)
        selector.selectedSegment = 1
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        let (left, right) = try tables(in: view)
        let leftScroll = try XCTUnwrap(left.enclosingScrollView)
        let rightScroll = try XCTUnwrap(right.enclosingScrollView)
        for size in [NSSize(width: 1000, height: 500), NSSize(width: 600, height: 140), NSSize(width: 1400, height: 800)] {
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            let first = leftScroll.convert(leftScroll.bounds, to: view)
            let second = rightScroll.convert(rightScroll.bounds, to: view)
            XCTAssertEqual(first.width, second.width, accuracy: 1)
            XCTAssertEqual(first.minX, 0, accuracy: 1)
            XCTAssertEqual(second.maxX, size.width, accuracy: 1)
            XCTAssertEqual(first.minY, 0, accuracy: 1)
            XCTAssertEqual(second.minY, 0, accuracy: 1)
            XCTAssertEqual(first.maxY, second.maxY, accuracy: 1)
            XCTAssertGreaterThan(first.height, size.height - 40)
        }
    }

    func testVerticalScrollingIsSharedAndHorizontalPositionsStayIndependent() throws {
        let old = String(repeating: "old", count: 300)
        let new = String(repeating: "new", count: 300)
        let context = (1...300).map { " unchanged \($0)" }.joined(separator: "\n")
        let text = "--- a/file\n+++ b/file\n@@ -1,301 +1,301 @@\n-\(old)\n+\(new)\n\(context)\n"
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        view.show(GitDiffDocument(patch: text))
        let selector = try control(in: view)
        selector.selectedSegment = 1
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        view.layoutSubtreeIfNeeded()
        let (left, right) = try tables(in: view)
        let first = try XCTUnwrap(left.enclosingScrollView)
        let second = try XCTUnwrap(right.enclosingScrollView)
        second.contentView.scroll(to: NSPoint(x: 120, y: 0))
        second.reflectScrolledClipView(second.contentView)
        first.contentView.scroll(to: NSPoint(x: 40, y: 450))
        first.reflectScrolledClipView(first.contentView)
        XCTAssertEqual(second.contentView.bounds.origin.y, first.contentView.bounds.origin.y, accuracy: 1)
        XCTAssertEqual(first.contentView.bounds.origin.x, 40, accuracy: 1)
        XCTAssertEqual(second.contentView.bounds.origin.x, 120, accuracy: 1)
    }

    func testNewDocumentAndMessagesReplaceBothPresentationsWithoutResettingChoice() throws {
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        view.show(GitDiffDocument(patch: patch))
        let selector = try control(in: view)
        selector.selectedSegment = 1
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        view.showMessage("Keine Auswahl.")
        let unified = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        let (left, right) = try tables(in: view)
        XCTAssertEqual(selector.selectedSegment, 1)
        XCTAssertEqual(unified.string, "Keine Auswahl.")
        XCTAssertEqual(left.numberOfRows, 1)
        XCTAssertEqual(right.numberOfRows, 1)
        let message = right.delegate?.tableView?(right, viewFor: right.tableColumns[1], row: 0) as? NSTextField
        XCTAssertEqual(message?.stringValue, "Keine Auswahl.")
    }

    func testWideUnicodeLinesRemainReachableByHorizontalScrolling() throws {
        let old = String(repeating: "界", count: 300)
        let new = String(repeating: "語", count: 300)
        let document = GitDiffDocument(patch: "@@ -1 +1 @@\n-\(old)\n+\(new)\n")
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        view.show(document)
        let selector = try control(in: view)
        selector.selectedSegment = 1
        XCTAssertTrue(selector.sendAction(selector.action, to: selector.target))
        view.layoutSubtreeIfNeeded()
        let (left, right) = try tables(in: view)
        let row = try XCTUnwrap(document.rows.firstIndex { $0.kind == .change })
        for (table, text) in [(left, old), (right, new)] {
            let label = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: table.tableColumns[1], row: row) as? NSTextField)
            let font = try XCTUnwrap(label.font)
            let renderedWidth = (text as NSString).size(withAttributes: [.font: font]).width
            XCTAssertGreaterThanOrEqual(table.tableColumns[1].width, ceil(renderedWidth) + 16)
            XCTAssertGreaterThan(table.frame.width, try XCTUnwrap(table.enclosingScrollView).contentSize.width)
        }
    }

    func testPaneStyleUpdatesRenderedThemeAndAppearanceWithoutLosingSelectionOrContent() throws {
        let suite = "PaneRook.DiffPaneThemeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previousAppearance = NSApplication.shared.appearance
        defer {
            defaults.removePersistentDomain(forName: suite)
            ThemeManager.apply()
            NSApplication.shared.appearance = previousAppearance
        }
        defaults.set("ocean", forKey: "appTheme")
        defaults.set(1, forKey: "appearance")
        ThemeManager.apply(defaults: defaults)
        let view = GitDiffView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        view.appearance = NSAppearance(named: .aqua)
        view.usePaneStyle()
        let document = GitDiffDocument(patch: patch)
        view.show(document)
        view.layoutSubtreeIfNeeded()
        let unified = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextView }.first)
        let selector = try control(in: view)
        XCTAssertGreaterThanOrEqual(view.bounds.width, selector.frame.maxX)
        XCTAssertFalse(unified.isEditable)
        unified.setSelectedRange(NSRange(location: 2, length: 7))
        let (left, right) = try tables(in: view)
        let row = try XCTUnwrap(document.rows.firstIndex { $0.kind == .change })
        view.setPresentation(1)
        left.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let hunk = (patch as NSString).range(of: "@@").location
        XCTAssertNotEqual(hunk, NSNotFound)
        func hunkColor() throws -> CGColor {
            let color = try XCTUnwrap(unified.textStorage?.attribute(.foregroundColor, at: hunk,
                effectiveRange: nil) as? NSColor)
            var result: CGColor?
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB)?.cgColor
            }
            return try XCTUnwrap(result)
        }
        let firstHunkColor = try hunkColor()
        defaults.set("iris", forKey: "appTheme")
        ThemeManager.apply(defaults: defaults)
        XCTAssertNotEqual(try hunkColor(), firstHunkColor)
        XCTAssertEqual(unified.string, patch)
        XCTAssertEqual(unified.selectedRange(), NSRange(location: 2, length: 7))
        XCTAssertEqual(left.selectedRowIndexes, IndexSet(integer: row))
        XCTAssertEqual(right.selectedRowIndexes, left.selectedRowIndexes)
        XCTAssertEqual(selector.selectedSegment, 1)
        let lightBackground = try XCTUnwrap(view.layer?.backgroundColor)
        view.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(view.layer?.backgroundColor, lightBackground)
        XCTAssertEqual(unified.string, patch)
        XCTAssertEqual(left.numberOfRows, document.rows.count)
        XCTAssertEqual(selector.selectedSegment, 1)
    }
}
