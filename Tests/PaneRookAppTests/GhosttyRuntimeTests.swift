import AppKit
import GhosttyTerminal
import XCTest
@testable import PaneRookApp

final class GhosttyRuntimeTests: XCTestCase {
    @MainActor
    func testWorkingDirectoryAcceptsExistingLocalPathsAndFileURLsWithoutLosingCharacters() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Ordner mit Leerzeichen % und ä 雪 '", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertEqual(GhosttyTerminalController.localDirectory(from: directory.path), directory.standardizedFileURL)
        XCTAssertEqual(GhosttyTerminalController.localDirectory(from: directory.absoluteString), directory.standardizedFileURL)
        var localhost = try XCTUnwrap(URLComponents(url: directory, resolvingAgainstBaseURL: false))
        localhost.host = "localhost"
        XCTAssertEqual(GhosttyTerminalController.localDirectory(from: try XCTUnwrap(localhost.string)), directory.standardizedFileURL)

        let percentName = root.appendingPathComponent("literal%20name", isDirectory: true)
        try FileManager.default.createDirectory(at: percentName, withIntermediateDirectories: false)
        XCTAssertEqual(GhosttyTerminalController.localDirectory(from: percentName.path), percentName.standardizedFileURL)
        XCTAssertEqual(GhosttyTerminalController.localDirectory(from: percentName.absoluteString), percentName.standardizedFileURL)
    }

    @MainActor
    func testWorkingDirectoryRejectsRemoteHostsFilesMissingAndRelativePaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("file".utf8).write(to: file)
        var remote = try XCTUnwrap(URLComponents(url: root, resolvingAgainstBaseURL: false))
        remote.host = "not-this-machine.invalid"
        let remoteURL = try XCTUnwrap(remote.string)
        for value in ["", ".", "relative/directory", "~/Downloads", file.path, file.absoluteString,
                      root.appendingPathComponent("missing").path, remoteURL,
                      "sftp://localhost" + root.path, root.path + "\0suffix"] {
            XCTAssertNil(GhosttyTerminalController.localDirectory(from: value), value.debugDescription)
        }
        for mutation in ["?query=1", "#fragment"] {
            XCTAssertNil(GhosttyTerminalController.localDirectory(from: root.absoluteString + mutation))
        }
        let controller = GhosttyTerminalController()
        controller.start(directory: file)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.currentDirectory)
        XCTAssertFalse(descendants(of: controller.view).contains { $0 is AppTerminalView })
    }

    @MainActor
    func testRuntimeResourcesIncludeShellIntegrationAndTerminfo() throws {
        let resources = try XCTUnwrap(GhosttyRuntimeResources.directoryURL, "Ghostty resource bundle is missing")
        let terminfo = try XCTUnwrap(GhosttyRuntimeResources.terminfoDirectoryURL, "Ghostty terminfo is missing")
        for relative in ["shell-integration/zsh/.zshenv", "shell-integration/zsh/ghostty-integration",
                         "shell-integration/bash/ghostty.bash"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent(relative).path), relative)
        }
        XCTAssertTrue((try terminfo.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: terminfo, includingPropertiesForKeys: nil))
        XCTAssertTrue(files.allObjects.compactMap { $0 as? URL }.contains { $0.lastPathComponent == "xterm-ghostty" })
    }

    /// Requires WindowServer/Metal and an unrestricted local PTY. Ordinary CI
    /// runs validate integration with the injected terminal tests instead.
    @MainActor
    func testNativeGhosttyShellReportsCWDAndSurvivesHiding() throws {
        guard ProcessInfo.processInfo.environment["PANEROOK_TEST_GHOSTTY"] == "1" else {
            throw XCTSkip("Set PANEROOK_TEST_GHOSTTY=1 to run the native Ghostty/PTY smoke test")
        }
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("shell cwd % ä '", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let controller = GhosttyTerminalController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            controller.stop()
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 800, height: 500))
        controller.start(directory: root)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.isRunning, "A rejected Ghostty configuration must fail startup")
        let terminal = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? AppTerminalView }.first)
        let runtime = try XCTUnwrap(terminal.controller)
        XCTAssertNil(runtime.lastConfigurationIssue, runtime.lastConfigurationIssue ?? "")
        XCTAssertGreaterThan(terminal.bounds.width, 0)
        XCTAssertGreaterThan(terminal.bounds.height, 0)
        let command = "cd -- " + shellQuote(target.path)
        try eventually("Ghostty surface did not become ready") { terminal.paste(text: command) }
        // The PTY can accept text before the login shell finishes its rc files.
        pumpRunLoop(for: 0.5)
        XCTAssertTrue(terminal.sendKey(.enter))
        try eventually("Shell integration did not report the changed working directory") {
            controller.currentDirectory == target
        }
        pumpRunLoop(for: 0.3)
        controller.setVisible(false)
        XCTAssertTrue(controller.view.isHidden)
        XCTAssertTrue(controller.isRunning)
        controller.setVisible(true)
        controller.start(directory: root)
        XCTAssertFalse(controller.view.isHidden)
        XCTAssertEqual(controller.currentDirectory, target, "Reopening must retain the existing shell")
        XCTAssertTrue(descendants(of: controller.view).contains { $0 === terminal })

        // Keep the same terminal process alive through a hide/show cycle and
        // prove it still executes keys and publishes fresh directory updates.
        XCTAssertTrue(terminal.paste(text: "cd -- " + shellQuote(root.path)))
        pumpRunLoop(for: 0.1)
        XCTAssertTrue(terminal.sendKey(.enter))
        try eventually("The retained shell stopped reporting directories") {
            controller.currentDirectory?.standardizedFileURL.path == root.standardizedFileURL.path
        }
        XCTAssertFalse(window.isVisible)
        window.close()
        XCTAssertFalse(controller.isRunning, "Closing the window must terminate its PTY")
        controller.stop()
        XCTAssertFalse(controller.isRunning)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneRookGhosttyTests-\(UUID())", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func shellQuote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private func pumpRunLoop(for interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    @MainActor
    private func eventually(_ message: String, timeout: TimeInterval = 12,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var succeeded = condition()
        while !succeeded && Date() < deadline {
            pumpRunLoop(for: 0.02)
            succeeded = condition()
        }
        guard succeeded else {
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "GhosttyRuntimeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
