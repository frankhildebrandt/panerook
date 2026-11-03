import AppKit
import PaneRookCore
import XCTest
@testable import PaneRookApp

final class DirectorySyncWindowTests: XCTestCase {
    private final class Host: InspectionHost {
        let leftPane: any PanelAccess
        let rightPane: any PanelAccess
        var activePane: any PanelAccess
        var otherPane: any PanelAccess { rightPane }
        var presentationWindow: NSWindow? { nil }
        let canUseMenus = true
        let canUseNativeDirectory = true
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        init(left: URL, right: URL) {
            leftPane = PaneController(label: "Links", directory: left)
            rightPane = PaneController(label: "Rechts", directory: right)
            activePane = leftPane
        }
        func activate(_ pane: any PanelAccess) { activePane = pane }
        func showError(_ error: Error, detail: String) { XCTFail(error.localizedDescription) }
    }
    private func control<T: NSControl>(_ type: T.Type, _ id: String, in view: NSView) throws -> T {
        if let result = view as? T, result.identifier?.rawValue == id { return result }
        for child in view.subviews {
            if let result = try? control(type, id, in: child) { return result }
        }
        throw NSError(domain: "Missing control \(id)", code: 1)
    }
    private func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(8)
        while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(predicate())
    }
    @MainActor func testPreviewUsesCapturedDirectoriesAndChangesInvalidateExecution() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-sync-window-\(UUID())")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for path in [left, right] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("copy".utf8).write(to: left.appendingPathComponent("file"))
        let suite = "PaneRook-sync-window-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = Host(left: left, right: right)
        let controller = DirectorySyncWindow(host: host, store: .init(defaults: defaults))
        defer { controller.close() }
        controller.makePreview()
        host.rightPane.navigate(to: root)
        waitUntil { controller.plan != nil }
        XCTAssertEqual(controller.plan?.destination.lastPathComponent, "right")
        XCTAssertEqual(controller.selection, ["file"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: right.appendingPathComponent("file").path))
        let content = try XCTUnwrap(controller.window?.contentView)
        let execute = try control(NSButton.self, "sync.execute", in: content)
        XCTAssertTrue(execute.isEnabled)
        let exclusions = try control(NSTextField.self, "sync.exclusions", in: content)
        exclusions.stringValue = "file"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: exclusions))
        XCTAssertNil(controller.plan); XCTAssertFalse(execute.isEnabled)
        controller.makePreview(); waitUntil { controller.plan != nil }
        XCTAssertTrue(controller.selection.isEmpty)
    }
    @MainActor func testProfilesAndConfirmedExecutionThroughTaskQueue() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-sync-execution-\(UUID())")
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for path in [left, right] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("new".utf8).write(to: left.appendingPathComponent("file"))
        try Data("old".utf8).write(to: right.appendingPathComponent("file"))
        let suite = "PaneRook-sync-profiles-ui-\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DirectorySyncProfileStore(defaults: defaults)
        let host = Host(left: left, right: right)
        let controller = DirectorySyncWindow(host: host, store: store)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        try control(NSTextField.self, "sync.profileName", in: content).stringValue = "Testprofil"
        try control(NSButton.self, "sync.profile.save", in: content).performClick(nil)
        XCTAssertEqual(try store.profiles().map(\.name), ["Testprofil"])
        XCTAssertFalse(try store.profiles()[0].options.deleteExtraneous)
        controller.showWindow(nil)
        controller.makePreview(); waitUntil { controller.plan != nil }
        XCTAssertEqual(controller.selection, ["file"])
        XCTAssertEqual(controller.plan?.actions.first?.kind, .updateFile)
        XCTAssertTrue(try control(NSButton.self, "sync.execute", in: content).isEnabled)
        controller.confirmExecution()
        let alert = try XCTUnwrap(controller.confirmation)
        XCTAssertEqual(alert.messageText, "Synchronisation ausführen?")
        let accept = try XCTUnwrap(alert.buttons.first)
        XCTAssertEqual(try String(contentsOf: right.appendingPathComponent("file")), "old")
        XCTAssertTrue(accept.sendAction(accept.action, to: accept.target))
        let remove = try control(NSButton.self, "sync.profile.remove", in: content)
        waitUntil { (try? String(contentsOf: right.appendingPathComponent("file"))) == "new" && remove.isEnabled && !host.tasks.hasActiveTasks }
        XCTAssertNil(controller.plan)
        XCTAssertFalse(try control(NSButton.self, "sync.execute", in: content).isEnabled)
        try control(NSButton.self, "sync.profile.remove", in: content).performClick(nil)
        XCTAssertTrue(try store.profiles().isEmpty)
    }
}
