import Foundation

struct GitDiffLine: Equatable, Sendable {
    let number: Int?
    let text: String
}

struct GitDiffRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, change, metadata }

    let left: GitDiffLine?
    let right: GitDiffLine?
    let kind: Kind

    fileprivate static func metadata(_ text: String) -> Self {
        let line = GitDiffLine(number: nil, text: text)
        return Self(left: line, right: line, kind: .metadata)
    }
}

/// Presentation data for both diff layouts. The original patch remains intact;
/// only complete, standard unified hunks receive side-by-side line numbers.
struct GitDiffDocument: Sendable {
    let unified: String
    let rows: [GitDiffRow]

    init(patch: String) {
        unified = patch
        let lines = Self.lines(in: patch)
        var parsed: [GitDiffRow] = []
        var index = 0
        while index < lines.count {
            if let hunk = Self.hunk(in: lines, at: index) {
                parsed.append(contentsOf: hunk.rows)
                index = hunk.end
            } else {
                parsed.append(.metadata(lines[index]))
                index += 1
            }
        }
        rows = parsed
    }

    private init(unified: String, rows: [GitDiffRow]) {
        self.unified = unified
        self.rows = rows
    }

    static func message(_ text: String) -> Self {
        Self(unified: text, rows: lines(in: text).map(GitDiffRow.metadata))
    }

    /// An untracked file is an addition against an empty left side. Keeping it
    /// as a regular patch makes both layouts use exactly the same content.
    static func addedFile(name: String, content: String, truncated: Bool = false) -> Self {
        let oldPath = quotedPath("a/" + name)
        let newPath = quotedPath("b/" + name)
        var patch = "diff --git \(oldPath) \(newPath)\nnew file mode 100644\n"
        if content.isEmpty {
            patch += "index 0000000..e69de29\n"
        } else {
            var contentLines = content.components(separatedBy: "\n")
            if content.utf8.last == 10 { contentLines.removeLast() }
            patch += "--- /dev/null\n+++ \(newPath)\n@@ -0,0 +1,\(contentLines.count) @@\n"
            for line in contentLines { patch += "+" + line + "\n" }
            if content.utf8.last != 10 && !truncated { patch += "\\ No newline at end of file\n" }
        }
        if truncated { patch += "[Vorschau gekürzt]\n" }
        return Self(patch: patch)
    }

    private static func lines(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var values = text.components(separatedBy: "\n")
        if text.utf8.last == 10 { values.removeLast() }
        return values.map { $0.utf8.last == 13 ? String($0.dropLast()) : $0 }
    }

    private static let hunkHeader = try! NSRegularExpression(
        pattern: #"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@.*$"#)
    private static let noNewline = "\\ No newline at end of file"

    private static func hunk(in lines: [String], at start: Int) -> (end: Int, rows: [GitDiffRow])? {
        let header = lines[start]
        guard let match = hunkHeader.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        func integer(_ group: Int, fallback: Int? = nil) -> Int? {
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return fallback }
            guard let swiftRange = Range(range, in: header) else { return nil }
            return Int(header[swiftRange])
        }
        guard let oldStart = integer(1), let oldCount = integer(2, fallback: 1),
              let newStart = integer(3), let newCount = integer(4, fallback: 1),
              oldCount == 0 || oldStart > 0, newCount == 0 || newStart > 0,
              !oldStart.addingReportingOverflow(oldCount).overflow,
              !newStart.addingReportingOverflow(newCount).overflow else { return nil }

        var oldNumber = oldStart, newNumber = newStart
        var oldRemaining = oldCount, newRemaining = newCount
        var index = start + 1
        var rows: [GitDiffRow] = [.metadata(header)]
        var removed: [GitDiffLine] = [], added: [GitDiffLine] = []
        var annotations: [String] = []
        func flushChanges() {
            for offset in 0..<max(removed.count, added.count) {
                rows.append(GitDiffRow(left: offset < removed.count ? removed[offset] : nil,
                                       right: offset < added.count ? added[offset] : nil, kind: .change))
            }
            rows.append(contentsOf: annotations.map(GitDiffRow.metadata))
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
            annotations.removeAll(keepingCapacity: true)
        }
        func annotate(_ text: String) {
            if removed.isEmpty && added.isEmpty { rows.append(.metadata(text)) }
            else { annotations.append(text) }
        }

        while oldRemaining > 0 || newRemaining > 0 {
            guard index < lines.count else { return nil }
            let line = lines[index]
            if line == noNewline {
                annotate(line)
            } else if line.hasPrefix(" "), oldRemaining > 0, newRemaining > 0 {
                flushChanges()
                let text = String(line.dropFirst())
                rows.append(GitDiffRow(left: GitDiffLine(number: oldNumber, text: text),
                                       right: GitDiffLine(number: newNumber, text: text), kind: .context))
                oldNumber += 1; newNumber += 1
                oldRemaining -= 1; newRemaining -= 1
            } else if line.hasPrefix("-"), oldRemaining > 0 {
                removed.append(GitDiffLine(number: oldNumber, text: String(line.dropFirst())))
                oldNumber += 1; oldRemaining -= 1
            } else if line.hasPrefix("+"), newRemaining > 0 {
                added.append(GitDiffLine(number: newNumber, text: String(line.dropFirst())))
                newNumber += 1; newRemaining -= 1
            } else {
                return nil
            }
            index += 1
        }
        while index < lines.count, lines[index] == noNewline {
            annotate(lines[index])
            index += 1
        }
        flushChanges()
        return (index, rows)
    }

    /// Git-style C quoting keeps control characters out of patch header lines
    /// while allowing readable Unicode filenames.
    private static func quotedPath(_ path: String) -> String {
        guard path.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127
                || $0.value == 34 || $0.value == 92
        }) else { return path }
        var bytes: [UInt8] = [34]
        for byte in path.utf8 {
            let escape: String?
            switch byte {
            case 34: escape = "\\\""
            case 92: escape = "\\\\"
            case 10: escape = "\\n"
            case 13: escape = "\\r"
            case 9: escape = "\\t"
            case 8: escape = "\\b"
            case 12: escape = "\\f"
            case 11: escape = "\\v"
            case 7: escape = "\\a"
            case 0..<32, 127: escape = String(format: "\\%03o", Int(byte))
            default: escape = nil
            }
            if let escape { bytes.append(contentsOf: escape.utf8) }
            else { bytes.append(byte) }
        }
        bytes.append(34)
        return String(decoding: bytes, as: UTF8.self)
    }
}
