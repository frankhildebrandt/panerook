import AppKit
import PaneRookRemote
import XCTest
@testable import PaneRookApp

final class RemoteEditWorkspaceTests: XCTestCase {
    func testCapturedEditStillUploadsAfterSwitchingWorkspaceAndClosingItsTab() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "PaneRook-RemoteEditWorkspaces-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "leftDirectory")
        defaults.set(root.path, forKey: "rightDirectory")
        let source = root.appendingPathComponent("source"), unrelated = root.appendingPathComponent("unrelated")
        for directory in [source, unrelated] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("original".utf8).write(to: directory.appendingPathComponent("file.txt"))
        }
        let commander = CommanderController(defaults: defaults)
        commander.tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        _ = commander.view
        let originalWorkspace = commander.workspaceSession
        commander.newTab()
        let editedPane = commander.left
        let browser = RemoteBrowser(connection: try RemoteConnection(kind: .shell, host: "test.invalid", port: 22, user: "me"),
            peer: commander.right, tasks: commander.tasks, runner: { invocation, token in
                // Exercise the SSH transport with a private local server fixture.
                // No network or external editor is started.
                var local = invocation
                local.executable = "/bin/sh"
                local.arguments = ["-c", try XCTUnwrap(invocation.arguments.last)]
                return try RemoteFileSystem.run(local, token)
            })
        editedPane.showRemoteContent(browser)
        browser.directory = source.path
        browser.allEntries = [RemoteEntry(name: "file.txt", isDirectory: false)]
        browser.rebuildListing()
        let request = try XCTUnwrap(editedPane.remoteContent?.remoteEditRequests.first)
        let session = try RemoteEditSession.prepare(fileSystem: request.fileSystem, path: request.path,
                                                   root: root.appendingPathComponent("copies"))
        try Data("edited".utf8).write(to: session.workingURL, options: .atomic)
        commander.createWorkspace()
        commander.left.navigate(to: unrelated)
        XCTAssertFalse(commander.workspaceSession === originalWorkspace)
        commander.loadWorkspace(id: originalWorkspace.id)
        commander.activate(editedPane)
        commander.closeActiveTab()
        XCTAssertFalse(commander.left === editedPane)
        XCTAssertTrue(browser.disconnected)
        XCTAssertEqual(try session.upload(), .uploaded)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("file.txt")), "edited")
        XCTAssertEqual(try String(contentsOf: unrelated.appendingPathComponent("file.txt")), "original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workingURL.path))
    }
}
