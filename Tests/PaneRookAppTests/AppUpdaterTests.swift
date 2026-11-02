import AppKit
import XCTest
import Sparkle

@testable import PaneRookApp

final class AppUpdaterTests: XCTestCase {
    private let appURL = URL(fileURLWithPath: "/Applications/PaneRook.app")
    private var releaseInfo: [String: Any] {
        ["SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
         "SUFeedURL": "https://github.com/frankhildebrandt/panerook/releases/latest/download/appcast.xml",
         "CFBundleVersion": "3"]
    }

    func testReleaseBundleRequiresPublicKeyAndHTTPSFeed() {
        XCTAssertTrue(AppUpdater.isConfigured(bundleURL: appURL, info: releaseInfo))
        for key in ["SUPublicEDKey", "SUFeedURL", "CFBundleVersion"] {
            var info = releaseInfo
            info.removeValue(forKey: key)
            XCTAssertFalse(AppUpdater.isConfigured(bundleURL: appURL, info: info), key)
        }
        for key in ["", "not base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = releaseInfo
            info["SUPublicEDKey"] = key
            XCTAssertFalse(AppUpdater.isConfigured(bundleURL: appURL, info: info))
        }
        for feed in ["http://github.com/feed.xml", "file:///tmp/appcast.xml", "https:", ""] {
            var info = releaseInfo
            info["SUFeedURL"] = feed
            XCTAssertFalse(AppUpdater.isConfigured(bundleURL: appURL, info: info), feed)
        }
        XCTAssertFalse(AppUpdater.isConfigured(bundleURL: appURL.deletingPathExtension(), info: releaseInfo))
    }

    func testDevelopmentLaunchExposesDisabledUpdateCommandsWithoutStartingSparkle() throws {
        _ = NSApplication.shared
        let updater = AppUpdater(bundle: Bundle(for: Self.self), presentationWindow: { nil })
        updater.start()
        XCTAssertNotNil(updater.unavailableReason)
        let previousMenu = NSApp.mainMenu
        let previousHelp = NSApp.helpMenu
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.helpMenu = previousHelp
        }
        let commander = CommanderController()
        let menus = CommanderMenus(commander: commander, updater: updater)
        menus.install()
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let item = try XCTUnwrap(appMenu.items.first { $0.action == #selector(AppUpdater.checkForUpdates(_:)) })
        XCTAssertTrue(item.target === updater)
        XCTAssertFalse(updater.validateMenuItem(item))
        XCTAssertNotNil(item.toolTip)
    }

    func testDevelopmentSettingsExplainUnavailabilityAndDisableUpdatePreferences() throws {
        _ = NSApplication.shared
        let updater = AppUpdater(bundle: Bundle(for: Self.self), presentationWindow: { nil })
        let settings = try XCTUnwrap(updater.makeSettingsView() as? NSStackView)
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        let controls = descendants(settings)
        let checks = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "updates.automaticChecks" } as? SettingsToggle)
        let downloads = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "updates.automaticDownloads" } as? SettingsToggle)
        let reason = try XCTUnwrap(controls.first { $0.identifier?.rawValue == "updates.unavailableReason" } as? NSTextField)
        XCTAssertFalse(checks.isEnabled)
        XCTAssertFalse(downloads.isEnabled)
        XCTAssertEqual(reason.stringValue, updater.unavailableReason)
    }

    func testEnablingChecksAndDownloadsTogetherPersistsAcrossUpdaterInstances() throws {
        _ = NSApplication.shared
        let id = "app.panerook.updater-tests.\(UUID().uuidString)"
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: app)
        }
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
                                   "SUEnableAutomaticChecks": false, "SUAutomaticallyUpdate": false]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: app))
        func makeUpdater() -> SPUUpdater {
            SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                       userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
        }
        let updater = makeUpdater()
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        AppUpdater.applySettings(to: updater, checks: true, downloads: true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        let nextLaunch = makeUpdater()
        XCTAssertTrue(nextLaunch.automaticallyChecksForUpdates)
        XCTAssertTrue(nextLaunch.automaticallyDownloadsUpdates)
        AppUpdater.applySettings(to: nextLaunch, checks: false, downloads: false)
        XCTAssertFalse(nextLaunch.automaticallyChecksForUpdates)
        // Disabling checks preserves the user's download preference.
        nextLaunch.automaticallyChecksForUpdates = true
        XCTAssertTrue(nextLaunch.automaticallyDownloadsUpdates)
    }
}
