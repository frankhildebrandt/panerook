import AppKit
import PaneRookCore
import XCTest
@testable import PaneRookApp

final class BatchRenameIntegrationTests: XCTestCase {
    private final class Host: FileOperationsHost {
        var activePane: any PanelAccess
        let otherPane: any PanelAccess
        let presentationWindow: NSWindow?
        var canUseMenus = true
        var canUseSelection: Bool { !activePane.selectedFiles.isEmpty }
        var canUseLocalDirectory: Bool { activePane.remoteContent == nil }
        var canUseNativeDirectory: Bool { canUseLocalDirectory && !activePane.isArchiveDirectory }
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        lazy var operations = OperationRunner(tasks: tasks, refresh: {})
        init(pane: any PanelAccess, window: NSWindow) { activePane = pane; otherPane = pane; presentationWindow = window }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func refreshAfterTask() {}
    }
    private func eventually(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, file: file, line: line)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    func testPresetsRoundTripReplaceRemoveAndKeepOtherSettings() throws {
        let suite = "BatchRename-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BatchRenamePresets(defaults: defaults)
        defaults.set("existing", forKey: "keyBindings")
        var rules = BatchRenameRules(); rules.prefix = "{n}_"; rules.numberStep = -1
        try store.save(name: "  Fotos  ", rules: rules); try store.remember(rules)
        let reloaded = BatchRenamePresets(defaults: defaults)
        XCTAssertEqual(reloaded.presets, [.init(name: "Fotos", rules: rules)])
        XCTAssertEqual(reloaded.lastRules, rules)
        rules.suffix = "_neu"; try reloaded.save(name: "Fotos", rules: rules)
        XCTAssertEqual(reloaded.presets.count, 1); XCTAssertEqual(reloaded.presets[0].rules, rules)
        XCTAssertThrowsError(try store.save(name: " ", rules: rules))
        try reloaded.remove(name: "Fotos"); XCTAssertTrue(store.presets.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "keyBindings"), "existing")
    }

    @MainActor func testLivePreviewInvalidationAndNoFilesystemMutation() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchRenameUI-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = ["A.txt", "B.txt"].map { root.appendingPathComponent($0) }
        for url in urls { try Data(url.lastPathComponent.utf8).write(to: url) }
        let suite = "BatchRenameUI-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dialog = BatchRenameDialog(sources: urls, store: BatchRenamePresets(defaults: defaults)) { _ in XCTFail("Preview must not submit") }
        defer { dialog.close() }
        var rules = BatchRenameRules(); rules.prefix = "{n}_"; rules.numberDigits = 2
        dialog.setRules(rules)
        eventually { !dialog.isPreviewPending }
        XCTAssertEqual(dialog.previewNames, ["01_A.txt", "02_B.txt"])
        XCTAssertEqual(dialog.previewPlan?.changedItems.count, 2)
        let content = try XCTUnwrap(dialog.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.tableColumns.map(\.title), ["Alter Name", "Neuer Name", "Status"])
        XCTAssertGreaterThan(table.enclosingScrollView?.frame.height ?? 0, 190)
        let submit = try XCTUnwrap(ContextCommands.button(in: content, id: "dialog.accept"))
        XCTAssertTrue(submit.isEnabled)
        rules.search = "["; rules.regularExpression = true
        dialog.setRules(rules)
        XCTAssertFalse(submit.isEnabled)
        eventually { !dialog.isPreviewPending }
        XCTAssertNil(dialog.previewPlan)
        // Fast edits must not allow an obsolete successful preview to enable execution.
        rules.search = "A"; dialog.setRules(rules)
        rules.search = ".*"; rules.replacement = "same"; rules.prefix = ""
        dialog.setRules(rules)
        eventually { !dialog.isPreviewPending }
        XCTAssertNil(dialog.previewPlan); XCTAssertFalse(submit.isEnabled)
        rules = .init(); rules.suffix = "_neu"; dialog.setRules(rules)
        eventually { !dialog.isPreviewPending }
        XCTAssertEqual(dialog.previewNames, ["A_neu.txt", "B_neu.txt"])
        let numeric = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Nummerierung: Stellen" })
        numeric.stringValue = "keine Zahl"
        dialog.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: numeric))
        XCTAssertNil(dialog.previewPlan); XCTAssertFalse(submit.isEnabled)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["A.txt", "B.txt"])
    }

    @MainActor func testExistingRenameCommandRoutesMultipleLocalEntriesToBatchDialog() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchRenameRoute-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let pane = PaneController(label: "Test", directory: root)
        _ = pane.view
        eventually { pane.entries.filter { !$0.isParent }.count == 2 }
        pane.table.selectRowIndexes(IndexSet(pane.entries.indices.filter { !pane.entries[$0].isParent }), byExtendingSelection: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = Host(pane: pane, window: window)
        let feature = FileOperations(owner: host)
        let registry = CommandRegistry(); feature.registerCommands(in: registry)
        XCTAssertTrue(feature.canRenameSelection); XCTAssertTrue(feature.canBatchRenameSelection)
        XCTAssertTrue(try XCTUnwrap(registry["files.rename"]).perform())
        let dialog = try XCTUnwrap(feature.batchRenameDialog)
        XCTAssertEqual(dialog.window?.title, "Mehrfachumbenennen")
        XCTAssertTrue(dialog.window?.sheetParent === window)
        let cancel = try XCTUnwrap(ContextCommands.button(in: dialog.window?.contentView, id: "dialog.cancel"))
        cancel.performClick(nil)
        eventually { feature.batchRenameDialog == nil }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["a", "b"])
        pane.table.selectRowIndexes(IndexSet(integer: try XCTUnwrap(pane.entries.firstIndex { $0.name == "a" })), byExtendingSelection: false)
        XCTAssertEqual(pane.selectedFiles.count, 1)
        XCTAssertTrue(feature.canRenameSelection)
        XCTAssertNil(feature.batchRenameDialog)
    }

    @MainActor func testConfirmationReturnsCapturedPlanWithoutRenamingUntilExecution() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchRenameConfirm-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        let suite = "BatchRenameConfirm-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var accepted: BatchRenamePlan?
        let dialog = BatchRenameDialog(sources: [source], store: BatchRenamePresets(defaults: defaults)) { accepted = $0 }
        var rules = BatchRenameRules(); rules.prefix = "neu_"
        dialog.setRules(rules); dialog.begin(on: window)
        eventually { !dialog.isPreviewPending }
        let submit = try XCTUnwrap(ContextCommands.button(in: dialog.window?.contentView, id: "dialog.accept"))
        XCTAssertTrue(submit.isEnabled)
        submit.performClick(nil)
        eventually { accepted != nil }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let plan = try XCTUnwrap(accepted)
        XCTAssertEqual(plan.items.first?.destination.path, root.appendingPathComponent("neu_original.txt").path)
        try plan.execute()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("neu_original.txt")), "original")
    }
}
