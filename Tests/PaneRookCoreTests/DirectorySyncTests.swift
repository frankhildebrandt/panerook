import XCTest
import Darwin
import PaneRookTasks
@testable import PaneRookCore

final class DirectorySyncTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var left: URL!
    private var right: URL!
    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PaneRookSync-\(UUID())")
        left = root.appendingPathComponent("left"); right = root.appendingPathComponent("right")
        try fm.createDirectory(at: left, withIntermediateDirectories: true)
        try fm.createDirectory(at: right, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    @discardableResult private func file(_ path: String, _ text: String, in base: URL) throws -> URL {
        let url = base.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url); return url
    }
    private func text(_ path: String, in base: URL) throws -> String { try String(contentsOf: base.appendingPathComponent(path), encoding: .utf8) }
    private func plan(_ options: DirectorySyncOptions = .init()) throws -> DirectorySyncPlan {
        try DirectorySync.plan(left: left, right: right, options: options)
    }
    private func run(_ plan: DirectorySyncPlan) throws { try DirectorySync.execute(plan, selected: plan.defaultSelection) }
    private func assertNoStaging(in directory: URL? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let enumerator = try XCTUnwrap(fm.enumerator(at: directory ?? right, includingPropertiesForKeys: nil))
        XCTAssertFalse(enumerator.compactMap { $0 as? URL }.contains { $0.lastPathComponent.hasPrefix(".panerook-sync-") }, file: file, line: line)
    }

    func testAddsUpdatesAndKeepsExtraTargetsByDefault() throws {
        try file("same", "same", in: left); try file("same", "same", in: right)
        let executable = try file("nested/new", "new data", in: left)
        try fm.setAttributes([.posixPermissions: 0o751], ofItemAtPath: executable.path)
        try file("changed", "ABCD", in: left); try file("changed", "ABCE", in: right)
        try file("extra", "keep", in: right)
        let before = try plan()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: before.actions.map { ($0.id, $0.kind) }),
                       ["nested": .createDirectory, "nested/new": .addFile, "changed": .updateFile])
        XCTAssertEqual(before.transferBytes(selected: before.defaultSelection), 12)
        try run(before)
        XCTAssertEqual(try text("nested/new", in: right), "new data")
        XCTAssertEqual(try text("changed", in: right), "ABCD")
        XCTAssertEqual(try text("extra", in: right), "keep")
        XCTAssertEqual((try fm.attributesOfItem(atPath: right.appendingPathComponent("nested/new").path)[.posixPermissions] as? NSNumber)?.intValue, 0o751)
        XCTAssertTrue(try plan().actions.isEmpty)
        try assertNoStaging()
    }
    func testReverseDirectionAndExplicitRecursiveDeletions() throws {
        try file("extra/deep/file", "remove", in: left)
        try file("from-right", "source", in: right)
        let before = try plan(.init(direction: .rightToLeft, deleteExtraneous: true))
        XCTAssertEqual(before.source.lastPathComponent, "right")
        XCTAssertEqual(before.actions.filter { $0.kind.isDeletion }.count, 3)
        try run(before)
        XCTAssertEqual(try text("from-right", in: left), "source")
        XCTAssertFalse(fm.fileExists(atPath: left.appendingPathComponent("extra").path))
        try assertNoStaging(in: left)
    }
    func testExclusionsPruneSubtreesAndRetainParentOfExcludedTarget() throws {
        try file("cache/file", "skip", in: left); try file("a.tmp", "skip", in: left)
        try file("sub/one.tmp", "skip", in: left); try file("sub/keep", "copy", in: left)
        try file("extra/keep.tmp", "retain", in: right); try file("extra/delete", "delete", in: right)
        let before = try plan(.init(deleteExtraneous: true, exclusions: ["cache", "*.tmp"]))
        XCTAssertFalse(before.actions.contains { $0.id.hasPrefix("cache") || $0.id.hasSuffix(".tmp") })
        XCTAssertEqual(before.actions.first { $0.id == "extra" }?.kind, .blocked)
        XCTAssertTrue(before.defaultSelection.contains("extra/delete"))
        try run(before)
        XCTAssertEqual(try text("extra/keep.tmp", in: right), "retain")
        XCTAssertFalse(fm.fileExists(atPath: right.appendingPathComponent("extra/delete").path))
        XCTAssertEqual(try text("sub/keep", in: right), "copy")
    }
    func testPartialSelectionAndDirectoryDependencies() throws {
        try file("new/deep/a", "a", in: left); try file("new/deep/b", "b", in: left)
        let before = try plan()
        let selected = before.selecting("new/deep/a", included: true, in: [])
        XCTAssertEqual(selected, ["new", "new/deep", "new/deep/a"])
        XCTAssertTrue(before.selecting("new", included: false, in: selected).isEmpty)
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: ["new/deep/a"]))
        XCTAssertFalse(fm.fileExists(atPath: right.appendingPathComponent("new").path))
        try DirectorySync.execute(before, selected: selected)
        XCTAssertEqual(try text("new/deep/a", in: right), "a")
        XCTAssertFalse(fm.fileExists(atPath: right.appendingPathComponent("new/deep/b").path))
    }
    func testDeselectingDeletionChildRetainsParents() throws {
        try file("extra/deep/a", "a", in: right); try file("extra/deep/b", "b", in: right)
        let before = try plan(.init(deleteExtraneous: true))
        let selected = before.selecting("extra/deep/a", included: false, in: before.defaultSelection)
        XCTAssertEqual(selected, ["extra/deep/b"])
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: ["extra"]))
        try DirectorySync.execute(before, selected: selected)
        XCTAssertEqual(try text("extra/deep/a", in: right), "a")
        XCTAssertFalse(fm.fileExists(atPath: right.appendingPathComponent("extra/deep/b").path))
    }
    func testSymlinksCyclesSpecialFilesAndTypeConflictsAreBlocked() throws {
        let outside = root.appendingPathComponent("outside")
        try file("secret", "safe", in: outside)
        try fm.createSymbolicLink(at: left.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: right.appendingPathComponent("cycle"), withDestinationURL: right)
        try file("type/child", "source", in: left); try file("type", "target", in: right)
        XCTAssertEqual(mkfifo(left.appendingPathComponent("pipe").path, 0o600), 0)
        let before = try plan(.init(deleteExtraneous: true))
        XCTAssertEqual(Set(before.actions.filter { $0.kind == .blocked }.map(\.id)), ["link", "cycle", "type", "pipe"])
        XCTAssertFalse(before.actions.contains { $0.id.contains("/child") || $0.id.contains("secret") })
        try run(before)
        XCTAssertEqual(try text("secret", in: outside), "safe")
        XCTAssertEqual(try text("type", in: right), "target")
    }
    func testSourceReadProblemBlocksExtraneousDeletion() throws {
        try file("large", "oversized", in: left); try file("extra", "safe", in: right)
        let before = try DirectorySync.plan(left: left, right: right, options: .init(deleteExtraneous: true), maximumFileBytes: 4)
        XCTAssertEqual(before.actions.first { $0.id == "large" }?.kind, .blocked)
        XCTAssertEqual(before.actions.first { $0.id == "extra" }?.kind, .blocked)
        XCTAssertTrue(before.defaultSelection.isEmpty)
    }
    func testEntryLimitsAbortPlanAndDoNotAuthorizePartialInventory() throws {
        try file("a", "a", in: left); try file("b", "b", in: left)
        XCTAssertThrowsError(try DirectorySync.plan(left: left, right: right, maximumEntries: 1))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: right.path).isEmpty)
    }
    func testIdenticalNestedAndSymlinkAliasedRootsAreRejected() throws {
        XCTAssertThrowsError(try DirectorySync.plan(left: left, right: left))
        let nested = left.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DirectorySync.plan(left: left, right: nested))
        XCTAssertThrowsError(try DirectorySync.plan(left: nested, right: left))
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: left)
        XCTAssertThrowsError(try DirectorySync.plan(left: left, right: alias))
        XCTAssertThrowsError(try DirectorySync.plan(left: URL(string: "https://example.com")!, right: right))
    }
    func testTargetContentChangeWithSameLengthAndRestoredMtimeInvalidatesPlan() throws {
        try file("file", "source", in: left); let target = try file("file", "before", in: right)
        let before = try plan()
        let date = try fm.attributesOfItem(atPath: target.path)[.modificationDate]!
        try Data("after!".utf8).write(to: target)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        XCTAssertThrowsError(try run(before))
        XCTAssertEqual(try text("file", in: right), "after!")
        try assertNoStaging()
    }
    func testSourceChangeAndNewTargetEntryInvalidateEntirePlanBeforeWrites() throws {
        try file("a", "a", in: left); try file("b", "b", in: left)
        let before = try plan()
        try file("b", "new", in: left)
        XCTAssertThrowsError(try run(before))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: right.path).isEmpty)
        let fresh = try plan()
        try file("unrelated", "keep", in: right)
        XCTAssertThrowsError(try run(fresh))
        XCTAssertFalse(fm.fileExists(atPath: right.appendingPathComponent("a").path))
    }
    func testSwappedTargetAncestorCannotFollowSymlinkOutsideRoot() throws {
        try file("folder/file", "new", in: left); try file("folder/file", "old", in: right)
        let before = try plan()
        let moved = root.appendingPathComponent("moved")
        try fm.moveItem(at: right.appendingPathComponent("folder"), to: moved)
        try fm.createSymbolicLink(at: right.appendingPathComponent("folder"), withDestinationURL: moved)
        XCTAssertThrowsError(try run(before))
        XCTAssertEqual(try text("file", in: moved), "old")
    }
    func testRootReplacementAfterPreviewIsRejected() throws {
        try file("file", "new", in: left)
        let before = try plan()
        try fm.moveItem(at: right, to: root.appendingPathComponent("old-right"))
        try fm.createDirectory(at: right, withIntermediateDirectories: false)
        XCTAssertThrowsError(try run(before))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: right.path).isEmpty)
    }
    func testCancellationDuringCopyDoesNotPublishPartialUpdate() throws {
        try file("file", String(repeating: "A", count: 4_000_000), in: left)
        try file("file", "keep", in: right)
        let before = try plan(); let token = TransferCancellation(); var cancelled = false
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: before.defaultSelection, cancellation: token) { progress in
            if progress.currentFileBytes > 0 { cancelled = true; token.cancel() }
        })
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try text("file", in: right), "keep")
        try assertNoStaging()
    }
    func testTargetChangedDuringStagingIsRetained() throws {
        try file("file", String(repeating: "A", count: 100_000), in: left)
        let target = try file("file", "keep", in: right)
        let before = try plan(); var changed = false
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: before.defaultSelection) { progress in
            if progress.currentFileBytes > 0 && !changed { changed = true; try! Data("external".utf8).write(to: target) }
        })
        XCTAssertTrue(changed); XCTAssertEqual(try text("file", in: right), "external")
        try assertNoStaging()
    }
    func testCancellationBeforeStartAndBlockedSelectionNeverWrite() throws {
        try file("file", "a", in: left)
        let before = try plan(); let token = TransferCancellation(); token.cancel()
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: before.defaultSelection, cancellation: token))
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: ["../escape"]))
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: right.path).isEmpty)
    }
    func testProgressReportsSelectedFileBytesAndCompletion() throws {
        try file("file", "12345", in: left)
        let before = try plan(); var updates: [OperationProgress] = []
        try DirectorySync.execute(before, selected: before.defaultSelection) { updates.append($0) }
        XCTAssertEqual(updates.last?.completedItems, 1); XCTAssertEqual(updates.last?.totalItems, 1)
        XCTAssertEqual(updates.last?.completedBytes, 5); XCTAssertEqual(updates.last?.totalBytes, 5)
        XCTAssertTrue(updates.contains { $0.currentFileBytes > 0 })
    }
    func testUnreadableSubdirectoryBecomesBlockedAndCannotAuthorizeDeletion() throws {
        let denied = left.appendingPathComponent("denied")
        try file("denied/secret", "secret", in: left); try file("extra", "safe", in: right)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path) }
        guard access(denied.path, R_OK) != 0 else { throw XCTSkip("Test benötigt einen Benutzer ohne Root-Leserechte") }
        let before = try plan(.init(deleteExtraneous: true))
        XCTAssertEqual(before.actions.first { $0.id == "denied" }?.kind, .blocked)
        XCTAssertEqual(before.actions.first { $0.id == "extra" }?.kind, .blocked)
        XCTAssertTrue(before.defaultSelection.isEmpty)
    }
    func testMovingTargetParentDuringCopyDoesNotPublishIntoDetachedDirectory() throws {
        try file("folder/file", String(repeating: "A", count: 100_000), in: left)
        try file("folder/file", "keep", in: right)
        let before = try plan(); let moved = root.appendingPathComponent("detached")
        var movedDuringCopy = false
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: before.defaultSelection) { progress in
            if progress.currentFileBytes > 0 && !movedDuringCopy {
                movedDuringCopy = true
                try! self.fm.moveItem(at: self.right.appendingPathComponent("folder"), to: moved)
                try! self.fm.createSymbolicLink(at: self.right.appendingPathComponent("folder"), withDestinationURL: moved)
            }
        })
        XCTAssertTrue(movedDuringCopy)
        XCTAssertEqual(try text("file", in: moved), "keep")
        try assertNoStaging(in: moved)
    }
    func testCaseAliasedNestedRootsAreRejectedWhenSupportedByVolume() throws {
        try fm.createDirectory(at: left.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("LEFT/nested")
        guard fm.fileExists(atPath: alias.path) else { throw XCTSkip("Volume ist case-sensitive") }
        XCTAssertThrowsError(try DirectorySync.plan(left: left, right: alias))
    }
    func testNewChildDuringDeletionKeepsDirectoryAndUnpreviewedFile() throws {
        try fm.createDirectory(at: right.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let before = try plan(.init(deleteExtraneous: true)); var injected = false
        XCTAssertThrowsError(try DirectorySync.execute(before, selected: before.defaultSelection) { progress in
            if progress.currentPath == "empty", progress.totalBytes != nil, !injected {
                injected = true
                try! self.file("empty/new", "safe", in: self.right)
            }
        })
        XCTAssertTrue(injected)
        XCTAssertEqual(try text("empty/new", in: right), "safe")
    }
    func testProfileRoundTripUpdateRemoveAndCorruptionProtection() throws {
        let suite = "PaneRookSyncProfiles-\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DirectorySyncProfileStore(defaults: defaults)
        var profile = DirectorySyncProfile(name: "Sicherung", left: left, right: right,
            options: .init(direction: .rightToLeft, deleteExtraneous: true, exclusions: [".git", "*.tmp"]))
        try store.save(profile)
        XCTAssertEqual(try DirectorySyncProfileStore(defaults: defaults).profiles(), [profile])
        profile.name = "Geändert"; try store.save(profile)
        XCTAssertEqual(try store.profiles(), [profile])
        try store.remove(profile.id); XCTAssertTrue(try store.profiles().isEmpty)
        let corrupt = Data("broken".utf8); defaults.set(corrupt, forKey: "PaneRook.directorySyncProfiles.v1")
        XCTAssertThrowsError(try store.profiles()); XCTAssertThrowsError(try store.save(profile))
        XCTAssertEqual(defaults.data(forKey: "PaneRook.directorySyncProfiles.v1"), corrupt)
    }
}
