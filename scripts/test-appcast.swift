#!/usr/bin/env swift
import Foundation
import CryptoKit

// Exercise the published-feed contract, including real Sparkle signing. These
// disposable keys are never added to the keychain or used for app releases.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let staging = FileManager.default.temporaryDirectory.appendingPathComponent("panerook-appcast-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: staging) }

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw NSError(domain: "AppcastTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
@discardableResult
func run(_ executable: String, _ arguments: [String], succeeds: Bool = true) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    try require((process.terminationStatus == 0) == succeeds, "Unexpected exit status for \(executable): \(output)")
    return output
}

let key = Curve25519.Signing.PrivateKey()
let privateKey = staging.appendingPathComponent("private-key")
try key.rawRepresentation.base64EncodedString().write(to: privateKey, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
let archive = staging.appendingPathComponent("PaneRook-1.2.3-macOS-universal.zip")
try Data("Disposable update archive fixture".utf8).write(to: archive)
let signature = staging.appendingPathComponent("signature")
let signUpdate = root.appendingPathComponent(".build/artifacts/sparkle/Sparkle/bin/sign_update")
let signed = try run(signUpdate.path, ["--ed-key-file", privateKey.path, "-p", archive.path])
try signed.write(to: signature, atomically: true, encoding: .utf8)
let info = staging.appendingPathComponent("Info.plist")
var properties = [
    "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42", "LSMinimumSystemVersion": "14.0",
    "SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()
]
func writeInfo() throws {
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: info)
}
try writeInfo()
let appcast = staging.appendingPathComponent("appcast.xml")
let generate = ["swift", root.appendingPathComponent("scripts/generate-appcast.swift").path,
                info.path, archive.path, signature.path, appcast.path]
try run("/usr/bin/env", generate)
let xml = try XMLDocument(contentsOf: appcast)
let enclosures = try xml.nodes(forXPath: "//enclosure")
try require(enclosures.count == 1, "Expected one update enclosure")
let enclosure = enclosures[0] as! XMLElement
try require(enclosure.attribute(forName: "url")?.stringValue == "https://github.com/frankhildebrandt/panerook/releases/download/v1.2.3/PaneRook-1.2.3-macOS-universal.zip", "The enclosure must link to the versioned GitHub ZIP")
try require(enclosure.attribute(forName: "length")?.stringValue == String(Data(contentsOf: archive).count), "The feed must contain the archive byte length")
try require(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == signed.trimmingCharacters(in: .whitespacesAndNewlines), "The feed must contain the archive signature")
try require(xml.nodes(forXPath: "//*[local-name()='version']").first?.stringValue == "42", "Sparkle must compare the build version")
try require(xml.nodes(forXPath: "//*[local-name()='shortVersionString']").first?.stringValue == "1.2.3", "The displayed release version must remain separate")
try require(xml.nodes(forXPath: "//*[local-name()='minimumSystemVersion']").first?.stringValue == "14.0", "The feed must preserve the app's minimum macOS version")

properties["SUPublicEDKey"] = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
try writeInfo()
try run("/usr/bin/env", generate, succeeds: false)
properties["SUPublicEDKey"] = key.publicKey.rawRepresentation.base64EncodedString()
properties["CFBundleVersion"] = "invalid"
try writeInfo()
try run("/usr/bin/env", generate, succeeds: false)
properties["CFBundleVersion"] = "42"
try writeInfo()
try Data("Tampered archive".utf8).write(to: archive)
try run("/usr/bin/env", generate, succeeds: false)
try "invalid signature".write(to: signature, atomically: true, encoding: .utf8)
try run("/usr/bin/env", generate, succeeds: false)
print("Appcast tests passed: GitHub metadata, Sparkle signing, key mismatch, tampering, invalid signature and build version.")
