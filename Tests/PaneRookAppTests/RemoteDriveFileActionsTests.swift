import AppKit
import PaneRookRemote
import XCTest

@testable import PaneRookApp

final class RemoteDriveFileActionsTests: XCTestCase {
    private func waitForListing(_ browser: RemoteBrowser) {
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !browser.isBusy }, object: nil)
        wait(for: [loaded], timeout: 10)
    }

    func testCopyBetweenConnectionsUsesSelectedRemoteSourceAndCapturedDestination() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let left = PaneController(label: "Left", directory: root)
        let right = PaneController(label: "Right", directory: root)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let contents = Data("The selected remote file".utf8)
        let source = RemoteBrowser(connection: try RemoteConnection(kind: .shell, host: "source.test", port: 22, user: "me"),
            peer: right, tasks: tasks, runner: { request, _ in
                if let output = request.outputFile { try contents.write(to: output); return Data() }
                return Data("-rw-r--r-- 1 501 20 24 Nov  1 10:00 selected.txt\n".utf8)
            })
        let transferred = expectation(description: "remote destination receives selected contents")
        let destination = RemoteBrowser(connection: try RemoteConnection(kind: .shell, host: "destination.test", port: 22, user: "me"),
            peer: left, tasks: tasks, runner: { request, _ in
                if let input = request.inputFile {
                    XCTAssertEqual(try Data(contentsOf: input), contents)
                    XCTAssertTrue(request.arguments.last?.contains("'/target/selected.txt'") == true)
                    transferred.fulfill()
                }
                return Data()
            })
        left.showRemoteContent(source); right.showRemoteContent(destination)
        defer { source.disconnect(); destination.disconnect() }
        source.show(directory: "/source"); destination.show(directory: "/target")
        waitForListing(source); waitForListing(destination)
        let selectedRow = try XCTUnwrap(source.entries.firstIndex { $0.name == "selected.txt" })
        source.table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        XCTAssertTrue(source.canDownload)

        source.download()
        wait(for: [transferred], timeout: 10)
        waitForListing(source)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("selected.txt").path))
        XCTAssertEqual(source.selection.map(\.name), ["selected.txt"])
        XCTAssertTrue(left.remoteContent === source)
        XCTAssertTrue(right.remoteContent === destination)
    }

    func testPreviewReadsSelectedRemoteFileIntoPrivateReadOnlyCopy() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = PaneController(label: "Local", directory: root)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let contents = Data("Readable contents".utf8)
        let browser = RemoteBrowser(connection: try RemoteConnection(kind: .shell, host: "source.test", port: 22, user: "me"),
            peer: peer, tasks: tasks, runner: { request, _ in
                if let output = request.outputFile { try contents.write(to: output); return Data() }
                return Data("-rw-r--r-- 1 501 20 17 Nov  1 10:00 preview.txt\n".utf8)
            })
        _ = browser.view
        defer { browser.disconnect() }
        browser.show(directory: "/")
        waitForListing(browser)
        let selectedRow = try XCTUnwrap(browser.entries.firstIndex { $0.name == "preview.txt" })
        browser.table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        XCTAssertTrue(browser.canPreview)
        let prepared = expectation(description: "readable remote preview")
        browser.preparePreview { files in
            do {
                let file = try XCTUnwrap(files.first)
                XCTAssertEqual(files.count, 1)
                XCTAssertEqual(file.lastPathComponent, "preview.txt")
                XCTAssertEqual(try Data(contentsOf: file), contents)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o400)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preview.txt").path))
            } catch { XCTFail(error.localizedDescription) }
            prepared.fulfill()
        }
        wait(for: [prepared], timeout: 10)
    }
}
