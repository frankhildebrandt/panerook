import AppKit
import XCTest

@testable import PaneRookApp

final class SettingsToggleTests: XCTestCase {
    private final class Target: NSObject {
        var calls = 0
        @objc func changed(_ sender: Any?) { calls += 1 }
    }

    private func fixture() -> (NSWindow, SettingsToggle, Target) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        window.contentView = root
        let toggle = SettingsToggle()
        toggle.frame = NSRect(x: 20, y: 20, width: 34, height: 22)
        let target = Target()
        toggle.target = target
        toggle.action = #selector(Target.changed(_:))
        root.addSubview(toggle)
        return (window, toggle, target)
    }

    private func event(_ type: NSEvent.EventType, point: NSPoint, toggle: SettingsToggle, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: toggle.convert(point, to: nil), modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    func testEntireSwitchBoundsTrackMouseAndDisabledSwitchDoesNot() throws {
        let (window, toggle, target) = fixture()
        defer { withExtendedLifetime(target) {} }
        for point in [NSPoint(x: 1, y: 1), NSPoint(x: 17, y: 11), NSPoint(x: 33, y: 21)] {
            let down = try event(.leftMouseDown, point: point, toggle: toggle, window: window)
            XCTAssertTrue(try XCTUnwrap(toggle.cell).hitTest(for: down, in: toggle.bounds, of: toggle).contains(.trackableArea))
        }
        let outside = try event(.leftMouseDown, point: NSPoint(x: -1, y: -1), toggle: toggle, window: window)
        XCTAssertTrue(try XCTUnwrap(toggle.cell).hitTest(for: outside, in: toggle.bounds, of: toggle).isEmpty)
        toggle.isEnabled = false
        let down = try event(.leftMouseDown, point: NSPoint(x: 17, y: 11), toggle: toggle, window: window)
        XCTAssertTrue(try XCTUnwrap(toggle.cell).hitTest(for: down, in: toggle.bounds, of: toggle).isEmpty)
        toggle.performClick(nil)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(target.calls, 0)
    }

    func testSingleNativeMouseClickTogglesStateAndSendsExactlyOneAction() throws {
        let (window, toggle, target) = fixture()
        let point = NSPoint(x: 17, y: 11)
        let down = try event(.leftMouseDown, point: point, toggle: toggle, window: window)
        let up = try event(.leftMouseUp, point: point, toggle: toggle, window: window)
        NSApp.postEvent(up, atStart: true)
        withExtendedLifetime(target) { toggle.mouseDown(with: down) }
        defer {
            while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
        }
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(target.calls, 1)
    }

    func testNativeProgrammaticActivationTogglesBothWays() {
        let (window, toggle, target) = fixture()
        defer { withExtendedLifetime(window) {} }
        toggle.performClick(nil)
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(target.calls, 1)
        toggle.performClick(nil)
        XCTAssertEqual(toggle.state, .off)
        XCTAssertEqual(target.calls, 2)
    }
}
