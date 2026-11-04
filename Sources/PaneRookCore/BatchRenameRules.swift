import Foundation

/// Codable rules contain no paths. Tokens are expanded only in prefix/suffix.
public struct BatchRenameRules: Codable, Equatable, Sendable {
    public enum LetterCase: String, Codable, CaseIterable, Sendable {
        case unchanged, lowercase, uppercase, capitalized
    }
    public enum DateSource: String, Codable, CaseIterable, Sendable {
        case now, modified, created
    }
    public var search = ""
    public var replacement = ""
    public var regularExpression = false
    public var caseSensitive = true
    public var includeExtension = false
    public var prefix = ""
    public var suffix = ""
    public var letterCase: LetterCase = .unchanged
    public var numberStart = 1
    public var numberStep = 1
    public var numberDigits = 3
    public var dateSource: DateSource = .now
    public var dateFormat = "yyyy-MM-dd"
    public init() {}

    public func names(for sources: [BatchRenameSource], referenceDate: Date = Date(),
                      timeZone: TimeZone = .current) throws -> [String] {
        guard (1...18).contains(numberDigits) else {
            throw BatchRenameError("Die Nummernbreite muss zwischen 1 und 18 liegen.")
        }
        let regex = regularExpression && !search.isEmpty
            ? try NSRegularExpression(pattern: search, options: caseSensitive ? [] : [.caseInsensitive]) : nil
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return try sources.enumerated().map { index, source in
            let name = source.url.lastPathComponent
            let ext = source.isDirectory || includeExtension ? "" : (name as NSString).pathExtension
            var stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
            if let regex {
                stem = regex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem),
                                                       withTemplate: replacement)
            } else if !search.isEmpty {
                stem = stem.replacingOccurrences(of: search, with: replacement,
                    options: caseSensitive ? [.literal] : [.literal, .caseInsensitive])
            }
            switch letterCase {
            case .unchanged: break
            case .lowercase: stem = stem.lowercased()
            case .uppercase: stem = stem.uppercased()
            case .capitalized: stem = stem.capitalized(with: Locale(identifier: "de_DE"))
            }
            var number = ""
            if prefix.contains("{n}") || suffix.contains("{n}") {
                let (offset, overflow1) = index.multipliedReportingOverflow(by: numberStep)
                let (value, overflow2) = numberStart.addingReportingOverflow(offset)
                guard !overflow1, !overflow2 else { throw BatchRenameError("Die Nummerierung ist zu groß.") }
                let magnitude = String(value.magnitude)
                number = (value < 0 ? "-" : "") + String(repeating: "0", count: max(0, numberDigits - magnitude.count)) + magnitude
            }
            let date: Date
            switch dateSource {
            case .now: date = referenceDate
            case .modified: date = source.modified
            case .created: date = source.created
            }
            func expand(_ text: String) -> String {
                text.replacingOccurrences(of: "{n}", with: number)
                    .replacingOccurrences(of: "{date}", with: formatter.string(from: date))
            }
            return expand(prefix) + stem + expand(suffix) + (ext.isEmpty ? "" : "." + ext)
        }
    }
}

public struct BatchRenameError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
