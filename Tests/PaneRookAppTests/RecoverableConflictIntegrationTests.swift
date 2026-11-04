import XCTest
import PaneRookCore
import PaneRookTasks
import PaneRookRemote
@testable import PaneRookApp

final class RecoverableConflictIntegrationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PaneRook-RecoveryConflicts-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func file(_ name: String, _ contents: String = "new") throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
    private func transfer(_ source: String, _ destination: String, moving: Bool = true) -> RecoverableTransfer {
        var record = RecoverableTransfer(title: "Test", moving: moving, roots: [.init(source: .init(root.appendingPathComponent(source).path), destination: .init(root.appendingPathComponent(destination).path))])
        record.allowsConflicts = true
        return record
    }
    private func restored(_ transfer: RecoverableTransfer) throws -> RecoverableTransfer {
        let value = try JSONDecoder().decode(RecoverableTransfer.self, from: JSONEncoder().encode(transfer))
        try value.validate(); return value
    }
    func testMergedMovePersistsSkippedChildrenAndKeepsUnrelatedTargetAndSource() throws {
        try file("source/new"); try file("source/skip"); try file("target/skip", "old"); try file("target/unrelated", "unrelated")
        var record = transfer("source", "target")
        let access = TransferFileAccess()
        access.conflictChoice = { _, actions in actions.contains(.merge) ? .merge : .skip }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("source").path), ["skip"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/skip")), "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/unrelated")), "unrelated")
        record = try restored(record)
        // Resuming must preserve the stored skip without asking or deleting the source.
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(), checkpoint: { _ in })
        XCTAssertEqual(record.entries?.filter { $0.skipped == true }.count, 1)
        let journal = FileOperationJournal(); RecoverableTransferJournal(journal).record(record)
        XCTAssertNil(journal.nextUndo)
    }
    func testNestedKeepBothNamesSurviveManifestRoundTrip() throws {
        try file("source/file.txt"); try file("target/file.txt", "old")
        var record = transfer("source", "target")
        let access = TransferFileAccess()
        access.conflictChoice = { _, actions in actions.contains(.merge) ? .merge : .keepBoth }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        record = try restored(record)
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(), checkpoint: { _ in })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/file.txt")), "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/file (2).txt")), "new")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("source").path))
    }
    func testRenamedRootMoveRetainsSafeUndoAtActualDestination() throws {
        try file("source/new"); try file("target/old", "old")
        var record = transfer("source", "target")
        let access = TransferFileAccess(); access.conflictChoice = { _, _ in .keepBoth }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        record = try restored(record)
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(), checkpoint: { _ in })
        let journal = FileOperationJournal(); RecoverableTransferJournal(journal).record(record)
        XCTAssertNotNil(journal.nextUndo)
        try journal.undo(expectedID: XCTUnwrap(journal.nextUndo).id)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source/new")), "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/old")), "old")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("target (2)").path))
    }
    func testDirectoryReplacementPublishesWholeTreeAndIsExcludedFromUndo() throws {
        try file("source/new"); try file("target/obsolete", "old")
        var record = transfer("source", "target")
        let access = TransferFileAccess(); access.conflictChoice = { _, _ in .replace }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        record = try restored(record)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("source").path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("target").path), ["new"])
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(), checkpoint: { _ in })
        let journal = FileOperationJournal(); RecoverableTransferJournal(journal).record(record)
        XCTAssertNil(journal.nextUndo)
    }
    func testTargetContentsChangedDuringDecisionCannotBeReplaced() throws {
        try file("source/new"); let old = try file("target/old", "old")
        var record = transfer("source", "target", moving: false)
        let access = TransferFileAccess()
        access.conflictChoice = { _, _ in try Data("changed".utf8).write(to: old); return .replace }
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&record, access: access, checkpoint: { _ in }))
        XCTAssertEqual(try String(contentsOf: old), "changed")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("target/new").path))
    }
    func testCancelledReplacementPreservesTargetAndRetryRequiresFreshDecision() throws {
        let source = try file("source", String(repeating: "a", count: 8 * 1024 * 1024))
        let target = try file("target", "old")
        var record = transfer("source", "target")
        let access = TransferFileAccess(); access.conflictChoice = { _, _ in .replace }
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&record, access: access, checkpoint: { _ in }, progress: {
            if $0.currentFileBytes > 0 { access.cancel() }
        }))
        XCTAssertEqual(try String(contentsOf: target), "old")
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        record = try restored(record)
        let retry = TransferFileAccess(); var decisions = 0
        retry.conflictChoice = { _, _ in decisions += 1; return .replace }
        try RecoverableTransferWorker.run(&record, access: retry, checkpoint: { try $0.validate() })
        XCTAssertEqual(decisions, 1)
        XCTAssertEqual(try Data(contentsOf: target).count, 8 * 1024 * 1024)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
    }
    func testSelfMoveKeepBothSurvivesResumeWithoutDeletingOriginal() throws {
        try file("file.txt")
        var record = transfer("file.txt", "file.txt")
        let access = TransferFileAccess(); access.conflictChoice = { _, actions in
            XCTAssertEqual(actions, [.skip, .keepBoth]); return .keepBoth
        }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        record = try restored(record)
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(), checkpoint: { _ in })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file (2).txt")), "new")
    }
    func testManifestCannotRedirectRenamedEntryOutsideItsParent() throws {
        try file("source/new"); try file("target/old")
        var record = transfer("source", "target")
        let access = TransferFileAccess(); access.conflictChoice = { _, _ in .keepBoth }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { _ in })
        record.entries![0].root.destination.path = "/outside/parent"
        XCTAssertThrowsError(try record.validate())
    }
    func testRemoteLinkTargetCanBeSkippedWithoutFollowingIt() throws {
        guard fm.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System-sftp-server fehlt") }
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "test", port: 22, user: "")) { invocation, token in
            var direct = invocation; direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            return try RemoteFileSystem.run(direct, token)
        }
        try file("source"); let referent = try file("referent", "old")
        let target = root.appendingPathComponent("target")
        try fm.createSymbolicLink(at: target, withDestinationURL: referent)
        var record = transfer("source", "target")
        let endpoint = TransferEndpoint(fs.connection); record.roots[0].destination.endpoint = endpoint
        let access = TransferFileAccess(remotes: [endpoint: fs])
        access.conflictChoice = { _, allowed in XCTAssertEqual(allowed, [.skip, .keepBoth]); return .skip }
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { try $0.validate() })
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.path), referent.path)
        XCTAssertEqual(try String(contentsOf: referent), "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("source")), "new")
        XCTAssertEqual(record.entries?.first?.skipped, true)
    }
    func testRemoteReplacementUsesRecoveryManifestAndPreservesSourceUntilCheckpoint() throws {
        guard fm.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System-sftp-server fehlt") }
        let fs = RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: "test", port: 22, user: "")) { invocation, token in
            var direct = invocation; direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            return try RemoteFileSystem.run(direct, token)
        }
        let source = try file("source"), target = try file("target", "old")
        var record = transfer("source", "target")
        let endpoint = TransferEndpoint(fs.connection); record.roots[0].destination.endpoint = endpoint
        let access = TransferFileAccess(remotes: [endpoint: fs]); access.conflictChoice = { _, _ in .replace }
        var savedBeforeRemoval = false
        try RecoverableTransferWorker.run(&record, access: access, checkpoint: { value in
            try value.validate()
            if value.entries?.first?.destination != nil && fm.fileExists(atPath: source.path) { savedBeforeRemoval = true }
        })
        XCTAssertTrue(savedBeforeRemoval)
        XCTAssertEqual(try String(contentsOf: target), "new")
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        record = try restored(record)
        try RecoverableTransferWorker.run(&record, access: TransferFileAccess(remotes: [endpoint: fs]), checkpoint: { _ in })
    }
}
