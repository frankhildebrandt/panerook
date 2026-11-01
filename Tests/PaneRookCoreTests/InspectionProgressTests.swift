import XCTest
@testable import PaneRookCore

final class InspectionProgressTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookInspectionProgress-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    func testFileComparisonReportsMeasuredChunksAndCancelsDuringRead() throws {
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        let data = Data(repeating: 42, count: 262_144)
        try data.write(to: left); try data.write(to: right)
        var updates: [OperationProgress] = []
        XCTAssertTrue(try LocalInspection.compareFiles(left, right, progress: { updates.append($0) }).equal)
        XCTAssertEqual(updates.last?.completedBytes, Int64(data.count))
        XCTAssertTrue(updates.contains { $0.completedBytes > 0 && $0.completedBytes < Int64(data.count) })
        XCTAssertTrue(updates.allSatisfy { $0.totalBytes == Int64(data.count) })

        let token = InspectionCancellation()
        XCTAssertThrowsError(try LocalInspection.compareFiles(left, right, cancellation: token) { progress in
            if progress.completedBytes >= 65_536 { token.cancel() }
        }) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
    }

    func testSearchLeavesTotalUnknownUntilTraversalFinishes() throws {
        for index in 0..<4 { try Data("sample".utf8).write(to: root.appendingPathComponent("\(index).txt")) }
        var updates: [OperationProgress] = []
        let result = try LocalInspection.search(in: root, query: .init(), progress: { updates.append($0) })
        XCTAssertEqual(result.urls.count, 4)
        XCTAssertTrue(updates.dropLast().allSatisfy { $0.totalItems == nil && $0.totalBytes == nil })
        XCTAssertEqual(updates.last?.completedItems, 4)
        XCTAssertEqual(updates.last?.totalItems, 4)
    }

    func testDirectoryComparisonReportsKnownInventoryAndFileProgress() throws {
        let left = root.appendingPathComponent("left"), right = root.appendingPathComponent("right")
        for directory in [left, right] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(repeating: 42, count: 131_072).write(to: directory.appendingPathComponent("same"))
            try fm.createDirectory(at: directory.appendingPathComponent("empty"), withIntermediateDirectories: false)
        }
        try Data().write(to: right.appendingPathComponent("only-right"))
        var updates: [OperationProgress] = []
        let comparison = try LocalInspection.compareDirectories(left, right, progress: { updates.append($0) })
        XCTAssertEqual(comparison.differences.count, 1)
        XCTAssertEqual(updates.last?.completedItems, 3)
        XCTAssertEqual(updates.last?.totalItems, 3)
        XCTAssertTrue(updates.contains { $0.totalItems == 3 && $0.currentFileBytes == 65_536 && $0.currentFileTotalBytes == 131_072 })
    }

    func testDirectorySizeReportsVisitedEntriesAndCancelsFromProgress() throws {
        for index in 0..<4 { try Data(repeating: 1, count: 10).write(to: root.appendingPathComponent("\(index)")) }
        var updates: [OperationProgress] = []
        XCTAssertEqual(try LocalInspection.byteCount(of: root, progress: { updates.append($0) }), 40)
        XCTAssertEqual(updates.last?.completedItems, 4)
        XCTAssertEqual(updates.last?.completedBytes, 40)
        let token = InspectionCancellation()
        XCTAssertThrowsError(try LocalInspection.byteCount(of: root, cancellation: token) { progress in
            if progress.completedItems == 1 { token.cancel() }
        }) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
    }
}
