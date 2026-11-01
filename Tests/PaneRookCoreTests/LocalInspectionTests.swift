import XCTest
@testable import PaneRookCore

final class LocalInspectionTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookInspection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func directory(_ name: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @discardableResult private func file(_ name: String, text: String, in base: URL? = nil) throws -> URL {
        let url = (base ?? root).appendingPathComponent(name)
        try Data(text.utf8).write(to: url); return url
    }

    func testTraversalDoesNotFollowSymlinkCycleOrExternalDirectory() throws {
        let scan = try directory("scan"), outside = try directory("outside")
        let nested = try directory("nested", in: scan)
        try file("a.txt", text: "abc", in: scan)
        try file("b.txt", text: "12345", in: nested)
        try file("outside.txt", text: String(repeating: "x", count: 1024), in: outside)
        try fm.createSymbolicLink(at: nested.appendingPathComponent("cycle"), withDestinationURL: scan)
        try fm.createSymbolicLink(at: scan.appendingPathComponent("external"), withDestinationURL: outside)
        let result = try LocalInspection.search(in: scan, query: .init(namePattern: "*.txt"))
        XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)), ["a.txt", "b.txt"])
        XCTAssertEqual(try LocalInspection.byteCount(of: scan), 8)
        XCTAssertEqual(try LocalInspection.byteCount(of: scan.appendingPathComponent("external")), 0)
    }

    func testContentSearchHonorsEncodingReadBoundAndHiddenOption() throws {
        try file("a.txt", text: "Needle trailing tail")
        try file("b.txt", text: "1234567890 Needle")
        try file(".hidden.txt", text: "needle")
        let nested = try directory("nested")
        try file("c.TXT", text: "NEEDLE", in: nested)
        var query = FileSearchQuery(namePattern: "*.txt", content: "needle", maximumContentBytes: 12)
        let result = try LocalInspection.search(in: root, query: query)
        XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)), ["a.txt", "c.TXT"])
        XCTAssertEqual(result.truncatedFiles, 2)
        query.includeHidden = true; query.recursive = false
        XCTAssertEqual(Set(try LocalInspection.search(in: root, query: query).urls.map(\.lastPathComponent)), ["a.txt", ".hidden.txt"])
        let encoded = root.appendingPathComponent("latin.txt")
        try "Grüße".data(using: .isoLatin1)!.write(to: encoded)
        let latin = try LocalInspection.search(in: root, query: .init(namePattern: "latin.txt", content: "Grüße", encoding: .isoLatin1))
        XCTAssertEqual(latin.urls.map(\.lastPathComponent), ["latin.txt"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(latin.urls.first)), try Data(contentsOf: encoded))
    }

    func testSearchLimitsResultsAndTraversal() throws {
        for number in 0..<12 { try file("\(number).txt", text: "data") }
        let result = try LocalInspection.search(in: root, query: .init(maximumResults: 3))
        XCTAssertEqual(result.urls.count, 3); XCTAssertTrue(result.resultLimitReached)
        XCTAssertThrowsError(try LocalInspection.search(in: root, query: .init(namePattern: "does-not-exist", maximumEntries: 2))) {
            XCTAssertEqual($0 as? InspectionError, .entryLimit(2))
        }
    }

    func testCancelledTraversalAndComparisonStopBeforeReading() throws {
        let left = try file("left", text: "left"), right = try file("right", text: "left")
        let token = InspectionCancellation(); token.cancel()
        XCTAssertTrue(token.isCancelled)
        XCTAssertThrowsError(try LocalInspection.search(in: root, query: .init(), cancellation: token)) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
        XCTAssertThrowsError(try LocalInspection.byteCount(of: root, cancellation: token)) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
        XCTAssertThrowsError(try LocalInspection.compareFiles(left, right, cancellation: token)) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
        XCTAssertThrowsError(try LocalInspection.compareDirectories(root, root, cancellation: token)) { XCTAssertEqual($0 as? InspectionError, .cancelled) }
    }

    func testFileComparisonReadsBytesAcrossChunkBoundaryAndDetectsLength() throws {
        let left = try file("a", text: String(repeating: "a", count: 65_540))
        let right = try file("b", text: String(repeating: "a", count: 65_536) + "baaa")
        let different = try LocalInspection.compareFiles(left, right)
        XCTAssertFalse(different.equal); XCTAssertEqual(different.firstDifferentOffset, 65_536)
        try fm.removeItem(at: right); try fm.copyItem(at: left, to: right)
        XCTAssertTrue(try LocalInspection.compareFiles(left, right).equal)
        try Data("a".utf8).write(to: right)
        XCTAssertEqual(try LocalInspection.compareFiles(left, right).firstDifferentOffset, 1)
        XCTAssertThrowsError(try LocalInspection.compareFiles(left, left, maximumBytes: 1)) { XCTAssertEqual($0 as? InspectionError, .fileLimit(1)) }
    }

    func testDirectoryComparisonReportsAddedChangedTypeAndLinkTargets() throws {
        let left = try directory("left"), right = try directory("right")
        try file("same", text: "same", in: left); try file("same", text: "same", in: right)
        try file("changed", text: "ABCD", in: left); try file("changed", text: "ABCE", in: right)
        try file("only-left", text: "", in: left); try file("only-right", text: "", in: right)
        try directory("type", in: left); try file("type", text: "", in: right)
        let ln = try directory("nested", in: left), rn = try directory("nested", in: right)
        try file("deep", text: "one", in: ln); try file("deep", text: "two", in: rn)
        try fm.createSymbolicLink(atPath: left.appendingPathComponent("link").path, withDestinationPath: "same")
        try fm.createSymbolicLink(atPath: right.appendingPathComponent("link").path, withDestinationPath: "changed")
        let comparison = try LocalInspection.compareDirectories(left, right)
        let kinds = Dictionary(uniqueKeysWithValues: comparison.differences.map { ($0.relativePath, $0.kind) })
        XCTAssertNil(kinds["same"])
        XCTAssertEqual(kinds["changed"], .different); XCTAssertEqual(kinds["nested/deep"], .different)
        XCTAssertEqual(kinds["only-left"], .onlyLeft); XCTAssertEqual(kinds["only-right"], .onlyRight)
        XCTAssertEqual(kinds["type"], .differentType); XCTAssertEqual(kinds["link"], .different)
        XCTAssertFalse(try LocalInspection.compareDirectories(left, right, recursive: false).differences.contains { $0.relativePath == "nested/deep" })
    }

    func testFilterRetainsParentAndDirectoriesAndMatchesShellGlob() throws {
        try directory("folder"); try file("one.txt", text: ""); try file("two.png", text: "")
        let entries = [FileEntry.parent(of: root)] + (try FileSystem.list(root, showHidden: true))
        XCTAssertEqual(LocalInspection.filter(entries, pattern: "*.txt").map(\.name), ["..", "folder", "one.txt"])
        XCTAssertEqual(LocalInspection.filter(entries, pattern: "nothing").map(\.name), ["..", "folder"])
        XCTAssertEqual(LocalInspection.filter(entries, pattern: "").count, entries.count)
        XCTAssertTrue(LocalInspection.matches("File02.TXT", pattern: "file[0-9]?.txt", caseSensitive: false))
        XCTAssertFalse(LocalInspection.matches("File02.TXT", pattern: "file*.txt", caseSensitive: true))
    }
}
