import AppKit
import PaneRookCore
import PaneRookPanels
import XCTest

@testable import PaneRookApp

final class AvailableSpaceTests: XCTestCase {
    private var directory: URL!

    private final class CapacitySource {
        private let lock = NSLock()
        private var value: Int64? = 128_000_000_000
        func set(_ value: Int64?) { lock.withLock { self.value = value } }
        func read(_ url: URL) -> Int64? {
            XCTAssertFalse(Thread.isMainThread)
            return lock.withLock { value }
        }
    }

    private final class RemoteContent: NSViewController, RemotePanelContent {
        var viewController: NSViewController { self }
        var onKey: ((NSEvent) -> Bool)?
        var isActive = false
        var isBusy = false
        var hasSelection = false
        var canDownload = false
        var canUpload = false
        override func loadView() { view = NSView() }
        func focus() {}
        func focusPath() {}
        func refresh() {}
        func goUp() {}
        func openSelection() {}
        func download() {}
        func upload() {}
        func makeDirectory() {}
        func deleteSelected() {}
        func disconnect() {}
    }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("PaneRook-space-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: directory.appendingPathComponent("file.txt"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            condition()
        }, object: nil)], timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func label(in pane: PaneController) throws -> NSTextField {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + ((view as? NSStackView)?.arrangedSubviews ?? view.subviews).flatMap(descendants)
        }
        pane.view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        pane.view.layoutSubtreeIfNeeded()
        return try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Test: Verfügbarer Speicherplatz" })
    }

    func testShowsCapacityRefreshesAfterTasksAndAcceptsAFullVolume() throws {
        let source = CapacitySource()
        let pane = PaneController(label: "Test", directory: directory, capacityReader: source.read)
        let space = try label(in: pane)
        eventually { space.stringValue == "128 GB frei" && !space.isHidden }
        XCTAssertEqual(pane.pathField.stringValue, directory.path)
        XCTAssertTrue(space.toolTip?.contains(directory.path) == true)

        source.set(64_000_000_000)
        pane.refreshAfterTask()
        eventually { space.stringValue == "64 GB frei" && !space.isHidden }

        source.set(0)
        pane.refresh()
        eventually { space.stringValue == ByteCountFormatter.string(fromByteCount: 0, countStyle: .file) + " frei" }
        XCTAssertFalse(space.isHidden)
    }

    func testHidesWhenUnavailableAndRestoresAfterNavigation() throws {
        let source = CapacitySource()
        let pane = PaneController(label: "Test", directory: directory, capacityReader: source.read)
        let space = try label(in: pane)
        eventually { !space.isHidden }

        for value: Int64? in [nil, -1] {
            source.set(value)
            pane.refresh()
            XCTAssertTrue(space.isHidden)
            eventually { pane.table.isEnabled && !pane.entries.isEmpty }
        }

        let next = directory.appendingPathComponent("next", isDirectory: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        source.set(32_000_000_000)
        pane.navigate(to: next)
        eventually { pane.directory == next && space.stringValue == "32 GB frei" && !space.isHidden }
        XCTAssertTrue(space.toolTip?.contains(next.path) == true)
    }

    func testModeChangesSearchResultsAndNarrowPanesKeepAUsablePathBar() throws {
        let source = CapacitySource()
        let pane = PaneController(label: "Test", directory: directory, capacityReader: source.read)
        let space = try label(in: pane)
        eventually { !space.isHidden }

        for width: CGFloat in [320, 700, 320, 700] {
            pane.view.setFrameSize(NSSize(width: width, height: 500))
            pane.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(space.isHidden, width == 320)
            XCTAssertGreaterThanOrEqual(pane.pathField.frame.width, 180)
            if !space.isHidden {
                let path = pane.pathField.convert(pane.pathField.bounds, to: pane.view)
                let capacity = space.convert(space.bounds, to: pane.view)
                XCTAssertGreaterThan(capacity.minX, path.maxX)
                XCTAssertEqual(capacity.midY, path.midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(capacity.width, space.intrinsicContentSize.width)
            }
        }

        pane.setMode(.tree)
        eventually { !space.isHidden }
        for mode in [PanelMode.info, .quickView, .gitHistory, .network] {
            pane.setMode(mode)
            XCTAssertTrue(space.isHidden)
        }
        pane.setMode(.listing)
        eventually { !space.isHidden }
        pane.panelize([directory.appendingPathComponent("file.txt")])
        XCTAssertTrue(space.isHidden)
        pane.navigate(to: directory)
        eventually { !space.isHidden }
    }

    func testSlowOldVolumeDoesNotBlockNavigationOrOverwriteNewCapacity() throws {
        let next = directory.appendingPathComponent("next", isDirectory: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: false)
        let first = directory!
        let started = expectation(description: "Old volume query started")
        let finished = expectation(description: "Old volume query returned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pane = PaneController(label: "Test", directory: first, capacityReader: { url in
            if url == first {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                finished.fulfill()
                return 128_000_000_000
            }
            return 32_000_000_000
        })
        let space = try label(in: pane)
        wait(for: [started], timeout: 5)
        pane.navigate(to: next)
        eventually { pane.directory == next && space.stringValue == "32 GB frei" }
        release.signal()
        wait(for: [finished], timeout: 5)
        // Drain the old worker's main-queue completion before checking its effect.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(space.stringValue, "32 GB frei")
        XCTAssertTrue(space.toolTip?.contains(next.path) == true)
    }

    func testArchiveDoesNotShowTheContainingVolumesCapacity() throws {
        let archive = directory.appendingPathComponent("fixture.tar")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", archive.path, "-C", directory.path, "file.txt"]
        process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let source = CapacitySource()
        let pane = PaneController(label: "Test", directory: directory, capacityReader: source.read)
        let space = try label(in: pane)
        eventually { !space.isHidden }
        pane.navigate(to: archive)
        eventually { pane.directory == archive && pane.entries.contains { $0.name == "file.txt" } }
        XCTAssertTrue(space.isHidden)
        pane.navigate(to: directory)
        eventually { !space.isHidden }
    }

    func testRemoteContentHidesLocalCapacityAndDisconnectRefreshesIt() throws {
        let source = CapacitySource()
        let pane = PaneController(label: "Test", directory: directory, capacityReader: source.read)
        let space = try label(in: pane)
        eventually { !space.isHidden }
        pane.showRemoteContent(RemoteContent())
        XCTAssertTrue(space.isHidden)
        XCTAssertTrue(space.stringValue.isEmpty)
        source.set(64_000_000_000)
        pane.showRemoteContent(nil)
        eventually { space.stringValue == "64 GB frei" && !space.isHidden }
    }
}
