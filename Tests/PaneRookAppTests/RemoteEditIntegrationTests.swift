import AppKit
import XCTest
import PaneRookRemote
@testable import PaneRookApp

final class RemoteEditIntegrationTests: XCTestCase {
    private final class Host: PreviewHost {
        let activePane: any PanelAccess
        var presentationWindow: NSWindow? { nil }
        var canUseMenus = true
        var canUseSelection: Bool { false }
        var canUseNativeSelection: Bool { false }
        lazy var tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        init(pane: any PanelAccess) { activePane = pane }
        func activate(_ pane: any PanelAccess) {}
        func recordFiles(_ urls: [URL]) {}
        func openUsingExtension(_ urls: [URL]) -> Bool { false }
        func showError(_ error: Error, detail: String) { XCTFail(error.localizedDescription) }
    }
    private func browser() throws -> (PaneController, RemoteBrowser) {
        _ = NSApplication.shared
        let pane = PaneController(label: "Test", directory: FileManager.default.temporaryDirectory)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let browser = RemoteBrowser(connection: try RemoteConnection(kind: .sftp, host: "test.invalid", port: 22, user: "user"), peer: pane, tasks: tasks)
        _ = browser.view
        browser.directory = "/captured"
        browser.allEntries = [RemoteEntry(name: "file.txt", isDirectory: false)]
        browser.rebuildListing()
        pane.showRemoteContent(browser)
        browser.setFilter("")
        browser.table.selectRowIndexes(IndexSet(integer: try XCTUnwrap(browser.entries.firstIndex { $0.name == "file.txt" })), byExtendingSelection: false)
        return (pane, browser)
    }
    func testF4AvailabilityAndCapturedRemoteRequestsRespectRegularSelectionAndBusyState() throws {
        let (pane, remote) = try browser()
        let host = Host(pane: pane)
        let preview = PreviewTools(owner: host)
        let registry = CommandRegistry()
        preview.registerCommands(in: registry)
        let edit = try XCTUnwrap(registry["edit"])
        XCTAssertTrue(edit.enabled())
        XCTAssertEqual(edit.defaultBinding, .function(4))
        let request = try XCTUnwrap(remote.remoteEditRequests.first)
        XCTAssertEqual(request.path, "/captured/file.txt")
        remote.directory = "/navigated"
        XCTAssertEqual(request.path, "/captured/file.txt")
        XCTAssertTrue(request.fileSystem === remote.fileSystem)
        remote.cancellation = RemoteCancellation()
        XCTAssertFalse(edit.enabled())
        remote.cancellation = nil
        for entry in [RemoteEntry(name: "folder", isDirectory: true),
                      RemoteEntry(name: "link", isDirectory: false, isSymbolicLink: true),
                      RemoteEntry(name: "special", isDirectory: false, isRegularFile: false)] {
            remote.allEntries = [entry]; remote.rebuildListing()
            XCTAssertFalse(edit.enabled())
        }
        remote.allEntries = [RemoteEntry(name: "file.txt", isDirectory: false)]; remote.rebuildListing()
        host.canUseMenus = false
        XCTAssertFalse(edit.enabled())
        host.canUseMenus = true; remote.disconnected = true
        XCTAssertFalse(edit.enabled())
    }
    func testEditorPreferenceAndSessionCommandsHaveIndependentPersistentIDs() throws {
        let (pane, _) = try browser()
        let host = Host(pane: pane)
        let suite = "PaneRook-RemoteEdit-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = RemoteEditTools(owner: host, defaults: defaults)
        XCTAssertEqual(tools.editorURL.path, "/System/Applications/TextEdit.app")
        defaults.set("/Applications/Editor.app", forKey: RemoteEditTools.editorPreferenceKey)
        XCTAssertEqual(RemoteEditTools(owner: host, defaults: defaults).editorURL.path, "/Applications/Editor.app")
        let registry = CommandRegistry(defaults: defaults)
        tools.registerCommands(in: registry); registry.addContextDefinitions()
        XCTAssertNotNil(registry["editor.choose"])
        XCTAssertNotNil(registry["remoteEdit.sessions"])
        for id in ["open", "upload", "cancel", "stop", "reveal"] {
            XCTAssertEqual(try XCTUnwrap(registry["remoteEdit." + id]).scope, .remoteEdit)
        }
        XCTAssertTrue(tools.confirmTermination(), "No sessions must not prompt on quit")
    }
    func testEmptyRecoveryWindowBuildsWithoutStartingRemoteWork() throws {
        _ = NSApplication.shared
        let window = RemoteEditWindow(root: FileManager.default.temporaryDirectory)
        XCTAssertEqual(window.window?.title, "Remote-Arbeitskopien")
        window.update([])
        XCTAssertTrue(window.window?.contentView?.subviews.isEmpty == false)
        window.close()
    }
}
