import AppKit
import XCTest

@testable import PaneRookApp

final class AppearanceUpdateTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testAppearanceCardsDoNotTouchPanelDataLayoutHighlightsOrKeyBindings() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-AppearanceUpdates-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
        defaults.set(AppColorScheme.light.rawValue, forKey: "appearance")
        ThemeManager.apply(defaults: defaults)
        let host = AppearancePreferencesHost(defaults: defaults)
        let preferences = PreferencesTools(owner: host, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .appearance, defaults: defaults,
                                    updaterView: { NSView() }, onClose: {})
        let content = try XCTUnwrap(dialog.window?.contentView)
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        let dark = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.scheme.dark" })
        let ocean = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.theme.ocean" })
        dark.performClick(nil)
        ocean.performClick(nil)
        XCTAssertEqual(ThemeManager.colorScheme, .dark)
        XCTAssertEqual(ThemeManager.theme, .ocean)
        XCTAssertEqual(host.panelReads, 0, "A color change must not recreate file cells or load their icons.")
        XCTAssertEqual(host.layoutUpdates, 0)
        XCTAssertEqual(host.highlightUpdates, 0, "A color change must not reread highlight.json.")
        XCTAssertEqual(host.keyBindingUpdates, 0)
        XCTAssertFalse(host.left.isViewLoaded)
        XCTAssertFalse(host.right.isViewLoaded)
    }

    func testEveryAppearanceCardTracksItsWholePaintedArea() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-CardHitTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = AppearancePreferencesHost(defaults: defaults)
        let preferences = PreferencesTools(owner: host, defaults: defaults)
        let dialog = SettingsDialog(preferences: preferences, section: .appearance, defaults: defaults,
                                    updaterView: { NSView() }, onClose: {})
        let window = try XCTUnwrap(dialog.window)
        let root = try XCTUnwrap(window.contentView)
        root.superview?.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        let cards = descendants(root).compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("appearance.") == true }
        XCTAssertEqual(cards.count, 9)
        for card in cards {
            let points = [NSPoint(x: 8, y: 8), NSPoint(x: card.bounds.midX, y: card.bounds.midY),
                          NSPoint(x: card.bounds.maxX - 8, y: card.bounds.maxY - 8)]
            for point in points {
                let event = try mouseEvent(.leftMouseDown, card: card, point: point, window: window)
                let hit = try XCTUnwrap(card.cell).hitTest(for: event, in: card.bounds, of: card)
                XCTAssertTrue(hit.contains(.trackableArea), "\(card.title), \(point) must accept a mouse click.")
            }
            let outside = try mouseEvent(.leftMouseDown, card: card, point: NSPoint(x: -1, y: -1), window: window)
            XCTAssertTrue(try XCTUnwrap(card.cell).hitTest(for: outside, in: card.bounds, of: card).isEmpty)
            card.isEnabled = false
            let center = try mouseEvent(.leftMouseDown, card: card, point: NSPoint(x: card.bounds.midX, y: card.bounds.midY), window: window)
            XCTAssertTrue(try XCTUnwrap(card.cell).hitTest(for: center, in: card.bounds, of: card).isEmpty)
        }
    }

    func testSingleMouseClicksOnCardCenterAndCornerChangeTheSelection() throws {
        _ = NSApplication.shared
        // Exercise native mouse tracking, which performClick bypasses entirely.
        for id in ["appearance.theme.ocean", "appearance.scheme.dark", "appearance.theme.iris"] {
            let suite = "PaneRook-CardMouseClick-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite); ThemeManager.apply() }
            let appearance = SettingsAppearanceView(defaults: defaults) { ThemeManager.apply(defaults: defaults) }
            let card = try XCTUnwrap(descendants(appearance).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id })
            // A plain offscreen window exercises native cell tracking without
            // requiring a visible scroll view's clipping/event-loop lifecycle.
            card.removeFromSuperview()
            card.translatesAutoresizingMaskIntoConstraints = true
            card.frame = NSRect(x: 20, y: 20, width: 180, height: 118)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
            window.contentView = root
            root.addSubview(card)
            let point = id.hasSuffix("iris") ? NSPoint(x: 10, y: 10) : NSPoint(x: card.bounds.midX, y: card.bounds.midY)
            let down = try mouseEvent(.leftMouseDown, card: card, point: point, window: window)
            let up = try mouseEvent(.leftMouseUp, card: card, point: point, window: window)
            NSApp.postEvent(up, atStart: true)
            withExtendedLifetime(appearance) { card.mouseDown(with: down) }
            defer {
                while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
            }
            XCTAssertEqual(card.state, .on)
            if id.contains("scheme") {
                XCTAssertEqual(defaults.integer(forKey: "appearance"), AppColorScheme.dark.rawValue)
                XCTAssertEqual(ThemeManager.colorScheme, .dark)
            } else {
                let theme = id.hasSuffix("ocean") ? AppTheme.ocean : .iris
                XCTAssertEqual(defaults.string(forKey: "appTheme"), theme.rawValue)
                XCTAssertEqual(ThemeManager.theme, theme)
            }
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, card: NSButton, point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: card.convert(point, to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    func testSelectingCurrentAppearanceDoesNotApplyItAgain() throws {
        _ = NSApplication.shared
        let suite = "PaneRook-AppearanceSelection-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var changes = 0
        let view = SettingsAppearanceView(defaults: defaults) { changes += 1 }
        let buttons = descendants(view).compactMap { $0 as? NSButton }
        let system = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.scheme.system" })
        let theme = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "appearance.theme.paneRook" })
        system.performClick(nil)
        theme.performClick(nil)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(buttons.filter { $0.state == .on }.count, 2)
    }
}

private final class AppearancePreferencesHost: PreferencesHost {
    let left = PaneController(label: "Links", directory: FileManager.default.homeDirectoryForCurrentUser)
    let right = PaneController(label: "Rechts", directory: FileManager.default.homeDirectoryForCurrentUser)
    let commandRegistry: CommandRegistry
    var panelReads = 0
    var layoutUpdates = 0
    var highlightUpdates = 0
    var keyBindingUpdates = 0

    init(defaults: UserDefaults) { commandRegistry = CommandRegistry(defaults: defaults) }
    var presentationWindow: NSWindow? { nil }
    var canUseMenus: Bool { true }
    var activePane: any PanelAccess { left }
    var otherPane: any PanelAccess { right }
    var leftPane: any PanelAccess { panelReads += 1; return left }
    var rightPane: any PanelAccess { panelReads += 1; return right }
    func activate(_ pane: any PanelAccess) {}
    func applyLayout(vertical: Bool, functionBar: Bool, toolbar: Bool) { layoutUpdates += 1 }
    func hotkeysChanged() { keyBindingUpdates += 1 }
    func refreshHighlights() { highlightUpdates += 1 }
    func setHiddenFilesVisible(_ visible: Bool) {}
    func remoteSettingsChanged() {}
    func showError(_ error: Error, detail: String) { XCTFail(error.localizedDescription) }
}
