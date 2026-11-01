import Foundation

extension RemoteFileSystem {
    public static func parseMLSD(_ data: Data) throws -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteError.unsupportedListing }
        var entries: [RemoteEntry] = []
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss"
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let space = line.firstIndex(of: " ") else { throw RemoteError.unsupportedListing }
            let name = String(line[line.index(after: space)...])
            let facts = line[..<space].split(separator: ";").reduce(into: [String: String]()) { values, fact in
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { values[String(pair[0]).lowercased()] = String(pair[1]) }
            }
            guard let type = facts["type"]?.lowercased() else { throw RemoteError.unsupportedListing }
            if ["cdir", "pdir"].contains(type) { continue }
            guard validName(name) else { throw RemoteError.unsupportedListing }
            entries.append(RemoteEntry(name: name, isDirectory: type == "dir", isSymbolicLink: type.contains("slink"), isRegularFile: type == "file", size: Int64(facts["size"] ?? "") ?? 0, modified: facts["modify"].flatMap { formatter.date(from: String($0.prefix(14))) }))
        }
        return sorted(entries)
    }
    public static func parseLongListing(_ data: Data) throws -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw RemoteError.unsupportedListing }
        // The last separator is exactly one space. Splitting whitespace would silently rename
        // files with leading spaces and could target a different file during deletion.
        let expression = try NSRegularExpression(pattern: #"^([-dlbcps][^\s]+)\s+\S+\s+\S+\s+\S+\s+([0-9]+)\s+\S+\s+\S+\s+\S+ (.*)$"#)
        var entries: [RemoteEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("total ") || line.hasPrefix("sftp>") || line.isEmpty { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = expression.firstMatch(in: line, range: range),
                  let modeRange = Range(match.range(at: 1), in: line), let type = line[modeRange].first,
                  let sizeRange = Range(match.range(at: 2), in: line), let size = Int64(line[sizeRange]),
                  let nameRange = Range(match.range(at: 3), in: line) else { throw RemoteError.unsupportedListing }
            var name = String(line[nameRange])
            if type == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if name == "." || name == ".." { continue }
            guard validName(name) else { throw RemoteError.unsupportedListing }
            entries.append(RemoteEntry(name: name, isDirectory: type == "d", isSymbolicLink: type == "l", isRegularFile: type == "-", size: size))
        }
        return sorted(entries)
    }
    static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(where: { $0.isNewline || $0 == "\0" }) }
    static func sorted(_ entries: [RemoteEntry]) -> [RemoteEntry] { entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
}
