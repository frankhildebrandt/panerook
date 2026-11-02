import AppKit
import XCTest

@testable import PaneRookApp

final class RemoteDriveControlsTests: XCTestCase {
    private final class Content: NSViewController, RemotePanelContent {
        var viewController: NSViewController { self }
        var onKey: ((NSEvent) -> Bool)?
        var isActive = false
        var isBusy = false
        var hasSelection = false
        var canDownload = false
        var canUpload = false
        var showHidden = false
        var sortKey = "name"
        var sortAscending = true
        var filterPattern = ""
        var isBriefListing = false
        var backs = 0
        var disconnected = 0
        var inversions = 0
        var patterns: [(String, Bool)] = []
        var favorites: NSMenu?
        var favoritesShown = 0
        var display: (CGFloat, Bool, Bool)?

        init() { super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("unsupported") }
        override func loadView() { view = NSView() }
        func focus() {}
        func focusPath() {}
        func refresh() {}
        func goUp() {}
        func goBack() { backs += 1 }
        func openSelection() {}
        func download() {}
        func upload() {}
        func makeDirectory() {}
        func deleteSelected() {}
        func disconnect() { disconnected += 1 }
        func setFilter(_ pattern: String) { filterPattern = pattern }
        func setSort(key: String, ascending: Bool) { sortKey = key; sortAscending = ascending }
        func setBriefListing(_ brief: Bool) { isBriefListing = brief }
        func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool) {
            display = (rowHeight, showIcons, showSummary)
        }
        func selectMatching(_ pattern: String, select: Bool) { patterns.append((pattern, select)) }
        func invertSelection() { inversions += 1 }
        func installFavoritesMenu(_ menu: NSMenu) { favorites = menu }
        func showFavorites() { favoritesShown += 1 }
    }

    func testConnectionInheritsPanelSettingsAndUsesTheSameControls() throws {
        _ = NSApplication.shared
        let pane = PaneController(label: "Test", directory: FileManager.default.temporaryDirectory)
        _ = pane.view
        pane.setFilter("*.txt")
        pane.setSort(key: "size", ascending: false)
        pane.setBriefListing(true)
        pane.showHidden = true
        pane.applyDisplayOptions(rowHeight: 36, showIcons: false, showSummary: false)
        let menu = NSMenu(title: "Laufwerke")
        pane.installFavoritesMenu(menu)
        let content = Content()

        pane.showRemoteContent(content)

        XCTAssertEqual(content.filterPattern, "*.txt")
        XCTAssertEqual(content.sortKey, "size")
        XCTAssertFalse(content.sortAscending)
        XCTAssertTrue(content.showHidden)
        XCTAssertTrue(content.isBriefListing)
        XCTAssertEqual(content.display?.0, 36)
        XCTAssertEqual(content.display?.1, false)
        XCTAssertEqual(content.display?.2, false)
        XCTAssertTrue(content.favorites === menu)

        pane.setSort(key: "modified", ascending: true)
        pane.setFilter("  *.swift  ")
        pane.setBriefListing(false)
        pane.showHidden = false
        pane.selectMatching("*.swift", select: true)
        pane.selectMatching("Tests*", select: false)
        pane.invertSelection()
        pane.showFavorites()

        XCTAssertEqual(pane.sortKey, "modified")
        XCTAssertTrue(pane.sortAscending)
        XCTAssertEqual(pane.filterPattern, "*.swift")
        XCTAssertFalse(pane.isBriefListing)
        XCTAssertFalse(content.showHidden)
        XCTAssertEqual(content.patterns.map(\.0), ["*.swift", "Tests*"])
        XCTAssertEqual(content.patterns.map(\.1), [true, false])
        XCTAssertEqual(content.inversions, 1)
        XCTAssertEqual(content.favoritesShown, 1)
        XCTAssertTrue(pane.remoteContent === content)
        XCTAssertEqual(content.disconnected, 0)
    }

    func testBackAndListingCommandsKeepTheConnection() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
        let pane = PaneController(label: "Test", directory: directory)
        let content = Content()
        pane.showRemoteContent(content)

        pane.goBack()
        pane.setMode(.listing)
        pane.setMode(.tree)
        pane.setMode(.quickView)

        XCTAssertEqual(content.backs, 1)
        XCTAssertEqual(content.disconnected, 0)
        XCTAssertTrue(pane.remoteContent === content)
        XCTAssertEqual(pane.directory, directory)
    }
}
