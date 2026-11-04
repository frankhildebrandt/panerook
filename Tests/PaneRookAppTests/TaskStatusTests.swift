import AppKit
import PaneRookTasks
import XCTest
@testable import PaneRookApp

final class TaskStatusTests: XCTestCase {
    @MainActor func testRestoredFailedAndInterruptedTransfersRemainActionableWithoutActiveWork() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TransferStore(directory: directory)
        var failed = RecoverableTransfer(title: "Kopieren", moving: false, roots: [
            .init(source: .init("/source/a"), destination: .init("/destination/a"))
        ])
        failed.state = .failed; failed.error = "Kein Speicherplatz"
        var interrupted = RecoverableTransfer(title: "Verschieben", moving: true, roots: [
            .init(source: .init("/source/b"), destination: .init("/destination/b"))
        ])
        interrupted.state = .running // An unfinished transfer is restored as interrupted.
        try store.save(failed); try store.save(interrupted)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: store)
        XCTAssertFalse(tasks.hasActiveTasks)
        XCTAssertEqual(tasks.attentionCount, 2, "A failed resumable transfer must only count once.")
        XCTAssertTrue(tasks.summary.contains("1 fehlgeschlagen"))
        XCTAssertTrue(tasks.summary.contains("2 fortsetzbar"))
    }

    @MainActor func testEmptyTaskCenterHasNeutralPersistentStatus() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: TransferStore(directory: directory))
        XCTAssertFalse(tasks.hasActiveTasks)
        XCTAssertEqual(tasks.attentionCount, 0)
        XCTAssertEqual(tasks.summary, "Keine Aufgaben")
    }
}
