import Foundation
import PaneRookCore
import PaneRookPanels
import XCTest

final class PanelObservationTests: XCTestCase {
    func testObservedListingKeepsNavigationAndFiltersButRejectsStaleOrHiddenResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.txt", "b.png"] { try Data().write(to: directory.appendingPathComponent(name)) }
        let files = try FileSystem.list(directory, showHidden: false)
        var state = PanelState(directory: directory)
        state.filterPattern = "*.txt"
        state.sortAscending = false
        let request = state.beginNavigation()
        XCTAssertTrue(state.completeNavigation(request, to: directory, files: [], recordHistory: false, preserveDirectorySizes: false))
        let snapshot = GitSnapshot(root: directory, branch: "main")
        state.gitSnapshot = snapshot
        XCTAssertTrue(state.applyObservedListing(files, in: directory, request: request))
        XCTAssertEqual(state.generation, request)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.entries.map(\.name), ["..", "a.txt"])
        XCTAssertEqual(state.gitSnapshot?.branch, "main")
        XCTAssertFalse(state.applyObservedListing([], in: directory.deletingLastPathComponent(), request: request))
        for mode in [PanelMode.info, .quickView, .network, .gitHistory, .terminal] {
            state.mode = mode
            XCTAssertFalse(state.applyObservedListing([], in: directory, request: request))
        }
        state.mode = .tree
        XCTAssertTrue(state.applyObservedListing(files, in: directory, request: request))
        _ = state.beginNavigation()
        XCTAssertFalse(state.applyObservedListing([], in: directory, request: request))
        state.showResults(files)
        XCTAssertFalse(state.applyObservedListing([], in: directory, request: state.generation))
        XCTAssertEqual(state.allEntries.filter { !$0.isParent }.count, 2)
    }
}
