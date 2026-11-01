import XCTest
@testable import PaneRookCore

final class PanelFavoritesTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookFavorites-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        suite = "PaneRookFavoritesTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try fm.removeItem(at: root)
    }
    @discardableResult private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
    private func paths(_ kind: FavoriteLocationKind) -> [String] {
        FavoriteLocationResolver.locations(home: root).first { $0.kind == kind }!.urls.map(\.path)
    }

    func testMissingProvidersStillAppearInTheFixedOrder() throws {
        let locations = FavoriteLocationResolver.locations(home: root)
        XCTAssertEqual(locations.map(\.kind), [.iCloudDrive, .protonDrive, .dropbox])
        XCTAssertTrue(locations.allSatisfy { $0.urls.isEmpty })
        XCTAssertEqual(FavoriteLocationResolver.locations(home: URL(string: "sftp://example.invalid/home")!).map(\.urls), [[], [], []])
    }

    func testProviderDetectionIsShallowAndSupportsMultipleAccountsAndLegacyRoots() throws {
        let cloud = try directory("Library/Mobile Documents/com~apple~CloudDocs")
        let protonA = try directory("Library/CloudStorage/ProtonDrive-personal-folder")
        let protonB = try directory("Library/CloudStorage/pRoToN dRiVe (Work)")
        let protonLegacy = try directory("Proton Drive")
        let dropboxA = try directory("Library/CloudStorage/Dropbox")
        let dropboxB = try directory("Library/CloudStorage/dropbox-Team")
        let dropboxLegacy = try directory("Dropbox")
        try directory("Library/CloudStorage/DropboxBackup")
        try directory("Library/CloudStorage/ProtonDriveUnrelated")
        try directory("Library/CloudStorage/Proton Drive backup")
        try directory("Library/CloudStorage/Dropbox-")
        try directory("Library/CloudStorage/Parent/Dropbox-Nested")
        let file = root.appendingPathComponent("Library/CloudStorage/ProtonDrive-file")
        try Data("ordinary file".utf8).write(to: file)
        XCTAssertEqual(paths(.iCloudDrive), [cloud.path])
        XCTAssertEqual(Set(paths(.protonDrive)), Set([protonA.path, protonB.path, protonLegacy.path]))
        XCTAssertEqual(Set(paths(.dropbox)), Set([dropboxA.path, dropboxB.path, dropboxLegacy.path]))
    }

    func testProviderSymlinksResolveAndDuplicatePhysicalRootsAreShownOnce() throws {
        let actualProton = try directory("actualProton")
        let actualDropbox = try directory("Library/CloudStorage/Dropbox-main")
        let storage = try directory("Library/CloudStorage")
        for name in ["ProtonDrive-one", "ProtonDrive-two"] {
            try fm.createSymbolicLink(at: storage.appendingPathComponent(name), withDestinationURL: actualProton)
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("Proton Drive"), withDestinationURL: actualProton)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Dropbox"), withDestinationURL: actualDropbox)
        try fm.createSymbolicLink(atPath: storage.appendingPathComponent("Dropbox-dangling").path, withDestinationPath: "missing")
        let proton = FavoriteLocationResolver.locations(home: root).first { $0.kind == .protonDrive }!.urls
        XCTAssertEqual(proton.count, 1)
        XCTAssertEqual(proton.first?.resolvingSymlinksInPath().standardizedFileURL.path, actualProton.path)
        XCTAssertEqual(paths(.dropbox), [actualDropbox.path])
    }

    func testLegacyHotlistAndOfflineFoldersRemainAvailableWithoutMutation() throws {
        let online = try directory("online")
        let offline = root.appendingPathComponent("unmounted/share", isDirectory: true).standardizedFileURL
        let original = [online.path, offline.path, online.path + "/./"]
        defaults.set(original, forKey: "hotlist")
        let store = PanelFavoriteStore(defaults: defaults)
        XCTAssertEqual(try store.folders().map(\.path), [online.path, offline.path])
        XCTAssertEqual(defaults.stringArray(forKey: "hotlist"), original)
        try store.removeFolder(offline)
        XCTAssertEqual(defaults.stringArray(forKey: "hotlist"), [online.path])
        XCTAssertEqual(try PanelFavoriteStore(defaults: defaults).folders().map(\.path), [online.path])
    }

    func testAddingDeduplicatesAndRejectsNonDirectoriesAndNonLocalURLs() throws {
        let folder = try directory("favorite")
        let store = PanelFavoriteStore(defaults: defaults)
        try store.addFolder(folder)
        try store.addFolder(folder.appendingPathComponent("."))
        XCTAssertEqual(try store.folders().map(\.path), [folder.path])
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        for bad in [file, root.appendingPathComponent("missing"), URL(string: "sftp://example.invalid/path")!, URL(fileURLWithPath: "/nul\0path")] {
            XCTAssertThrowsError(try store.addFolder(bad))
        }
        XCTAssertEqual(defaults.stringArray(forKey: "hotlist"), [folder.path])
        try store.removeFolder(folder)
        XCTAssertEqual(try store.folders(), [])
    }

    func testOverridesPersistChosenPathsAndDoNotChangeAutomaticDetection() throws {
        let chosen = try directory("chosenDropbox")
        let store = PanelFavoriteStore(defaults: defaults)
        XCTAssertNil(store.overriddenLocation(.dropbox))
        try store.overrideLocation(.dropbox, with: chosen)
        XCTAssertEqual(PanelFavoriteStore(defaults: defaults).overriddenLocation(.dropbox)?.path, chosen.path)
        XCTAssertEqual(paths(.dropbox), [])
        XCTAssertThrowsError(try store.overrideLocation(.dropbox, with: root.appendingPathComponent("missing")))
        XCTAssertEqual(store.overriddenLocation(.dropbox)?.path, chosen.path)
        try fm.removeItem(at: chosen)
        // An unmounted custom location is remembered so the UI can explain or reconfigure it.
        XCTAssertEqual(store.overriddenLocation(.dropbox)?.path, chosen.path)
        try store.overrideLocation(.protonDrive, with: root)
        store.clearOverrideLocation(.dropbox)
        XCTAssertNil(store.overriddenLocation(.dropbox))
        XCTAssertEqual(store.overriddenLocation(.protonDrive)?.path, root.standardizedFileURL.path)
        store.clearOverrideLocation(.protonDrive)
        XCTAssertNil(store.overriddenLocation(.protonDrive))
    }

    func testCorruptStoredPathsAreReportedAndNeverSilentlyReplaced() throws {
        let store = PanelFavoriteStore(defaults: defaults)
        let valid = try directory("valid")
        for object: Any in [["relative/folder"], [""], ["/nul\0path"], 42] {
            defaults.set(object, forKey: "hotlist")
            XCTAssertThrowsError(try store.folders())
            XCTAssertThrowsError(try store.addFolder(valid))
            XCTAssertThrowsError(try store.removeFolder(valid))
            XCTAssertEqual(defaults.object(forKey: "hotlist") as? NSObject, object as? NSObject)
        }
    }
}
