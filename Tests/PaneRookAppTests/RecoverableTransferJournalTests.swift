import AppKit
import XCTest
import PaneRookCore
import PaneRookTasks
@testable import PaneRookApp

final class RecoverableTransferJournalTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
        for name in ["a", "b"] { try Data(name.utf8).write(to: root.appendingPathComponent("source/" + name)) }
        return root
    }
    private func record(_ root: URL, moving: Bool = true) -> RecoverableTransfer {
        RecoverableTransfer(title: "Verschieben", moving: moving, roots: ["a", "b"].map { name in
            TransferRoot(source: TransferPath(root.appendingPathComponent("source/" + name).path),
                         destination: TransferPath(root.appendingPathComponent("target/" + name).path))
        })
    }

    func testCancelledMoveAndRepeatedResumeJournalEachCompletedRootOnce() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = FileOperationJournal(), bridge = RecoverableTransferJournal(journal), access = TransferFileAccess()
        var transfer = record(root)
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: access, checkpoint: { _ in }, progress: { value in
            if value.totalItems == 2 && value.completedItems == 1 { access.cancel() }
        }))
        bridge.record(transfer)
        XCTAssertEqual(journal.history.count, 1)
        XCTAssertEqual(journal.history.first?.completed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("source/a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source/b").path))
        try RecoverableTransferWorker.run(&transfer, access: TransferFileAccess(), checkpoint: { _ in })
        bridge.record(transfer); bridge.record(transfer)
        XCTAssertEqual(journal.history.count, 2)
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source/b")), "b")
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source/a")), "a")
        bridge.record(transfer)
        XCTAssertNil(journal.nextUndo, "A retried transfer must not re-adopt undone entries")
    }

    func testCompletedDirectoryMoveSupportsCheckedUndoAndRedo() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = FileOperationJournal(), bridge = RecoverableTransferJournal(journal)
        var transfer = RecoverableTransfer(title: "Verschieben", moving: true, roots: [
            .init(source: TransferPath(root.appendingPathComponent("source").path), destination: TransferPath(root.appendingPathComponent("moved").path))])
        try RecoverableTransferWorker.run(&transfer, access: TransferFileAccess(), checkpoint: { _ in })
        bridge.record(transfer)
        XCTAssertNil(journal.history.first?.error)
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source/a")), "a")
        try journal.redo(expectedID: XCTUnwrap(journal.nextRedo).id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("moved/b")), "b")
    }

    func testChangedCompletedDirectoryIsReportedWithoutAdoptingForeignChildren() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = FileOperationJournal(), bridge = RecoverableTransferJournal(journal)
        var transfer = RecoverableTransfer(title: "Verschieben", moving: true, roots: [
            .init(source: TransferPath(root.appendingPathComponent("source").path), destination: TransferPath(root.appendingPathComponent("moved").path))])
        try RecoverableTransferWorker.run(&transfer, access: TransferFileAccess(), checkpoint: { _ in })
        try Data("foreign".utf8).write(to: root.appendingPathComponent("moved/new"))
        bridge.record(transfer)
        XCTAssertNil(journal.nextUndo)
        XCTAssertNotNil(journal.history.first?.error)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("moved/new")), "foreign")
    }

    func testTaskCenterRegistersLiveAndRestoredMovesButDoesNotJournalCopies() throws {
        _ = NSApplication.shared
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root.appendingPathComponent("store")), journal = FileOperationJournal()
        let transfer = record(root)
        try store.save(transfer)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: store, transferJournal: journal)
        tasks.resumeTransfer(transfer.id)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tasks.snapshots.first?.state == .completed }, object: nil)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(journal.history.count, 1)
        XCTAssertEqual(journal.history.first?.completed, 2)
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id)
        let standalone = FileOperationJournal()
        let copied = expectation(description: "copied")
        tasks.submitTransfer(record(root, moving: false), journal: standalone) { copied.fulfill() }
        wait(for: [copied], timeout: 5)
        XCTAssertNil(standalone.nextUndo)
        XCTAssertTrue(standalone.history.isEmpty)
        // Explicit per-transfer journals also work for hosts that do not configure a default journal.
        try FileManager.default.removeItem(at: root.appendingPathComponent("target/a"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("target/b"))
        let other = TaskCenter(parentWindow: { nil }, restoreFocus: {})
        let moved = expectation(description: "moved")
        other.submitTransfer(record(root), journal: standalone) { moved.fulfill() }
        wait(for: [moved], timeout: 5)
        XCTAssertEqual(standalone.nextUndo?.title, "Verschieben")
    }
}
