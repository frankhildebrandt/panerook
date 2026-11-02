#!/usr/bin/env swift
import Foundation
import CryptoKit

// Verify the archive against the key actually embedded in the app before
// publishing metadata. In particular, mismatched CI signing keys must fail.
func generateAppcast() throws {
    guard CommandLine.arguments.count == 5 else {
        throw AppcastError.invalid("Usage: generate-appcast.swift <Info.plist> <archive.zip> <signature-file> <appcast.xml>")
    }
    let arguments = CommandLine.arguments
    let plistData = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else {
        throw AppcastError.invalid("The built application's Info.plist is invalid.")
    }
    func value(_ key: String) throws -> String {
        guard let value = plist[key] as? String, !value.isEmpty else {
            throw AppcastError.invalid("The built application's Info.plist is missing \(key).")
        }
        return value
    }
    let version = try value("CFBundleShortVersionString")
    let build = try value("CFBundleVersion")
    let minimumSystem = try value("LSMinimumSystemVersion")
    guard version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil,
          build.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else {
        throw AppcastError.invalid("Release and build versions must be valid version numbers.")
    }
    guard let publicKeyData = Data(base64Encoded: try value("SUPublicEDKey")), publicKeyData.count == 32 else {
        throw AppcastError.invalid("The built app must contain a valid Sparkle public key.")
    }
    let signatureText = try String(contentsOfFile: arguments[3], encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
        throw AppcastError.invalid("sign_update did not produce a valid Ed25519 signature.")
    }
    let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .mappedIfSafe)
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signature, for: archive) else {
        throw AppcastError.invalid("The update signature does not match the public key embedded in the app.")
    }
    let artifact = "PaneRook-\(version)-macOS-universal.zip"
    guard URL(fileURLWithPath: arguments[2]).lastPathComponent == artifact else {
        throw AppcastError.invalid("The ZIP filename must match the release version: \(artifact).")
    }
    let releaseURL = "https://github.com/frankhildebrandt/panerook/releases/tag/v\(version)"
    let downloadURL = "https://github.com/frankhildebrandt/panerook/releases/download/v\(version)/\(artifact)"
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    let description = "<p>PaneRook \(version) ist verfügbar.</p><p><a href=\"\(releaseURL)\">Versionshinweise auf GitHub</a></p>"
    let appcast = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel>
        <title>PaneRook Updates</title>
        <link>https://github.com/frankhildebrandt/panerook/releases</link>
        <description>PaneRook für macOS</description>
        <language>de</language>
        <item>
          <title>PaneRook \(xml(version))</title>
          <pubDate>\(dateFormatter.string(from: Date()))</pubDate>
          <link>\(xml(releaseURL))</link>
          <description>\(xml(description))</description>
          <sparkle:version>\(xml(build))</sparkle:version>
          <sparkle:shortVersionString>\(xml(version))</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>\(xml(minimumSystem))</sparkle:minimumSystemVersion>
          <enclosure url="\(xml(downloadURL))" sparkle:edSignature="\(xml(signatureText))" length="\(archive.count)" type="application/octet-stream" />
        </item>
      </channel>
    </rss>

    """
    try appcast.write(toFile: arguments[4], atomically: true, encoding: .utf8)
}

enum AppcastError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

do {
    try generateAppcast()
} catch {
    fputs("Appcast generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
