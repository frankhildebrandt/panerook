import AppKit
import XCTest

@testable import PaneRookApp

final class KeyboardCaptureTests: XCTestCase {
    private func event(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testCaptureAcceptsDialogAndNavigationKeys() throws {
        _ = NSApplication.shared
        let capture = KeyCapture()
        var captured: [UInt16] = []
        capture.onCapture = { captured.append($0.keyCode) }
        for (characters, code) in [("\r", UInt16(36)), ("\u{1b}", 53), ("\t", 48), (" ", 49)] {
            XCTAssertTrue(capture.performKeyEquivalent(with: try event(characters, code: code)))
            XCTAssertEqual(capture.binding?.keyCode, code)
            XCTAssertFalse(capture.stringValue.isEmpty)
        }
        XCTAssertEqual(captured, [36, 53, 48, 49])
    }

    func testCaptureNormalizesModifiersAndIgnoresModifierOnlyEvents() throws {
        _ = NSApplication.shared
        let capture = KeyCapture()
        capture.keyDown(with: try event("q", code: 12, flags: [.command, .shift, .capsLock, .numericPad]))
        let expected: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertEqual(capture.binding?.modifiers, expected.rawValue)
        XCTAssertEqual(capture.stringValue, "⇧⌘Q")
        let previous = capture.binding
        capture.capture(try event("", code: 56, flags: .shift, type: .flagsChanged))
        XCTAssertEqual(capture.binding, previous)
        capture.clear()
        XCTAssertNil(capture.binding)
        XCTAssertEqual(capture.stringValue, "")
    }
}
