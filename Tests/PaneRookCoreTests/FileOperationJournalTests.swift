import XCTest
import Darwin
@testable import PaneRookCore

final class FileOperationJournalTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookUndo-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    private func file(_ name: String, content: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }
    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func undo(_ journal: FileOperationJournal, token: TransferCancellation = .init()) throws {
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id, cancellation: token)
    }
    private func redo(_ journal: FileOperationJournal) throws {
        try journal.redo(expectedID: XCTUnwrap(journal.nextRedo).id)
    }
    private func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }

    func testRenameRoundTripAndNamesInHistory() throws {
        let source = try file("a"), target = root.appendingPathComponent("b")
        let journal = FileOperationJournal()
        let plan = try TransferPlan(sources: [source], sourcePattern: "*", destinationPath: target.path, relativeTo: root, kind: .move)
        try journal.move(plan, title: "Umbenennen")
        XCTAssertFalse(exists(source)); XCTAssertTrue(exists(target))
        XCTAssertTrue(journal.nextUndo?.description.contains("Umbenennen") == true)
        try undo(journal)
        XCTAssertEqual(try String(contentsOf: source), "original"); XCTAssertFalse(exists(target))
        try redo(journal)
        XCTAssertFalse(exists(source)); XCTAssertTrue(exists(target))
        XCTAssertEqual(journal.history.count, 3)
        XCTAssertTrue(journal.history.first?.paths[0].contains(" → ") == true)
    }

    func testBatchMovePreservesTreeLinksAndMetadata() throws {
        let folder = try directory("tree"), target = try directory("target")
        let child = folder.appendingPathComponent("child")
        try Data("hello".utf8).write(to: child)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: child.path)
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("link").path, withDestinationPath: "../missing")
        let other = try file("other")
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [folder, other], destination: target, kind: .move))
        XCTAssertEqual(journal.nextUndo?.paths.count, 2)
        try undo(journal); try redo(journal); try undo(journal)
        XCTAssertTrue(exists(folder)); XCTAssertTrue(exists(other))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("link").path), "../missing")
        XCTAssertEqual((try fm.attributesOfItem(atPath: child.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testChangedContentEvenWithSameSizeAndRestoredDateRefusesUndo() throws {
        let source = try file("a"), target = try directory("target")
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [source], destination: target, kind: .move))
        let moved = target.appendingPathComponent("a")
        let date = try XCTUnwrap(fm.attributesOfItem(atPath: moved.path)[.modificationDate])
        let handle = try FileHandle(forWritingTo: moved)
        try handle.write(contentsOf: Data("modified".utf8)); try handle.close()
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: moved.path)
        XCTAssertThrowsError(try undo(journal))
        XCTAssertEqual(try String(contentsOf: moved), "modified")
        XCTAssertFalse(exists(source)); XCTAssertNotNil(journal.nextUndo); XCTAssertNil(journal.nextRedo)
    }

    func testReplacedIdentityAndOccupiedDestinationIncludingDanglingLinkAreSafe() throws {
        let source = try file("a"), target = try directory("target")
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [source], destination: target, kind: .move))
        let moved = target.appendingPathComponent("a")
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        XCTAssertThrowsError(try undo(journal))
        XCTAssertTrue(exists(moved)); XCTAssertTrue(exists(source))
        try fm.removeItem(at: source)
        let replacement = try file("replacement")
        try fm.removeItem(at: moved); try fm.moveItem(at: replacement, to: moved)
        XCTAssertThrowsError(try undo(journal))
        XCTAssertFalse(exists(source)); XCTAssertTrue(exists(moved))
    }

    func testCreateFolderUndoOnlyRemovesUnchangedEmptyDirectoryAndRedoChecksCollision() throws {
        let journal = FileOperationJournal()
        try journal.createDirectory(named: "new", in: root)
        let folder = root.appendingPathComponent("new"), child = folder.appendingPathComponent("child")
        try Data("keep".utf8).write(to: child)
        XCTAssertThrowsError(try undo(journal)); XCTAssertTrue(exists(child))
        try fm.removeItem(at: child)
        try undo(journal); XCTAssertFalse(exists(folder))
        try Data("collision".utf8).write(to: folder)
        XCTAssertThrowsError(try redo(journal))
        XCTAssertEqual(try String(contentsOf: folder), "collision")
        try fm.removeItem(at: folder)
        try redo(journal); XCTAssertTrue(exists(folder))
    }

    func testTrashUsesReturnedPathAndRedoTrashesAgain() throws {
        let bin = try directory("bin"), source = try file("a")
        var count = 0
        let journal = FileOperationJournal(trash: { source in
            count += 1
            let output = bin.appendingPathComponent("different-name-\(count)")
            try self.fm.moveItem(at: source, to: output)
            return output
        })
        try journal.trash([source]); XCTAssertFalse(exists(source))
        XCTAssertEqual(journal.nextUndo?.paths, [bin.appendingPathComponent("different-name-1").path])
        try undo(journal); XCTAssertTrue(exists(source))
        try redo(journal); XCTAssertEqual(count, 2); XCTAssertFalse(exists(source))
        try undo(journal); XCTAssertEqual(try String(contentsOf: source), "original")
    }

    func testMissingTrashItemOrMissingVolumeParentDoesNotConsumeHistory() throws {
        let bin = try directory("bin"), source = try file("a")
        let journal = FileOperationJournal(trash: { source in
            let output = bin.appendingPathComponent("a"); try self.fm.moveItem(at: source, to: output); return output
        })
        try journal.trash([source])
        try fm.moveItem(at: bin, to: root.appendingPathComponent("unmounted"))
        XCTAssertThrowsError(try undo(journal)); XCTAssertNotNil(journal.nextUndo)
        try fm.createDirectory(at: bin, withIntermediateDirectories: false)
        try Data("other volume".utf8).write(to: bin.appendingPathComponent("a"))
        XCTAssertThrowsError(try undo(journal)); XCTAssertFalse(exists(source))
    }

    func testPartialTrashFailureJournalsOnlyCompletedItems() throws {
        let bin = try directory("bin"), a = try file("a"), b = try file("b")
        let journal = FileOperationJournal(trash: { source in
            if source == b { throw CocoaError(.fileWriteNoPermission) }
            let output = bin.appendingPathComponent(source.lastPathComponent)
            try self.fm.moveItem(at: source, to: output); return output
        })
        XCTAssertThrowsError(try journal.trash([a, b]))
        XCTAssertEqual(journal.history.last?.completed, 1)
        XCTAssertEqual(journal.history.last?.total, 2)
        XCTAssertEqual(journal.nextUndo?.paths.count, 1)
        try undo(journal); XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b))
    }

    func testPartialUndoKeepsSeparateRetryAndRedoSteps() throws {
        let a = try file("a"), b = try file("b"), target = try directory("target")
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [a, b], destination: target, kind: .move))
        // Undo runs b then a; only a conflicts.
        try Data("collision".utf8).write(to: a)
        XCTAssertThrowsError(try undo(journal))
        XCTAssertTrue(exists(b)); XCTAssertTrue(exists(target.appendingPathComponent("a")))
        XCTAssertEqual(journal.nextUndo?.paths.count, 1); XCTAssertEqual(journal.nextRedo?.paths.count, 1)
        try fm.removeItem(at: a)
        try undo(journal); XCTAssertEqual(try String(contentsOf: a), "original")
        try redo(journal); try redo(journal)
        XCTAssertFalse(exists(a)); XCTAssertFalse(exists(b))
        XCTAssertTrue(exists(target.appendingPathComponent("a"))); XCTAssertTrue(exists(target.appendingPathComponent("b")))
    }

    func testCancellationBetweenItemsKeepsCompletedMoveUndoable() throws {
        let a = try file("a"), b = try file("b"), target = try directory("target")
        let journal = FileOperationJournal(), token = TransferCancellation()
        XCTAssertThrowsError(try journal.move(TransferPlan(sources: [a, b], destination: target, kind: .move), cancellation: token) { progress in
            if !self.exists(a) { token.cancel() }
        })
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(b))
        XCTAssertEqual(journal.nextUndo?.paths.count, 1)
        try undo(journal); XCTAssertTrue(exists(a))
        let cancelled = TransferCancellation(); cancelled.cancel()
        XCTAssertThrowsError(try journal.redo(expectedID: XCTUnwrap(journal.nextRedo).id, cancellation: cancelled))
        XCTAssertTrue(exists(a)); XCTAssertNotNil(journal.nextRedo)
    }

    func testChangedDescendantAndAttributesPreventUndo() throws {
        let source = try directory("tree"), target = try directory("target")
        let child = source.appendingPathComponent("child")
        try Data("original".utf8).write(to: child)
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [source], destination: target, kind: .move))
        let moved = target.appendingPathComponent("tree/child")
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: moved.path)
        XCTAssertThrowsError(try undo(journal))
        XCTAssertTrue(exists(moved)); XCTAssertFalse(exists(source))
    }

    func testNewActionClearsRedoAndStaleQueuedActionIDCannotUndoAnotherAction() throws {
        let journal = FileOperationJournal()
        try journal.createDirectory(named: "first", in: root)
        let old = try XCTUnwrap(journal.nextUndo).id
        try undo(journal)
        try journal.createDirectory(named: "second", in: root)
        XCTAssertNil(journal.nextRedo)
        XCTAssertThrowsError(try journal.undo(expectedID: old))
        XCTAssertTrue(exists(root.appendingPathComponent("second")))
    }

    func testSourceChangedDuringTransferScanIsNotMoved() throws {
        let source = try file("source"), target = try directory("target")
        let journal = FileOperationJournal()
        var changed = false
        XCTAssertThrowsError(try journal.move(TransferPlan(sources: [source], destination: target, kind: .move)) { value in
            if value.totalItems == nil, !changed {
                changed = true
                try! Data("changed during scan".utf8).write(to: source)
            }
        })
        XCTAssertTrue(changed); XCTAssertTrue(exists(source))
        XCTAssertFalse(exists(target.appendingPathComponent("source")))
        XCTAssertNil(journal.nextUndo)
    }

    func testExtendedAttributeChangesAndChangedTrashItemsRefuseRestore() throws {
        let source = try file("source"), bin = try directory("bin")
        let output = bin.appendingPathComponent("trashed")
        let journal = FileOperationJournal(trash: { source in
            try self.fm.moveItem(at: source, to: output); return output
        })
        try journal.trash([source])
        let value = Data("new Finder metadata".utf8)
        XCTAssertEqual(value.withUnsafeBytes { setxattr(output.path, "user.panerook-undo-test", $0.baseAddress, $0.count, 0, 0) }, 0)
        XCTAssertThrowsError(try undo(journal))
        XCTAssertTrue(exists(output)); XCTAssertFalse(exists(source))
        XCTAssertNotNil(journal.history.last?.error)
    }

    func testUndoCancellationAfterOneItemCanBeRetriedWithoutRepeatingIt() throws {
        let a = try file("a"), b = try file("b"), target = try directory("target")
        let journal = FileOperationJournal(), token = TransferCancellation()
        try journal.move(TransferPlan(sources: [a, b], destination: target, kind: .move))
        XCTAssertThrowsError(try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id, cancellation: token) { _ in
            if self.exists(b) { token.cancel() }
        })
        XCTAssertTrue(exists(b)); XCTAssertFalse(exists(a))
        XCTAssertEqual(journal.nextUndo?.paths.count, 1); XCTAssertEqual(journal.nextRedo?.paths.count, 1)
        try undo(journal)
        XCTAssertTrue(exists(a)); XCTAssertTrue(exists(b))
    }

    func testNativeTrashRoundTripWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["PANEROOK_TEST_TRASH"] == "1" else {
            throw XCTSkip("Opt-in: PANEROOK_TEST_TRASH=1 exercises the macOS Trash and restores its test file.")
        }
        let source = try file("PaneRook-native-trash-\(UUID())")
        let journal = FileOperationJournal()
        do { try journal.trash([source]) } catch {
            if let path = journal.nextUndo?.paths.first { try? fm.moveItem(atPath: path, toPath: source.path) }
            throw error
        }
        let trashPath = URL(fileURLWithPath: try XCTUnwrap(journal.nextUndo?.paths.first))
        defer {
            if exists(trashPath) && !exists(source) { try? fm.moveItem(at: trashPath, to: source) }
        }
        XCTAssertFalse(exists(source)); XCTAssertTrue(exists(trashPath))
        try undo(journal)
        XCTAssertEqual(try String(contentsOf: source), "original")
        XCTAssertFalse(exists(trashPath))
    }

    func testCrossVolumeRoundTripWhenVolumeIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PANEROOK_TEST_UNDO_VOLUME"] else {
            throw XCTSkip("Opt-in: PANEROOK_TEST_UNDO_VOLUME names a writable test volume.")
        }
        let volume = URL(fileURLWithPath: path)
        XCTAssertNotEqual(try FileOperationIdentity.read(volume).st_dev, try FileOperationIdentity.read(root).st_dev)
        let target = volume.appendingPathComponent("PaneRookUndo-\(UUID())")
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: target) }
        let source = try directory("tree")
        try Data("cross volume".utf8).write(to: source.appendingPathComponent("child"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "child")
        let journal = FileOperationJournal()
        try journal.move(TransferPlan(sources: [source], destination: target, kind: .move))
        XCTAssertFalse(exists(source))
        try undo(journal)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("child")), "cross volume")
        try redo(journal); try undo(journal)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: source.appendingPathComponent("link").path), "child")
    }

    func testJournalLimitAndNestedFolderActions() throws {
        let journal = FileOperationJournal(limit: 2)
        try journal.createDirectory(named: "a", in: root)
        let a = root.appendingPathComponent("a")
        try journal.createDirectory(named: "b", in: a)
        try undo(journal); try undo(journal)
        XCTAssertFalse(exists(a))
        XCTAssertEqual(journal.history.count, 2)
        try redo(journal); try redo(journal)
        XCTAssertTrue(exists(a.appendingPathComponent("b")))
    }
}
