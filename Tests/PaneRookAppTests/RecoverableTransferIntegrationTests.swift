import AppKit
import XCTest
import PaneRookCore
import PaneRookRemote
import PaneRookTasks
@testable import PaneRookApp

final class RecoverableTransferIntegrationTests: XCTestCase {
    private final class Faults: RecoverableTransferAccess {
        let base: TransferFileAccess
        var failName: String?
        var copied: [String] = []
        init(_ base: TransferFileAccess) { self.base = base }
        func checkCancellation() throws { try base.checkCancellation() }
        func fingerprint(_ path: TransferPath) throws -> TransferFingerprint? { try base.fingerprint(path) }
        func children(_ path: TransferPath) throws -> [String] { try base.children(path) }
        func createDirectory(_ path: TransferPath) throws { try base.createDirectory(path) }
        func copyFile(from: TransferPath, to: TransferPath, progress: @escaping (OperationProgress) -> Void) throws {
            if (from.path as NSString).lastPathComponent == failName { throw CocoaError(.fileReadNoPermission) }
            try base.copyFile(from: from, to: to, progress: progress); copied.append(from.path)
        }
        func finishDirectory(from: TransferPath, to: TransferPath) throws { try base.finishDirectory(from: from, to: to) }
        func remove(_ path: TransferPath, directory: Bool) throws { try base.remove(path, directory: directory) }
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source"), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: root.appendingPathComponent("source/a"))
        try Data("second".utf8).write(to: root.appendingPathComponent("source/b"))
        return root
    }
    private func record(_ root: URL, moving: Bool = false) -> RecoverableTransfer {
        .init(title: "Test", moving: moving, roots: [.init(source: .init(root.appendingPathComponent("source").path), destination: .init(root.appendingPathComponent("target").path))])
    }
    func testLocalDirectoryRestartSkipsCompletedFileAndDetectsSameSizeTargetChange() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root.appendingPathComponent("store")), fs = Faults(TransferFileAccess())
        fs.failName = "b"; var transfer = record(root)
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: store.save))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/a")), "first")
        var restored = try XCTUnwrap(store.load().first)
        fs.failName = nil
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        XCTAssertEqual(fs.copied.map { ($0 as NSString).lastPathComponent }, ["a", "b"])
        let a = root.appendingPathComponent("target/a")
        let oldDate = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate]!
        let handle = try FileHandle(forWritingTo: a)
        try handle.write(contentsOf: Data("other".utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: a.path)
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save))
        XCTAssertEqual(fs.copied.count, 2)
    }
    func testLocalMoveKeepsNewChildrenAndFinishesAfterTheyAreMovedAside() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let fs = Faults(TransferFileAccess()); fs.failName = "b"; var transfer = record(root, moving: true)
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        let extra = root.appendingPathComponent("source/new")
        try Data("keep".utf8).write(to: extra)
        fs.failName = nil
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        XCTAssertEqual(try String(contentsOf: extra), "keep")
        try FileManager.default.moveItem(at: extra, to: root.appendingPathComponent("keep"))
        try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("source").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/b")), "second")
    }
    func testCancellationCleansCurrentLocalStagingAndResumeRetriesWholeFile() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("source/large")
        try Data(repeating: 8, count: 8 * 1024 * 1024).write(to: large)
        var transfer = RecoverableTransfer(title: "Cancel", moving: false, roots: [.init(source: .init(large.path), destination: .init(root.appendingPathComponent("large").path))])
        let access = TransferFileAccess()
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: access, checkpoint: { _ in }, progress: { value in
            if value.currentFileBytes > 0 { access.cancel() }
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("large").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".panerook-transfer-") })
        try RecoverableTransferWorker.run(&transfer, access: TransferFileAccess(), checkpoint: { _ in })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("large")), try Data(contentsOf: large))
    }
    private func server(_ name: String) throws -> RemoteFileSystem {
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/sftp-server") else { throw XCTSkip("System-sftp-server fehlt") }
        return RemoteFileSystem(connection: try RemoteConnection(kind: .sftp, host: name, port: 22, user: "")) { invocation, token in
            var direct = invocation
            direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            return try RemoteFileSystem.run(direct, token)
        }
    }
    func testRemoteUploadRestartRetryAndChangedDestination() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try server("one.test"), endpoint = TransferEndpoint(server.connection)
        let fs = Faults(TransferFileAccess(remotes: [endpoint: server])); fs.failName = "b"
        var transfer = record(root)
        transfer.roots[0].destination.endpoint = endpoint
        let store = TransferStore(directory: root.appendingPathComponent("store"))
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: store.save))
        var restored = try XCTUnwrap(TransferStore(directory: root.appendingPathComponent("store")).load().first)
        fs.failName = nil
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        XCTAssertEqual(fs.copied.count, 2)
        try Data("remote change".utf8).write(to: root.appendingPathComponent("target/a"))
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save))
    }
    func testRemoteDownloadAndRemoteToRemoteMove() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try server("first.test"), second = try server("second.test")
        let from = TransferEndpoint(first.connection), to = TransferEndpoint(second.connection)
        let access = TransferFileAccess(remotes: [from: first, to: second])
        var download = record(root); download.roots[0].source.endpoint = from
        try RecoverableTransferWorker.run(&download, access: access, checkpoint: { _ in })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/a")), "first")
        var move = record(root, moving: true); move.roots[0].source.endpoint = from
        move.roots[0].destination = .init(root.appendingPathComponent("remoteTarget").path, endpoint: to)
        do { try RecoverableTransferWorker.run(&move, access: access, checkpoint: { _ in }) } catch { XCTFail(move.detail); throw error }
        do { try RecoverableTransferWorker.run(&move, access: access, checkpoint: { _ in }) } catch { XCTFail(move.detail); throw error }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("source").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("remoteTarget/b")), "second")
    }
    func testCancelledRemoteUploadKeepsSourceAndRequiresPartialTargetReview() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("cancelled.txt")
        let original = try server("cancel.test")
        let endpoint = TransferEndpoint(original.connection)
        let interrupted = RemoteFileSystem(connection: original.connection) { invocation, token in
            if String(data: invocation.input ?? Data(), encoding: .utf8)?.contains("@put ") == true {
                try Data("partial".utf8).write(to: target)
                token.cancel(); throw RemoteError.cancelled
            }
            var direct = invocation
            direct.arguments = ["-D", "/usr/libexec/sftp-server", "-q", "-b", "-", "test"]
            return try RemoteFileSystem.run(direct, token)
        }
        let source = root.appendingPathComponent("source/a")
        var transfer = RecoverableTransfer(title: "Cancelled upload", moving: true, roots: [.init(source: .init(source.path), destination: .init(target.path, endpoint: endpoint))])
        let store = TransferStore(directory: root.appendingPathComponent("store"))
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: TransferFileAccess(remotes: [endpoint: interrupted]), checkpoint: store.save))
        XCTAssertEqual(try String(contentsOf: source), "first")
        XCTAssertEqual(try String(contentsOf: target), "partial")
        var restored = try XCTUnwrap(store.load().first)
        let resumed = TransferFileAccess(remotes: [endpoint: original])
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&restored, access: resumed, checkpoint: store.save))
        XCTAssertEqual(try String(contentsOf: target), "partial")
        try FileManager.default.removeItem(at: target)
        try RecoverableTransferWorker.run(&restored, access: resumed, checkpoint: store.save)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target), "first")
    }
    func testTaskCenterRestoresWithoutExecutingAndResumesWithSameID() throws {
        _ = NSApplication.shared
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root.appendingPathComponent("store"))
        var transfer = record(root); transfer.state = .running
        try store.save(transfer)
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: store)
        XCTAssertFalse(tasks.hasActiveTasks)
        XCTAssertEqual(tasks.snapshots.first?.id, transfer.id)
        XCTAssertEqual(tasks.snapshots.first?.canResume, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("target").path))
        tasks.resumeTransfer(transfer.id)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tasks.snapshots.first?.state == .completed }, object: nil)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(tasks.snapshots.count, 1)
        XCTAssertEqual(tasks.snapshots.first?.id, transfer.id)
        XCTAssertEqual(try store.load().first?.state, .completed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("target/b")), "second")
    }
    func testRetryDoesNotReplayOriginalPanelCompletion() throws {
        _ = NSApplication.shared
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: false)
        let store = TransferStore(directory: root.appendingPathComponent("store"))
        var originalCallbacks = 0, retryRefreshes = 0
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: store,
                               restoredTransferCompletion: { retryRefreshes += 1 })
        let transfer = record(root)
        XCTAssertEqual(tasks.submitTransfer(transfer) { originalCallbacks += 1 }, transfer.id)
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tasks.snapshots.first?.state == .failed && originalCallbacks == 1 }, object: nil)
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(originalCallbacks, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("target"))
        tasks.resumeTransfer(transfer.id)
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tasks.snapshots.first?.state == .completed && retryRefreshes == 1 }, object: nil)
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(originalCallbacks, 1)
        XCTAssertEqual(retryRefreshes, 1)
    }
    func testQueuedCancellationIsPersistedWithoutRunningTransfer() throws {
        _ = NSApplication.shared
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root.appendingPathComponent("store"))
        let tasks = TaskCenter(parentWindow: { nil }, restoreFocus: {}, transferStore: store)
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockerDone = expectation(description: "blocker finishes")
        tasks.submit(title: "Blocker", work: { _ in started.signal(); release.wait() }, completion: { _ in blockerDone.fulfill() })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let transfer = record(root)
        let cancelled = expectation(description: "queued cancellation")
        tasks.submitTransfer(transfer) { cancelled.fulfill() }
        tasks.cancel(transfer.id)
        wait(for: [cancelled], timeout: 3)
        XCTAssertEqual(try store.load().first?.state, .cancelled)
        XCTAssertNil(try store.load().first?.entries)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("target").path))
        release.signal(); wait(for: [blockerDone], timeout: 3)
    }
    func testPasswordsAreRedactedFromPersistedTransferErrors() throws {
        let connection = try RemoteConnection(kind: .ftp, host: "host.test", port: 21, user: "test", password: "very-secret")
        let fs = RemoteFileSystem(connection: connection)
        let access = TransferFileAccess(remotes: [TransferEndpoint(connection): fs])
        var transfer = RecoverableTransfer(title: "Test", moving: false, roots: [.init(source: .init("/source"), destination: .init("/dest"))])
        transfer.error = "Server echoed very-secret"
        let data = try JSONEncoder().encode(access.sanitized(transfer))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("very-secret"))
    }

}
