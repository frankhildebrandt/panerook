import XCTest
@testable import PaneRookTasks

final class RecoverableTransferTests: XCTestCase {
    private final class Files: RecoverableTransferAccess {
        var values: [String: TransferFingerprint] = ["/": .init(kind: .directory),
            "/source": .init(kind: .directory), "/source/a": .init(kind: .file, size: 1, digest: "a"),
            "/source/b": .init(kind: .file, size: 1, digest: "b")]
        var failures = Set<String>()
        var copies: [String] = []
        var cancelled = false
        var afterCopy: (() -> Void)?
        func checkCancellation() throws { if cancelled { throw BackgroundTaskError.cancelled } }
        func fingerprint(_ path: TransferPath) throws -> TransferFingerprint? { values[path.path] }
        func children(_ path: TransferPath) throws -> [String] {
            values.keys.filter { ($0 as NSString).deletingLastPathComponent == path.path }.map { ($0 as NSString).lastPathComponent }
        }
        func createDirectory(_ path: TransferPath) throws { values[path.path] = .init(kind: .directory) }
        func copyFile(from: TransferPath, to: TransferPath, progress: @escaping (OperationProgress) -> Void) throws {
            if failures.contains(from.path) { throw RecoverableTransferError.changed(from.path) }
            copies.append(from.path); values[to.path] = values[from.path]; afterCopy?()
        }
        func remove(_ path: TransferPath, directory: Bool) throws { values.removeValue(forKey: path.path) }
    }
    private func record(moving: Bool = false) -> RecoverableTransfer {
        RecoverableTransfer(title: "Test", moving: moving, roots: [.init(source: .init("/source"), destination: .init("/target"))])
    }
    func testPartialFailureRestartAndRepeatedResumeOnlyCopyFailedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root), fs = Files()
        var transfer = record(); fs.failures = ["/source/b"]
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: store.save))
        XCTAssertEqual(fs.copies, ["/source/a"])
        XCTAssertEqual(transfer.entries?.filter { $0.error != nil }.count, 1)
        var restored = try XCTUnwrap(TransferStore(directory: root).load().first)
        fs.failures = []
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        try RecoverableTransferWorker.run(&restored, access: fs, checkpoint: store.save)
        XCTAssertEqual(fs.copies, ["/source/a", "/source/b"])
        XCTAssertTrue(restored.entries!.allSatisfy { $0.error == nil })
    }
    func testChangedCompletedTargetBlocksBeforeAnyMoreWrites() throws {
        let fs = Files(); var transfer = record(); fs.failures = ["/source/b"]
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        fs.failures = []; fs.values["/target/a"]?.digest = "changed"
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        XCTAssertEqual(fs.copies, ["/source/a"])
        XCTAssertNotNil(transfer.entries?.first { $0.root.destination.path == "/target/a" }?.error)
    }
    func testChangedSourceAndUnknownPartialTargetAreNeverOverwritten() throws {
        let fs = Files(); var transfer = record(); fs.failures = ["/source/b"]
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        fs.failures = []; fs.values["/source/b"]?.digest = "changed"
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        fs.values["/source/b"]?.digest = "b"; fs.values["/target/b"] = .init(kind: .file, size: 1, digest: "partial")
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        XCTAssertEqual(fs.values["/target/b"]?.digest, "partial")
        XCTAssertEqual(fs.copies, ["/source/a"])
    }
    func testMoveCopyCheckpointSurvivesCancellationAndSourceRemovalCrash() throws {
        let fs = Files(); var transfer = record(moving: true)
        fs.afterCopy = { fs.cancelled = true }
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in }))
        XCTAssertNotNil(fs.values["/source/a"])
        fs.cancelled = false; fs.afterCopy = nil
        // Copy checkpoint exists; simulates unlink completing immediately before process death.
        fs.values.removeValue(forKey: "/source/a")
        try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in })
        XCTAssertNil(fs.values["/source"])
        XCTAssertTrue(transfer.entries!.allSatisfy(\.sourceRemoved))
        try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { _ in })
        XCTAssertEqual(fs.copies, ["/source/a", "/source/b"])
    }
    func testCheckpointFailureStopsBeforeSourceDeletionAndLaterFiles() throws {
        let fs = Files(); var transfer = record(moving: true)
        XCTAssertThrowsError(try RecoverableTransferWorker.run(&transfer, access: fs, checkpoint: { value in
            if value.entries?.contains(where: { $0.root.destination.path == "/target/a" && $0.destination != nil }) == true {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }))
        XCTAssertNotNil(fs.values["/source/a"])
        XCTAssertEqual(fs.copies, ["/source/a"])
    }
    func testRestoredQueueIsInactiveAndGenericTasksAreNotRestored() throws {
        let queue = BackgroundTaskQueue(); var transfer = record(); transfer.state = .running
        queue.restoreTransfer(transfer)
        XCTAssertEqual(queue.snapshots.first?.state, .interrupted)
        XCTAssertEqual(queue.snapshots.first?.canResume, true)
        XCTAssertFalse(queue.snapshots.first!.state.isActive)
        queue.clearFinished(); XCTAssertEqual(queue.snapshots.count, 1)
        let done = expectation(description: "resume")
        queue.submit(id: transfer.id, recoverable: true, title: "Resume", work: { _ in }, completion: { _ in done.fulfill() })
        wait(for: [done], timeout: 3)
        XCTAssertEqual(queue.snapshots.count, 1)
        XCTAssertEqual(queue.snapshots.first?.state, .completed)
        XCTAssertEqual(queue.snapshots.first?.canResume, false)
        queue.clearFinished(); XCTAssertTrue(queue.snapshots.isEmpty)
    }
    func testStorePermissionsNoCredentialsAndInvalidDocumentIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TransferStore(directory: root); let transfer = record()
        try store.save(transfer)
        let url = root.appendingPathComponent(transfer.id.uuidString + ".json")
        let data = try String(contentsOf: url)
        XCTAssertFalse(data.contains("password")); XCTAssertFalse(data.contains("closure"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("invalid".utf8).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try String(contentsOf: url), "invalid")
    }
}
