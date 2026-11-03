import Foundation
import XCTest
@testable import PaneRookCore

final class BatchRenameTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BatchRename-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    @discardableResult private func file(_ name: String, content: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((content ?? name).utf8).write(to: url)
        return url
    }
    private func capture(_ names: [String]) throws -> [BatchRenameSource] {
        try names.map { try BatchRenameSource(url: root.appendingPathComponent($0)) }
    }
    private func contents(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name)) }
    private func assertClean(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".panerook-rename-") }, file: file, line: line)
    }

    func testCombinedRulesArePureAndPreserveExtension() throws {
        try file("IMG_ÄBC.JPG"); try file("IMG_DEF.JPG")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
        var rules = BatchRenameRules()
        rules.search = #"^IMG_(.*)$"#; rules.replacement = "$1"; rules.regularExpression = true
        rules.letterCase = .lowercase; rules.prefix = "{date}_{n}_"; rules.suffix = "_fertig"
        rules.numberStart = 7; rules.numberStep = 3; rules.numberDigits = 2
        let sources = try capture(["IMG_ÄBC.JPG", "IMG_DEF.JPG"])
        let names = try rules.names(for: sources, referenceDate: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(names, ["1970-01-01_07_äbc_fertig.JPG", "1970-01-01_10_def_fertig.JPG"])
        _ = try BatchRenamePlan(sources: sources, names: names)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set(before))
        XCTAssertEqual(try contents("IMG_ÄBC.JPG"), "IMG_ÄBC.JPG")
    }
    func testLiteralReplacementDotfilesDirectoriesAndExtensionOption() throws {
        try file("a$1.TXT"); try file(".hidden")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir.ext"), withIntermediateDirectories: false)
        var rules = BatchRenameRules(); rules.search = "$1"; rules.replacement = "\\$2"
        XCTAssertEqual(try rules.names(for: capture(["a$1.TXT"])), ["a\\$2.TXT"])
        rules = .init(); rules.letterCase = .uppercase
        XCTAssertEqual(try rules.names(for: capture([".hidden", "dir.ext"])), [".HIDDEN", "DIR.EXT"])
        rules.includeExtension = true
        XCTAssertEqual(try rules.names(for: capture(["a$1.TXT"])), ["A$1.TXT"])
        rules = .init(); rules.search = "TXT"; rules.replacement = "bin"; rules.caseSensitive = false
        XCTAssertEqual(try rules.names(for: capture(["a$1.TXT"])), ["a$1.TXT"])
        rules.includeExtension = true
        XCTAssertEqual(try rules.names(for: capture(["a$1.TXT"])), ["a$1.bin"])
    }
    func testDatesAndNumberingBounds() throws {
        let url = try file("a")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 86400)], ofItemAtPath: url.path)
        let sources = try capture(["a"])
        var rules = BatchRenameRules(); rules.prefix = "{date}_{n}_"; rules.dateSource = .modified
        rules.numberStart = -4; rules.numberDigits = 2
        XCTAssertEqual(try rules.names(for: sources, timeZone: TimeZone(secondsFromGMT: 0)!), ["1970-01-02_-04_a"])
        rules.dateSource = .created; rules.dateFormat = "yyyy"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy"
        XCTAssertEqual(try rules.names(for: sources), [formatter.string(from: sources[0].created) + "_-04_a"])
        rules.numberStart = Int.max; rules.numberStep = 1
        XCTAssertThrowsError(try rules.names(for: sources + sources))
        rules.numberDigits = 100
        XCTAssertThrowsError(try rules.names(for: sources))
        rules = .init(); rules.search = "["; rules.regularExpression = true
        XCTAssertThrowsError(try rules.names(for: sources))
    }
    func testInvalidNamesAndInternalCollisions() throws {
        try file("a"); try file("b")
        let sources = try capture(["a", "b"])
        for name in ["", " ", ".", "..", "x/y", "x:y", "x\0y", String(repeating: "x", count: 300)] {
            XCTAssertThrowsError(try BatchRenamePlan(sources: sources, names: [name, "other"]), name)
        }
        XCTAssertThrowsError(try BatchRenamePlan(sources: sources, names: ["same", "same"]))
        XCTAssertThrowsError(try BatchRenamePlan(sources: sources, names: ["b", "b"]))
        XCTAssertThrowsError(try BatchRenamePlan(sources: [sources[0], sources[0]], names: ["x", "y"]))
        try assertClean()
    }
    func testExistingTargetAndDanglingSymlinkAreNotOverwritten() throws {
        try file("a"); try file("occupied")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
        for name in ["occupied", "dangling"] {
            XCTAssertThrowsError(try BatchRenamePlan(sources: capture(["a"]), names: [name]))
        }
        XCTAssertEqual(try contents("occupied"), "occupied")
    }
    func testSwapCycleAndUnchangedEntryKeepAllContents() throws {
        for name in ["a", "b", "c", "keep"] { try file(name) }
        let plan = try BatchRenamePlan(sources: capture(["a", "b", "c", "keep"]), names: ["b", "c", "a", "keep"])
        XCTAssertEqual(plan.changedItems.count, 3)
        var last = 0
        try plan.execute { progress in last = progress.completedItems }
        XCTAssertEqual(last, 6)
        XCTAssertEqual(try contents("b"), "a"); XCTAssertEqual(try contents("c"), "b"); XCTAssertEqual(try contents("a"), "c")
        XCTAssertEqual(try contents("keep"), "keep"); try assertClean()
    }
    func testCaseOnlyRename() throws {
        try file("mixed.txt")
        try BatchRenamePlan(sources: capture(["mixed.txt"]), names: ["MIXED.txt"]).execute()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("MIXED.txt"))
        XCTAssertEqual(try contents("MIXED.txt"), "mixed.txt"); try assertClean()
    }
    func testCaseCollisionsRespectActualVolume() throws {
        try file("a"); try file("b")
        let sensitive = (try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == true
        if sensitive { _ = try BatchRenamePlan(sources: capture(["a", "b"]), names: ["X", "x"]) }
        else { XCTAssertThrowsError(try BatchRenamePlan(sources: capture(["a", "b"]), names: ["X", "x"])) }
    }
    func testDanglingSymlinkAndDirectoryAreRenamedAsEntries() throws {
        let dir = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: dir.appendingPathComponent("nested"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "missing")
        try BatchRenamePlan(sources: capture(["folder", "link"]), names: ["renamed", "new-link"]).execute()
        XCTAssertEqual(try contents("renamed/nested"), "nested")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("new-link").path), "missing")
        try assertClean()
    }
    func testHardlinksAreDistinctNamesAndExistingHardlinkIsCollision() throws {
        let a = try file("a")
        try FileManager.default.linkItem(at: a, to: root.appendingPathComponent("b"))
        XCTAssertThrowsError(try BatchRenamePlan(sources: capture(["a"]), names: ["b"]))
        try BatchRenamePlan(sources: capture(["a", "b"]), names: ["b", "a"]).execute()
        XCTAssertEqual(try contents("a"), "a"); XCTAssertEqual(try contents("b"), "a"); try assertClean()
    }
    func testNestedSelectionsAndNonLocalSourcesAreRejected() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try file("dir/child")
        XCTAssertThrowsError(try BatchRenamePlan(sources: capture(["dir", "dir/child"]), names: ["renamed", "new"]))
        XCTAssertThrowsError(try BatchRenameSource(url: URL(string: "sftp://example.com/a")!))
        XCTAssertThrowsError(try BatchRenameSource(url: URL(fileURLWithPath: "/")))
    }
    func testChangedSourceAndNewTargetAreRevalidatedBeforeExecution() throws {
        try file("a"); try file("b")
        let plan = try BatchRenamePlan(sources: capture(["a", "b"]), names: ["x", "y"])
        try file("y", content: "outsider")
        XCTAssertThrowsError(try plan.execute())
        XCTAssertEqual(try contents("a"), "a"); XCTAssertEqual(try contents("y"), "outsider")
        try FileManager.default.removeItem(at: root.appendingPathComponent("y"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("b"), to: root.appendingPathComponent("original-b"))
        try file("b", content: "replacement")
        XCTAssertThrowsError(try plan.execute())
        XCTAssertEqual(try contents("b"), "replacement"); try assertClean()
    }
    func testCancellationDuringStagingAndPublishingRestoresCycle() throws {
        for stop in [1, 3, 4, 5, 6] {
            for name in ["a", "b", "c"] { try file(name) }
            let plan = try BatchRenamePlan(sources: capture(["a", "b", "c"]), names: ["b", "c", "a"])
            let token = TransferCancellation()
            XCTAssertThrowsError(try plan.execute(cancellation: token) { if $0.completedItems == stop { token.cancel() } }) { error in
                XCTAssertTrue(error.localizedDescription.contains("zurückgesetzt"))
            }
            for name in ["a", "b", "c"] { XCTAssertEqual(try contents(name), name) }
            try assertClean()
        }
    }
    func testRuntimeTargetRaceRollsBackWithoutOverwriting() throws {
        try file("a"); try file("b")
        let plan = try BatchRenamePlan(sources: capture(["a", "b"]), names: ["x", "y"])
        XCTAssertThrowsError(try plan.execute { progress in
            if progress.completedItems == 3 { try! self.file("y", content: "outsider") }
        })
        XCTAssertEqual(try contents("a"), "a"); XCTAssertEqual(try contents("b"), "b")
        XCTAssertEqual(try contents("y"), "outsider"); try assertClean()
    }
    func testRollbackConflictPreservesDataAndReportsRecoveryPath() throws {
        try file("a"); try file("b")
        let plan = try BatchRenamePlan(sources: capture(["a", "b"]), names: ["x", "y"])
        let token = TransferCancellation()
        var description = ""
        XCTAssertThrowsError(try plan.execute(cancellation: token) { progress in
            if progress.completedItems == 1 {
                try! self.file("a", content: "outsider"); token.cancel()
            }
        }) { description = $0.localizedDescription }
        XCTAssertTrue(description.contains("Teilweise umbenannt")); XCTAssertTrue(description.contains(".panerook-rename-"))
        XCTAssertEqual(try contents("a"), "outsider"); XCTAssertEqual(try contents("b"), "b")
        let container = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".panerook-rename-") })
        XCTAssertEqual(try String(contentsOf: container.appendingPathComponent("0")), "a")
    }
    func testDifferentParentDirectoriesAndPreCancelledPlan() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: false)
        try file("a"); try file("dir/a", content: "inner")
        let plan = try BatchRenamePlan(sources: capture(["a", "dir/a"]), names: ["x", "x"])
        let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try plan.execute(cancellation: token))
        XCTAssertEqual(try contents("a"), "a")
        try plan.execute()
        XCTAssertEqual(try contents("x"), "a"); XCTAssertEqual(try contents("dir/x"), "inner")
        try assertClean()
    }
    func testUnicodeCollisionsAndArchiveMembers() throws {
        try file("a"); try file("b"); try file("archive.zip")
        XCTAssertThrowsError(try BatchRenamePlan(sources: capture(["a", "b"]), names: ["é", "e\u{301}"]))
        XCTAssertThrowsError(try BatchRenameSource(url: root.appendingPathComponent("archive.zip/member")))
        _ = try BatchRenameSource(url: root.appendingPathComponent("archive.zip"))
    }
    func testSymlinkParentAliasesDeduplicateAndDoNotRetargetCapturedSources() throws {
        let original = root.appendingPathComponent("original"), other = root.appendingPathComponent("other")
        for directory in [original, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        try file("original/a", content: "original"); try file("other/a", content: "other")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let sources = try [BatchRenameSource(url: link.appendingPathComponent("a")), BatchRenameSource(url: original.appendingPathComponent("a"))]
        XCTAssertThrowsError(try BatchRenamePlan(sources: sources, names: ["x", "y"]))
        let plan = try BatchRenamePlan(sources: [sources[0]], names: ["x"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        try plan.execute()
        XCTAssertEqual(try contents("original/x"), "original"); XCTAssertEqual(try contents("other/a"), "other")
    }
    func testParentReplacedDuringExecutionDoesNotReceiveStagedData() throws {
        let parent = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try file("parent/a"); try file("parent/b")
        let plan = try BatchRenamePlan(sources: capture(["parent/a", "parent/b"]), names: ["x", "y"])
        XCTAssertThrowsError(try plan.execute { progress in
            if progress.completedItems == 1 {
                try! FileManager.default.moveItem(at: parent, to: moved)
                try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                try! self.file("parent/a", content: "outsider")
            }
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("moved/a"))
        }
        XCTAssertEqual(try contents("parent/a"), "outsider")
        XCTAssertEqual(try contents("moved/a"), "parent/a"); XCTAssertEqual(try contents("moved/b"), "parent/b")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: moved.path)), ["a", "b"])
    }
}
