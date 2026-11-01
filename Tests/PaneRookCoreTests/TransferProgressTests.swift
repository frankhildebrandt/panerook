import XCTest
import Darwin
@testable import PaneRookCore

final class TransferProgressTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookProgress-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func folder(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    @discardableResult private func file(_ name: String, bytes: Int, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? root).appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        return url
    }

    func testLargeFileReportsBytesBeforeCompletion() throws {
        let source = try file("large", bytes: 32 * 1024 * 1024)
        let target = try folder("target")
        var values: [OperationProgress] = []
        try TransferPlan(sources: [source], destination: target, kind: .copy).execute { values.append($0) }
        XCTAssertTrue(values.contains { $0.totalBytes == nil }, "The size scan has no invented percentage.")
        XCTAssertTrue(values.contains { $0.currentFileBytes > 0 && $0.currentFileBytes < 32 * 1024 * 1024 })
        let last = try XCTUnwrap(values.last)
        XCTAssertEqual(last.completedBytes, 32 * 1024 * 1024)
        XCTAssertEqual(last.totalBytes, last.completedBytes)
        XCTAssertEqual(last.completedItems, 1)
        XCTAssertEqual(last.totalItems, 1)
        let known = values.filter { $0.totalBytes != nil }.map(\.completedBytes)
        XCTAssertEqual(known, known.sorted(), "Aggregate progress cannot move backwards.")
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: target.appendingPathComponent("large")))
    }

    func testRecursiveCopyTotalsDoNotFollowSymlinksAndMetadataSurvives() throws {
        let source = try folder("source")
        let nested = try folder("nested", in: source)
        let one = try file("one", bytes: 17, in: source)
        try file("two", bytes: 23, in: nested)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "../missing")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.posixPermissions: 0o640, .modificationDate: date], ofItemAtPath: one.path)
        let attribute = Data("metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes { setxattr(one.path, "user.panerook-test", $0.baseAddress, $0.count, 0, 0) }, 0)
        let target = try folder("target")
        var last: OperationProgress?
        try TransferPlan(sources: [source], destination: target, kind: .copy).execute { last = $0 }
        XCTAssertEqual(last?.completedBytes, 40)
        XCTAssertEqual(last?.totalBytes, 40)
        XCTAssertEqual(last?.completedItems, 5)
        XCTAssertEqual(last?.totalItems, 5)
        let copied = target.appendingPathComponent("source/one")
        let attributes = try fm.attributesOfItem(atPath: copied.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, date)
        var copiedAttribute = Data(count: 8)
        XCTAssertEqual(copiedAttribute.withUnsafeMutableBytes {
            getxattr(copied.path, "user.panerook-test", $0.baseAddress, $0.count, 0, 0)
        }, 8)
        XCTAssertEqual(copiedAttribute, attribute)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("source/link").path), "../missing")
    }

    func testOverlappingPanelizedSourcesCountEachCopyOccurrence() throws {
        let source = try folder("source")
        let child = try file("child", bytes: 1024 * 1024, in: source)
        let target = try folder("target")
        var reports: [OperationProgress] = []
        try TransferPlan(sources: [source, child], destination: target, kind: .copy).execute { reports.append($0) }
        let last = try XCTUnwrap(reports.last)
        XCTAssertEqual(last.completedBytes, 2 * 1024 * 1024)
        XCTAssertEqual(last.totalBytes, last.completedBytes)
        XCTAssertEqual(last.completedItems, 3)
        XCTAssertEqual(last.totalItems, 3)
        let bytes = reports.filter { $0.totalBytes != nil }.map(\.completedBytes)
        XCTAssertEqual(bytes, bytes.sorted())
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("source/child").path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("child").path))
    }

    func testCancellationInsideAFileRemovesCurrentPartialCopyAndKeepsSource() throws {
        let source = try file("large", bytes: 32 * 1024 * 1024)
        let target = try folder("target")
        let token = TransferCancellation()
        let plan = try TransferPlan(sources: [source], destination: target, kind: .copy)
        XCTAssertThrowsError(try plan.execute(cancellation: token) { value in
            if value.currentFileBytes > 0 { token.cancel() }
        }) { XCTAssertTrue($0 is TransferError) }
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), [])
    }

    func testCancelledMoveNeverTouchesSource() throws {
        let source = try file("source", bytes: 17)
        let target = try folder("target")
        let token = TransferCancellation(); token.cancel()
        let plan = try TransferPlan(sources: [source], destination: target, kind: .move)
        XCTAssertThrowsError(try plan.execute(cancellation: token))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), [])
    }

    func testAtomicMoveReportsCompleteTree() throws {
        let source = try folder("source")
        try file("item", bytes: 61, in: source)
        let target = try folder("target")
        var last: OperationProgress?
        try TransferPlan(sources: [source], destination: target, kind: .move).execute { last = $0 }
        XCTAssertEqual(last?.completedBytes, 61)
        XCTAssertEqual(last?.totalBytes, 61)
        XCTAssertEqual(last?.completedItems, 2)
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("source/item").path))
    }

    func testQueuedDestinationCollisionPreflightsWholeBatchAgain() throws {
        let one = try file("one", bytes: 3), two = try file("two", bytes: 5)
        let target = try folder("target")
        let plan = try TransferPlan(sources: [one, two], destination: target, kind: .move)
        let existing = try file("two", bytes: 7, in: target)
        XCTAssertThrowsError(try plan.execute())
        XCTAssertTrue(fm.fileExists(atPath: one.path))
        XCTAssertTrue(fm.fileExists(atPath: two.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["two"])
        XCTAssertEqual(try Data(contentsOf: existing).count, 7)
    }

    func testQueuedDestinationSymlinkIsRevalidatedBeforeScanning() throws {
        let source = try folder("source"), target = try folder("target")
        try file("item", bytes: 5, in: source)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)
        let plan = try TransferPlan(sources: [source], destination: alias, kind: .copy)
        try fm.removeItem(at: alias)
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try plan.execute()) { error in
            guard case FileActionError.recursiveDestination = error else {
                return XCTFail("Expected recursiveDestination, got \(error)")
            }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.path), ["item"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), [])
    }

    func testCollisionAtCommitKeepsNewDestinationAndRemovesStaging() throws {
        let source = try file("source", bytes: 32 * 1024 * 1024)
        let target = try folder("target")
        let plan = try TransferPlan(sources: [source], destination: target, kind: .copy)
        var wroteCollision = false
        XCTAssertThrowsError(try plan.execute { value in
            if value.currentFileBytes > 0 && !wroteCollision {
                wroteCollision = true
                try! Data("new owner".utf8).write(to: target.appendingPathComponent("source"))
            }
        })
        XCTAssertTrue(wroteCollision)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("source")), "new owner")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.path), ["source"])
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }
}
