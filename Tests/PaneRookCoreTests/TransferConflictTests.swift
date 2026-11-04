import XCTest
import Darwin
@testable import PaneRookCore

final class TransferConflictTests: XCTestCase {
    private var root: URL!
    private var target: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookConflicts-" + UUID().uuidString)
        target = root.appendingPathComponent("target")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func file(_ name: String, _ text: String = "new", in directory: URL? = nil) throws -> URL {
        let url = (directory ?? root).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func plan(_ source: URL, kind: TransferKind = .copy) throws -> TransferPlan {
        try TransferPlan(sources: [source], destination: target, kind: kind, allowsConflicts: true)
    }
    private func assertClean() throws {
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: target.path).contains { $0.hasPrefix(".panerook-transfer-") })
    }
    func testSkipMoveKeepsBothOriginals() throws {
        let source = try file("one")
        let old = try file("one", "old", in: target)
        try plan(source, kind: .move).execute(resolveConflict: { _ in .skip })
        XCTAssertEqual(try String(contentsOf: source), "new")
        XCTAssertEqual(try String(contentsOf: old), "old")
    }
    func testKeepBothGeneratesUnusedNameAndPreservesExtension() throws {
        let source = try file("one.txt")
        try file("one.txt", "old", in: target); try file("one (2).txt", "other", in: target)
        try plan(source, kind: .move).execute(resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("one (3).txt")), "new")
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(TransferNaming.candidate(".hidden", number: 2), ".hidden (2)")
    }
    func testSelfCopyAndHardlinkOnlyAllowNonDestructiveChoices() throws {
        let source = try file("one")
        let selfPlan = try TransferPlan(sources: [source], destination: root, kind: .copy, allowsConflicts: true)
        try selfPlan.execute(resolveConflict: { conflict in
            XCTAssertEqual(conflict.allowedActions, [.skip, .keepBoth]); return .keepBoth
        })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one (2)")), "new")
        try fm.linkItem(at: source, to: target.appendingPathComponent("one"))
        XCTAssertThrowsError(try plan(source).execute(resolveConflict: { _ in .replace }))
        XCTAssertEqual(try String(contentsOf: source), "new")
    }
    func testReplacePublishesNewFileAndMoveRemovesSource() throws {
        for kind in [TransferKind.copy, .move] {
            let source = try file("one")
            try file("one", "old", in: target)
            try plan(source, kind: kind).execute(resolveConflict: { _ in .replace })
            XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("one")), "new")
            XCTAssertEqual(fm.fileExists(atPath: source.path), kind == .copy)
            try assertClean()
        }
    }
    func testDirectoryTypeConflictsReplaceEntireEntry() throws {
        let source = try file("folder/new").deletingLastPathComponent()
        try file("folder", "old file", in: target)
        try plan(source).execute(resolveConflict: { conflict in
            XCTAssertFalse(conflict.allowedActions.contains(.merge)); return .replace
        })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/new")), "new")
        let single = try file("single")
        try file("single/old", in: target)
        try plan(single).execute(resolveConflict: { _ in .replace })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("single")), "new")
        try assertClean()
    }
    func testMergeMoveLeavesSkippedChildrenAndKeepsUnrelatedTargetFiles() throws {
        let source = try file("folder/skip").deletingLastPathComponent()
        try file("folder/new"); try file("folder/replace")
        try file("folder/skip", "old", in: target); try file("folder/replace", "old", in: target)
        try file("folder/unrelated", "unrelated", in: target)
        try plan(source, kind: .move).execute(resolveConflict: { conflict in
            conflict.sourceInfo.kind == .directory ? .merge : (conflict.source.lastPathComponent == "skip" ? .skip : .replace)
        })
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.path), ["skip"])
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/skip")), "old")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/replace")), "new")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/unrelated")), "unrelated")
        try assertClean()
    }
    func testMergeMoveRemovesEmptySourceDirectories() throws {
        let source = try file("folder/nested/new").deletingLastPathComponent().deletingLastPathComponent()
        try file("folder/nested/old", in: target)
        try plan(source, kind: .move).execute(resolveConflict: { _ in .merge })
        XCTAssertFalse(fm.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("folder/nested/new")), "new")
    }
    func testDanglingLinksAreReplacedAsLinksWithoutTouchingReferents() throws {
        let source = root.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        try fm.createSymbolicLink(atPath: target.appendingPathComponent("link").path, withDestinationPath: "other-missing")
        try plan(source).execute(resolveConflict: { conflict in
            XCTAssertEqual(conflict.sourceInfo.kind, .symbolicLink)
            XCTAssertFalse(conflict.allowedActions.contains(.merge)); return .replace
        })
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path), "missing")
        try assertClean()
    }
    func testTargetChangedWhilePromptOpenIsNotReplaced() throws {
        let source = try file("one")
        let old = try file("one", "old", in: target)
        XCTAssertThrowsError(try plan(source).execute(resolveConflict: { _ in
            try Data("changed".utf8).write(to: old); return .replace
        }))
        XCTAssertEqual(try String(contentsOf: old), "changed")
        try assertClean()
    }
    func testCancelledReplacementPreservesOldFileAndCleansStaging() throws {
        let source = try file("large", String(repeating: "a", count: 8 * 1024 * 1024))
        let old = try file("large", "old", in: target)
        let token = TransferCancellation()
        XCTAssertThrowsError(try plan(source, kind: .move).execute(cancellation: token, resolveConflict: { _ in .replace }, progress: {
            if $0.currentFileBytes > 0 { token.cancel() }
        }))
        XCTAssertEqual(try String(contentsOf: old), "old")
        XCTAssertTrue(fm.fileExists(atPath: source.path)); try assertClean()
    }
    func testChangeDuringCopyDoesNotReplaceOldTarget() throws {
        let source = try file("large", String(repeating: "a", count: 8 * 1024 * 1024))
        let old = try file("large", "old", in: target)
        var changed = false
        XCTAssertThrowsError(try plan(source).execute(resolveConflict: { _ in .replace }, progress: {
            if $0.currentFileBytes > 0 && !changed { changed = true; try? Data("newer".utf8).write(to: old) }
        }))
        XCTAssertTrue(changed); XCTAssertEqual(try String(contentsOf: old), "newer"); try assertClean()
    }
    func testQueuedCollisionCanBeResolvedAndRulesRejectIncompatibleAction() throws {
        let source = try file("one")
        let queued = try plan(source)
        try file("one", "created later", in: target)
        try queued.execute(resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("one (2)")), "new")
        XCTAssertNil(TransferConflictRules(action: .merge).decision(for: [.skip, .keepBoth, .replace]))
        XCTAssertEqual(TransferConflictRules(action: .replace).decision(for: [.skip, .replace]), .replace)
    }
    func testRecursiveDestinationStillRejectedWithConflictsEnabled() throws {
        let source = try file("folder/sub/file").deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertThrowsError(try TransferPlan(sources: [source], destination: source.appendingPathComponent("sub"), kind: .copy, allowsConflicts: true))
    }
    func testRetargetedParentLinkDoesNotPublishAndCleansOriginalStaging() throws {
        let source = try file("large", String(repeating: "a", count: 8 * 1024 * 1024))
        try file("large", "old", in: target)
        let other = try file("other/large", "unrelated").deletingLastPathComponent()
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: target)
        let transfer = try TransferPlan(sources: [source], destination: alias, kind: .copy, allowsConflicts: true)
        var changed = false
        XCTAssertThrowsError(try transfer.execute(resolveConflict: { _ in .replace }, progress: {
            if $0.currentFileBytes > 0 && !changed {
                changed = true
                do {
                    try self.fm.removeItem(at: alias)
                    try self.fm.createSymbolicLink(at: alias, withDestinationURL: other)
                } catch { XCTFail(error.localizedDescription) }
            }
        }))
        XCTAssertTrue(changed)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("large")), "old")
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("large")), "unrelated")
        try assertClean()
    }
    func testSelfMoveKeepBothPreservesExistingTarget() throws {
        let source = try file("self.txt")
        let transfer = try TransferPlan(sources: [source], destination: root, kind: .move, allowsConflicts: true)
        try transfer.execute(resolveConflict: { _ in .keepBoth })
        XCTAssertEqual(try String(contentsOf: source), "new")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("self (2).txt")), "new")
    }
    func testSourceReplacedByLinkDuringMergePromptIsRejected() throws {
        let source = try file("folder/new").deletingLastPathComponent()
        let other = try file("other/untouched").deletingLastPathComponent()
        try file("folder/old", in: target)
        XCTAssertThrowsError(try plan(source, kind: .move).execute(resolveConflict: { _ in
            try self.fm.removeItem(at: source)
            try self.fm.createSymbolicLink(at: source, withDestinationURL: other)
            return .merge
        }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: other.path), ["untouched"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: target.appendingPathComponent("folder").path), ["old"])
    }
    func testReadOnlyTargetFailureKeepsOriginalAndCleansStaging() throws {
        let source = try file("folder/new").deletingLastPathComponent()
        let old = try file("folder/old", in: target).deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: old.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: old.path) }
        XCTAssertThrowsError(try plan(source).execute(resolveConflict: { _ in .replace }))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: old.path), ["old"])
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("new")), "new")
        try assertClean()
    }
    func testArchiveConflictsOnlySupportSkipAndUniqueNames() throws {
        let input = try file("input/one.txt", "old").deletingLastPathComponent()
        let archive = root.appendingPathComponent("test.tar")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", archive.path, "-C", input.path, "one.txt"]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let source = try file("one.txt")
        let transfer = try TransferPlan(sources: [source], destination: archive, kind: .copy, allowsConflicts: true)
        try transfer.execute(resolveConflict: {
            XCTAssertEqual($0.allowedActions, [.skip, .keepBoth]); return .keepBoth
        })
        XCTAssertEqual(try FileSystem.list(archive, showHidden: true).map(\.name), ["one (2).txt", "one.txt"])
        XCTAssertThrowsError(try transfer.execute(resolveConflict: { _ in .replace }))
    }
}
