import XCTest
@testable import PaneRookCore

final class CommandExecutionTests: XCTestCase {
    func testEnvironmentIsPassedLiterallyAndStreamsAndStatusArePreserved() throws {
        let literal = "quote ' \" $HOME $(echo injected)\nsecond line"
        let result = try CommandExecution().run("/usr/bin/printf '%s' \"$PANEROOK_TEST_VALUE\"; /usr/bin/printf error >&2; exit 7",
            in: FileManager.default.temporaryDirectory, environment: ["PANEROOK_TEST_VALUE": literal])
        XCTAssertEqual(result.output, literal)
        XCTAssertEqual(result.errorOutput, "error")
        XCTAssertEqual(result.status, 7)
        XCTAssertFalse(result.wasCancelled)
    }
    func testOutputLimitIsReported() throws {
        let result = try CommandExecution().run("/usr/bin/printf abcdefghij", in: FileManager.default.temporaryDirectory, limit: 5)
        XCTAssertEqual(result.output, "abcde")
        XCTAssertTrue(result.truncated)
    }
    func testCancellationTerminatesTheProcessGroupPromptly() throws {
        let execution = CommandExecution()
        let done = expectation(description: "command cancelled")
        let start = Date()
        DispatchQueue.global().async {
            do {
                let result = try execution.run("/bin/sleep 15 & wait", in: FileManager.default.temporaryDirectory)
                XCTAssertTrue(result.wasCancelled)
                XCTAssertNotEqual(result.status, 0)
            } catch { XCTFail(error.localizedDescription) }
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { execution.cancel() }
        wait(for: [done], timeout: 4)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
    func testPreCancelledCommandDoesNotRun() throws {
        let execution = CommandExecution(); execution.cancel()
        let result = try execution.run("exit 0", in: FileManager.default.temporaryDirectory)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.status, -1)
    }
    func testUnboundedOutputStopsAtTheViewerLimit() throws {
        let start = Date()
        let result = try CommandExecution().run("/usr/bin/yes output", in: FileManager.default.temporaryDirectory, limit: 4096)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.output.utf8.count, 4096)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
