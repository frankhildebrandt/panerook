import Foundation
import XCTest

final class ArchitectureBoundaryTests: XCTestCase {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }
    func testFeaturesCannotReachBackIntoConcreteShellOrPanelControllers() throws {
        let app = sources.appendingPathComponent("PaneRookApp")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" {
            let relative = String(file.path.dropFirst(app.path.count + 1))
            let source = try String(contentsOf: file)
            if !relative.hasPrefix("Shell/") {
                XCTAssertNil(source.range(of: #"\bCommanderController\b"#, options: .regularExpression), relative)
            }
            if !relative.hasPrefix("Shell/") && !relative.hasPrefix("Panels/") {
                XCTAssertNil(source.range(of: #"\bPaneController\b"#, options: .regularExpression), relative)
            }
        }
    }
    func testDomainTargetsDoNotImportUIOrTheApp() throws {
        for target in ["PaneRookCore", "PaneRookTasks", "PaneRookRemote", "PaneRookPanels"] {
            let files = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: sources.appendingPathComponent(target), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file)
                XCTAssertNil(
                    source.range(of: #"(?m)^import (AppKit|Quartz|PaneRookApp)\b"#, options: .regularExpression),
                    file.path)
            }
        }
    }
}
