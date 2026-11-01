import XCTest
@testable import PaneRookCore

final class FileSystemTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookTests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func folder(_ name: String) throws -> URL { try FileActions.createDirectory(named: name, in: root) }
    @discardableResult private func file(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    func testListingDirectoriesFirstAndNaturalOrder() throws {
        try file("10.txt"); try file("2.txt"); try file(".hidden"); try folder("Z folder")
        XCTAssertEqual(try FileSystem.list(root, showHidden: false).map(\.name), ["Z folder", "2.txt", "10.txt"])
        XCTAssertEqual(try FileSystem.list(root, showHidden: true).count, 4)
    }
    func testCopyAndMovePreserveContents() throws {
        let source = try file("hello.txt")
        let destination = try folder("destination")
        try TransferPlan(sources: [source], destination: destination, kind: .copy).execute()
        let copied = destination.appendingPathComponent("hello.txt")
        XCTAssertEqual(try Data(contentsOf: copied), Data("fixture".utf8))
        XCTAssertTrue(fm.fileExists(atPath: source.path))
        let second = try folder("second")
        try TransferPlan(sources: [copied], destination: second, kind: .move).execute()
        XCTAssertFalse(fm.fileExists(atPath: copied.path))
        XCTAssertTrue(fm.fileExists(atPath: second.appendingPathComponent("hello.txt").path))
    }
    func testCollisionPreflightsEntireBatch() throws {
        let first = try file("first")
        let second = try file("second")
        let target = try folder("target")
        try file("second", in: target)
        XCTAssertThrowsError(try TransferPlan(sources: [first, second], destination: target, kind: .move))
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("first").path))
    }
    func testRecursiveAndSameDirectoryTargetsAreRejected() throws {
        let source = try folder("source")
        let child = try FileActions.createDirectory(named: "child", in: source)
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: child, kind: .copy))
        let file = try file("item")
        XCTAssertThrowsError(try TransferPlan(sources: [file], destination: root, kind: .move))
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: child)
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: alias, kind: .copy))
    }
    func testDanglingDestinationSymlinkIsNotOverwritten() throws {
        let source = try file("item")
        let target = try folder("target")
        let link = target.appendingPathComponent("item")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/does-not-exist-panerook")
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: target, kind: .copy))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "/does-not-exist-panerook")
    }
    func testCopyDirectoryAndSymlink() throws {
        let source = try folder("source")
        try file("nested", in: source)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let target = try folder("target")
        let linkEntry = try XCTUnwrap(FileSystem.list(root, showHidden: true).first { $0.name == "link" })
        XCTAssertTrue(linkEntry.isDirectory)
        XCTAssertTrue(linkEntry.isSymbolicLink)
        try TransferPlan(sources: [source, link], destination: target, kind: .copy).execute()
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("source/nested").path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path), source.path)
    }
    func testInvalidFolderNamesAndRelativePaths() throws {
        for name in ["", " ", ".", "..", "one/two", "one:two"] {
            XCTAssertThrowsError(try FileActions.createDirectory(named: name, in: root))
        }
        let folder = try folder("folder")
        XCTAssertEqual(try FileSystem.directory(from: "folder", relativeTo: root), folder.standardizedFileURL)
        XCTAssertThrowsError(try FileSystem.directory(from: "missing", relativeTo: root))
    }

    func testDialogMaskFiltersSelectionBeforeCopying() throws {
        let text = try file("notes.txt")
        let image = try file("image.png")
        let target = try folder("target")
        let plan = try TransferPlan(sources: [text, image], sourcePattern: "*.txt",
            destinationPath: target.path + "/", relativeTo: root, kind: .copy)
        XCTAssertEqual(plan.items.map(\.source), [text])
        try plan.execute()
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("image.png").path))
    }

    func testDialogCanCopyAndMoveToNewNames() throws {
        let source = try file("original.txt")
        let plan = try TransferPlan(sources: [source], sourcePattern: "*", destinationPath: "renamed.txt", relativeTo: root, kind: .copy)
        try plan.execute()
        let renamed = root.appendingPathComponent("renamed.txt")
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: renamed))
        try TransferPlan(sources: [renamed], sourcePattern: "*", destinationPath: "moved.txt", relativeTo: root, kind: .move).execute()
        XCTAssertFalse(fm.fileExists(atPath: renamed.path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("moved.txt").path))
    }

    func testDialogRejectsInvalidTargetsAndEmptyMatches() throws {
        let first = try file("first")
        let second = try file("second")
        for path in ["", " ", "missing/", "missing/child"] {
            XCTAssertThrowsError(try TransferPlan(sources: [first], sourcePattern: "*", destinationPath: path, relativeTo: root, kind: .copy))
        }
        XCTAssertThrowsError(try TransferPlan(sources: [first, second], sourcePattern: "*", destinationPath: "new-name", relativeTo: root, kind: .copy))
        XCTAssertThrowsError(try TransferPlan(sources: [first], sourcePattern: "*.png", destinationPath: root.path, relativeTo: root, kind: .copy))
        XCTAssertThrowsError(try TransferPlan(sources: [first], sourcePattern: "", destinationPath: root.path, relativeTo: root, kind: .copy))
        XCTAssertThrowsError(try TransferPlan(sources: [first], sourcePattern: "*", destinationPath: second.path, relativeTo: root, kind: .copy))
        XCTAssertEqual(try Data(contentsOf: second), Data("fixture".utf8))
    }

    func testDialogRejectsRecursiveRenameThroughSymlink() throws {
        let source = try folder("source")
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        XCTAssertThrowsError(try TransferPlan(sources: [source], sourcePattern: "*", destinationPath: "alias/nested", relativeTo: root, kind: .copy))
    }
}
