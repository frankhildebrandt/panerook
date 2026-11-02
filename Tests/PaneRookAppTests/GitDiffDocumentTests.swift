import XCTest

@testable import PaneRookApp

final class GitDiffDocumentTests: XCTestCase {
    func testReplacementRunsAlignUnequalSidesAndKeepBothLineNumbers() {
        let patch = """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -10,4 +20,5 @@ function
         context
        -old one
        -old two
        +new one
        +new two
        +new three
         tail
        """
        let document = GitDiffDocument(patch: patch)
        XCTAssertEqual(document.unified, patch)
        let changes = document.rows.filter { $0.kind == .change }
        XCTAssertEqual(changes, [
            GitDiffRow(left: GitDiffLine(number: 11, text: "old one"), right: GitDiffLine(number: 21, text: "new one"), kind: .change),
            GitDiffRow(left: GitDiffLine(number: 12, text: "old two"), right: GitDiffLine(number: 22, text: "new two"), kind: .change),
            GitDiffRow(left: nil, right: GitDiffLine(number: 23, text: "new three"), kind: .change)
        ])
        let context = document.rows.filter { $0.kind == .context }
        XCTAssertEqual(context.map { $0.left?.number }, [10, 13])
        XCTAssertEqual(context.map { $0.right?.number }, [20, 24])
        XCTAssertEqual(context.map { $0.left?.text }, ["context", "tail"])
    }

    func testPureAdditionsDeletionsAndMultipleFilesResetHunkNumbers() {
        let document = GitDiffDocument(patch: """
        diff --git a/deleted.txt b/deleted.txt
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/added.txt b/added.txt
        @@ -0,0 +1,2 @@
        +three
        +four
        @@ -8 +9 @@
        -old
        +new
        """)
        let changes = document.rows.filter { $0.kind == .change }
        XCTAssertEqual(changes.count, 5)
        XCTAssertEqual(changes[0].left, GitDiffLine(number: 1, text: "one"))
        XCTAssertNil(changes[0].right)
        XCTAssertEqual(changes[1].left?.number, 2)
        XCTAssertNil(changes[2].left)
        XCTAssertEqual(changes[2].right, GitDiffLine(number: 1, text: "three"))
        XCTAssertEqual(changes[3].right?.number, 2)
        XCTAssertEqual(changes[4].left?.number, 8)
        XCTAssertEqual(changes[4].right?.number, 9)
    }

    func testHeaderLookingSourceLinesStayInsideTheHunk() {
        let document = GitDiffDocument(patch: """
        @@ -2,2 +2,2 @@
        ---- source
        -+++ source
        +--- target
        ++++ target
        """)
        let changes = document.rows.filter { $0.kind == .change }
        XCTAssertEqual(changes.map { $0.left?.text }, ["--- source", "+++ source"])
        XCTAssertEqual(changes.map { $0.right?.text }, ["--- target", "+++ target"])
        XCTAssertEqual(changes.map { $0.left?.number }, [2, 3])
    }

    func testMissingFinalNewlineMarkersDoNotBreakReplacementAlignment() {
        let patch = "@@ -1 +1 @@\n-älter 👩🏽‍💻\n\\ No newline at end of file\n+neuer 🦊\n\\ No newline at end of file\n"
        let document = GitDiffDocument(patch: patch)
        let changes = document.rows.filter { $0.kind == .change }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.left, GitDiffLine(number: 1, text: "älter 👩🏽‍💻"))
        XCTAssertEqual(changes.first?.right, GitDiffLine(number: 1, text: "neuer 🦊"))
        let annotations = document.rows.filter { $0.left?.text == "\\ No newline at end of file" }
        XCTAssertEqual(annotations.count, 2)
        XCTAssertTrue(annotations.allSatisfy { $0.kind == .metadata && $0.left?.number == nil && $0.right?.number == nil })
    }

    func testCRLFPatchPreservesOriginalTextAndDisplaysLogicalLines() {
        let patch = "@@ -1,2 +1,2 @@\r\n keep\r\n-old\r\n+new\r\n"
        let document = GitDiffDocument(patch: patch)
        XCTAssertEqual(document.unified, patch)
        XCTAssertEqual(document.rows.first { $0.kind == .context }?.left?.text, "keep")
        XCTAssertEqual(document.rows.first { $0.kind == .change }?.left?.text, "old")
        XCTAssertEqual(document.rows.first { $0.kind == .change }?.right?.text, "new")
    }

    func testBinaryCombinedMalformedAndTruncatedHunksRemainReadableMetadata() {
        let samples = [
            "Binary files a/image.png and b/image.png differ\n",
            "diff --cc file\n@@@ -1,1 -1,1 +1,1 @@@\n--old\n++new\n",
            "@@ -1,3 +1,3 @@\n one\n-old\n+new\n",
            "@@ -1 +1 @@\n? malformed\n",
            "@@ -\(Int.max),1 +1,1 @@\n-old\n+new\n"
        ]
        for patch in samples {
            let document = GitDiffDocument(patch: patch)
            XCTAssertEqual(document.unified, patch)
            XCTAssertFalse(document.rows.isEmpty)
            XCTAssertTrue(document.rows.allSatisfy { $0.kind == .metadata && $0.left?.number == nil && $0.right?.number == nil })
        }
    }

    func testMessageDoesNotInterpretPatchLookingContent() {
        let message = "@@ -1 +1 @@\n-old\n+new"
        let document = GitDiffDocument.message(message)
        XCTAssertEqual(document.unified, message)
        XCTAssertEqual(document.rows.count, 3)
        XCTAssertTrue(document.rows.allSatisfy { $0.kind == .metadata })
        XCTAssertEqual(document.rows[1].left?.text, "-old")
        XCTAssertEqual(document.rows[1].right?.text, "-old")
    }

    func testUntrackedFilesBecomeAddedLinesWithNoLeftSide() {
        let document = GitDiffDocument.addedFile(name: "Ordner/naïve file\n\"quoted\".txt", content: "first\nsecond")
        XCTAssertTrue(document.unified.contains("--- /dev/null\n"))
        XCTAssertTrue(document.unified.contains("+++ \"b/Ordner/naïve file\\n\\\"quoted\\\".txt\"\n"))
        XCTAssertTrue(document.unified.contains("@@ -0,0 +1,2 @@\n"))
        XCTAssertTrue(document.unified.contains("\\ No newline at end of file"))
        let changes = document.rows.filter { $0.kind == .change }
        XCTAssertTrue(changes.allSatisfy { $0.left == nil })
        XCTAssertEqual(changes.map { $0.right?.number }, [1, 2])
        XCTAssertEqual(changes.map { $0.right?.text }, ["first", "second"])
    }

    func testEmptyAndTrailingBlankUntrackedFilesAndTruncation() {
        let empty = GitDiffDocument.addedFile(name: "empty", content: "")
        XCTAssertTrue(empty.unified.contains("new file mode 100644"))
        XCTAssertTrue(empty.unified.contains("index 0000000..e69de29"))
        XCTAssertFalse(empty.rows.contains { $0.kind == .change })

        let blank = GitDiffDocument.addedFile(name: "blank", content: "first\r\n\r\n")
        XCTAssertEqual(blank.rows.filter { $0.kind == .change }.map { $0.right?.text }, ["first", ""])
        XCTAssertFalse(blank.unified.contains("No newline"))
        let truncated = GitDiffDocument.addedFile(name: "large", content: "partial", truncated: true)
        XCTAssertTrue(truncated.rows.contains { $0.kind == .metadata && $0.right?.text == "[Vorschau gekürzt]" })
        XCTAssertFalse(truncated.unified.contains("No newline"))
    }
}
