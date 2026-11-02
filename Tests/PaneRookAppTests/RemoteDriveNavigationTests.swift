import AppKit
import PaneRookRemote
import XCTest

@testable import PaneRookApp

final class RemoteDriveNavigationTests: XCTestCase {
    private func browser(runner: @escaping RemoteFileSystem.Runner) throws -> (RemoteBrowser, PaneController, TaskCenter) {
        _ = NSApplication.shared
        let peer = PaneController(label: "Local", directory: FileManager.default.temporaryDirectory)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let connection = try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "me")
        let browser = RemoteBrowser(connection: connection, peer: peer, tasks: tasks, runner: runner)
        _ = browser.view
        return (browser, peer, tasks)
    }

    private func idle(_ browser: RemoteBrowser) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !browser.isBusy }, object: nil)], timeout: 10)
    }

    func testParentAndBackKeepRemoteHistoryAndSelectionAndFailuresDoNotChangeIt() throws {
        let listing = Data("drwxr-xr-x 2 501 20 0 Nov  1 10:00 child\n-rw-r--r-- 1 501 20 12 Nov  1 10:00 file.txt\n".utf8)
        let (browser, peer, tasks) = try browser { invocation, _ in
            if invocation.arguments.last == "LC_ALL=C ls -lan '/missing'" { throw RemoteError.process("Missing directory") }
            return listing
        }
        defer { browser.disconnect(); withExtendedLifetime((peer, tasks)) {} }
        browser.show(directory: "/home/me")
        idle(browser)
        XCTAssertEqual(browser.entries.first?.name, "..")
        XCTAssertTrue(browser.history.isEmpty)
        browser.navigate("child")
        idle(browser)
        XCTAssertEqual(browser.directory, "/home/me/child")
        XCTAssertEqual(browser.history, ["/home/me"])
        browser.goUp()
        idle(browser)
        XCTAssertEqual(browser.directory, "/home/me")
        XCTAssertEqual(browser.selection.map(\.name), ["child"])
        browser.goBack()
        idle(browser)
        XCTAssertEqual(browser.directory, "/home/me/child")
        XCTAssertEqual(browser.history, ["/home/me"])
        browser.navigate("/missing")
        idle(browser)
        XCTAssertEqual(browser.directory, "/home/me/child")
        XCTAssertEqual(browser.pathField.stringValue, "/home/me/child")
        XCTAssertEqual(browser.history, ["/home/me"])
        browser.goBack()
        idle(browser)
        XCTAssertEqual(browser.directory, "/home/me")
        XCTAssertTrue(browser.history.isEmpty)
        browser.reload()
        idle(browser)
        XCTAssertTrue(browser.history.isEmpty, "Refreshing must not create history entries")
    }

    func testFailedNavigationDoesNotRefreshTheOtherConnection() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
        let left = PaneController(label: "Left", directory: directory)
        let right = PaneController(label: "Right", directory: directory)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let connection = try RemoteConnection(kind: .shell, host: "host.test", port: 22, user: "me")
        let source = RemoteBrowser(connection: connection, peer: right, tasks: tasks, runner: { _, _ in
            throw RemoteError.process("Connection unavailable")
        })
        let lock = NSLock()
        var peerRequests = 0
        let destination = RemoteBrowser(connection: connection, peer: left, tasks: tasks, runner: { _, _ in
            lock.withLock { peerRequests += 1 }; return Data()
        })
        left.showRemoteContent(source); right.showRemoteContent(destination)
        defer { source.disconnect(); destination.disconnect() }
        source.show(directory: "/")
        idle(source)
        idle(destination)
        XCTAssertEqual(lock.withLock { peerRequests }, 0,
                       "Read failures must not trigger requests in the other panel, which could fail and refresh this panel again")
    }

    func testSortingFilteringAndHiddenFilesReuseListingAndNeverSelectParentForActions() throws {
        let lock = NSLock()
        var requests = 0
        let listing = Data(([
            "-rw-r--r-- 1 501 20 20 Nov  1 10:00 file10.txt",
            "-rw-r--r-- 1 501 20 4 Nov  1 10:00 file2.txt",
            "-rw-r--r-- 1 501 20 1 Nov  1 10:00 .hidden.txt",
            "drwxr-xr-x 2 501 20 0 Nov  1 10:00 folder"
        ].joined(separator: "\n") + "\n").utf8)
        let (browser, peer, tasks) = try browser { _, _ in
            lock.withLock { requests += 1 }
            return listing
        }
        defer { browser.disconnect(); withExtendedLifetime((peer, tasks)) {} }
        browser.show(directory: "/files")
        idle(browser)
        XCTAssertEqual(browser.entries.map(\.name), ["..", "folder", "file2.txt", "file10.txt"])
        browser.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        browser.setSort(key: "size", ascending: false)
        XCTAssertEqual(browser.entries.map(\.name), ["..", "folder", "file10.txt", "file2.txt"])
        XCTAssertEqual(browser.selection.map(\.name), ["file10.txt"])
        browser.showHidden = true
        browser.setFilter("*.txt")
        XCTAssertEqual(browser.entries.map(\.name), ["..", "file10.txt", "file2.txt", ".hidden.txt"])
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertFalse(browser.hasSelection)
        XCTAssertFalse(browser.canDownload)
        XCTAssertFalse(browser.canPreview)
        browser.selectMatching("*.txt", select: true)
        XCTAssertEqual(browser.selection.count, 3)
        XCTAssertFalse(browser.selectedRows.contains { $0.name == ".." })
        browser.invertSelection()
        XCTAssertTrue(browser.selection.isEmpty)
        browser.setFilter("does-not-exist")
        XCTAssertEqual(browser.entries.map(\.name), [".."])
        XCTAssertFalse(browser.hasSelection)
        XCTAssertEqual(lock.withLock { requests }, 1)
    }
}
