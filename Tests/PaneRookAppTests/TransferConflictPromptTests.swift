import AppKit
import PaneRookCore
import XCTest
@testable import PaneRookApp

final class TransferConflictPromptTests: XCTestCase {
    @MainActor private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func waitForSheet(_ window: NSWindow) throws -> NSWindow {
        let deadline = Date().addingTimeInterval(3)
        while window.attachedSheet == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return try XCTUnwrap(window.attachedSheet)
    }
    private func fixture() throws -> (URL, TransferConflict) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRookConflictPrompt-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let source = root.appendingPathComponent("source.txt"), destination = root.appendingPathComponent("target.txt")
        try Data("new".utf8).write(to: source); try Data("old".utf8).write(to: destination)
        return (root, try TransferConflict(source: source, destination: destination))
    }
    @MainActor func testNativePromptAppliesRuleToSubsequentConflictInSameJob() throws {
        let (root, conflict) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = window()
        defer { parent.close() }
        let prompt = TransferConflictPrompt(parent: parent)
        let finished = expectation(description: "two decisions from one sheet")
        DispatchQueue.global().async {
            do {
                let first = try prompt.resolve(conflict, cancelled: { false })
                let second = try prompt.resolve(conflict, cancelled: { false })
                XCTAssertEqual(first, .keepBoth)
                XCTAssertEqual(second, .keepBoth)
            } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        let sheet = try waitForSheet(parent)
        defer { if sheet.sheetParent != nil { parent.endSheet(sheet, returnCode: .abort) } }
        let views = descendants(try XCTUnwrap(sheet.contentView))
        let choices = views.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("conflict.") == true }
        XCTAssertEqual(choices.count, 3, "Files offer skip, keep both and replace, without merge.")
        try XCTUnwrap(choices.first { $0.identifier?.rawValue == "conflict.keepBoth" }).performClick(nil)
        let confirm = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "dialog.accept" })
        XCTAssertEqual(confirm.title, "Beide behalten")
        XCTAssertFalse(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("atomare") || $0.stringValue.contains("Bei Archiven") })
        let apply = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Für weitere Konflikte") })
        apply.state = .on
        confirm.performClick(nil)
        wait(for: [finished], timeout: 3)
        XCTAssertNil(parent.attachedSheet)
    }
    @MainActor func testCancellingTaskClosesWaitingConflictAndReleasesWorker() throws {
        let (root, conflict) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = window()
        defer { parent.close() }
        let token = TransferCancellation()
        let prompt = TransferConflictPrompt(parent: parent, onCancel: { token.cancel() })
        let finished = expectation(description: "cancelled worker")
        DispatchQueue.global().async {
            do {
                _ = try prompt.resolve(conflict, cancelled: { token.isCancelled })
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is TransferError) }
            finished.fulfill()
        }
        let sheet = try waitForSheet(parent)
        defer { if sheet.sheetParent != nil { parent.endSheet(sheet, returnCode: .abort) } }
        token.cancel()
        wait(for: [finished], timeout: 3)
        XCTAssertNil(parent.attachedSheet)
    }
}
