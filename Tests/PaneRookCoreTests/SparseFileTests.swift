import XCTest
import Darwin
@testable import PaneRookCore

final class SparseFileTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookSparseTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    func testLargeLogicalFileUsesFewPhysicalBlocksAndReadsAsZero() throws {
        let length: Int64 = 1_073_741_824
        let url = try SparseFile.create(named: "disk.img", in: root, logicalSize: length)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_size, length)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
        XCTAssertLessThan(Int64(info.st_blocks) * 512, length / 100)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for offset: UInt64 in [0, UInt64(length / 2), UInt64(length - 64)] {
            try handle.seek(toOffset: offset)
            XCTAssertEqual(try handle.read(upToCount: 64), Data(repeating: 0, count: 64))
        }
        try handle.seek(toOffset: UInt64(length))
        XCTAssertTrue((try handle.read(upToCount: 1) ?? Data()).isEmpty)
    }

    func testZeroLengthIsAllowed() throws {
        let url = try SparseFile.create(named: "empty", in: root, logicalSize: 0)
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testExistingFilesDirectoriesAndDanglingLinksAreNeverOverwritten() throws {
        let file = root.appendingPathComponent("existing")
        let content = Data("keep original contents".utf8)
        try content.write(to: file)
        let directory = root.appendingPathComponent("folder")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("dangling")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "absent-target")
        for name in ["existing", "folder", "dangling"] {
            XCTAssertThrowsError(try SparseFile.create(named: name, in: root, logicalSize: 4096))
        }
        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "absent-target")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("absent-target").path))
    }

    func testExactLocalizedSizesAndIntegerBoundaries() throws {
        XCTAssertEqual(try SparseFile.logicalSize(from: " 1,5 ", unit: .gibibytes), 1_610_612_736)
        XCTAssertEqual(try SparseFile.logicalSize(from: "0.5", unit: .kibibytes), 512)
        XCTAssertEqual(try SparseFile.logicalSize(from: "0001.2500", unit: .mebibytes), 1_310_720)
        XCTAssertEqual(try SparseFile.logicalSize(from: "1", unit: .tebibytes), 1_099_511_627_776)
        XCTAssertEqual(try SparseFile.logicalSize(from: "0,000", unit: .bytes), 0)
        XCTAssertEqual(try SparseFile.logicalSize(from: String(Int64.max), unit: .bytes), Int64.max)
        XCTAssertEqual(try SparseFile.logicalSize(from: "0.0000000000009094947017729282379150390625", unit: .tebibytes), 1)
    }

    func testInvalidAndFractionalByteSizesAreRejectedWithoutRounding() throws {
        let invalid = ["", " ", "-1", "+1", "1e3", "NaN", "Infinity", "1.000,5", "1 024", "1.", ".5", "1GiB", "١", "1\n2", "9223372036854775808", "0.1", "0.9999999999999999999999999999999999999999"]
        for input in invalid {
            XCTAssertThrowsError(try SparseFile.logicalSize(from: input, unit: .bytes), input)
        }
        XCTAssertThrowsError(try SparseFile.logicalSize(from: "8388608", unit: .tebibytes))
        XCTAssertThrowsError(try SparseFile.logicalSize(from: "0.0001", unit: .kibibytes))
        XCTAssertThrowsError(try SparseFile.logicalSize(from: "99999999999999999999999999999999999999999999999", unit: .bytes))
    }

    func testInvalidNamesLocationsAndNegativeLengthsDoNotCreateFiles() throws {
        for name in ["", ".", "..", "nested/file", "with:colon", "nul\0name"] {
            XCTAssertThrowsError(try SparseFile.create(named: name, in: root, logicalSize: 10), name)
        }
        XCTAssertThrowsError(try SparseFile.create(named: "negative", in: root, logicalSize: -1))
        XCTAssertThrowsError(try SparseFile.create(named: "remote", in: URL(string: "sftp://example.invalid/path")!, logicalSize: 10))
        XCTAssertThrowsError(try SparseFile.create(named: "missing", in: root.appendingPathComponent("missing-parent"), logicalSize: 10))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
    }
}
