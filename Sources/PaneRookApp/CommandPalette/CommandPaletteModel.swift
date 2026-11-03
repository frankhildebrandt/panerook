import Foundation

/// Sources own their policies and actions. The palette only searches and dispatches them.
struct CommandPaletteEntry {
    let id: String
    let title: String
    let detail: String
    var keywords = ""
    var shortcut = ""
    let enabled: () -> Bool
    let run: () -> Void

    @discardableResult func perform() -> Bool {
        guard enabled() else { return false }
        run()
        return true
    }
}

protocol CommandPaletteSource {
    var title: String { get }
    func entries() throws -> [CommandPaletteEntry]
}

struct ClosureCommandPaletteSource: CommandPaletteSource {
    let title: String
    let load: () throws -> [CommandPaletteEntry]
    func entries() throws -> [CommandPaletteEntry] { try load() }
}

final class CommandPaletteModel {
    private(set) var entries: [CommandPaletteEntry] = []
    private(set) var sourceErrors: [String] = []

    func load(_ sources: [any CommandPaletteSource]) {
        entries = []; sourceErrors = []
        var seen = Set<String>()
        for source in sources {
            do { entries += try source.entries().filter { seen.insert($0.id).inserted } }
            catch { sourceErrors.append(source.title + ": " + error.localizedDescription) }
        }
    }

    func results(for query: String) -> [CommandPaletteEntry] {
        let terms = Self.normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.enumerated().compactMap { index, entry -> (Int, Int, CommandPaletteEntry)? in
            guard entry.enabled() else { return nil }
            let fields = [(Self.normalized(entry.title), 500), (Self.normalized(entry.detail), 0),
                          (Self.normalized(entry.keywords + " " + entry.shortcut), -200)]
            var total = 0
            for term in terms {
                guard let best = fields.compactMap({ field, weight in
                    Self.score(term, in: field).map { $0 + weight }
                }).max() else { return nil }
                total += best
            }
            return (total, index, entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "de_DE")).replacingOccurrences(of: "ß", with: "ss")
    }

    /// Exact, prefix and substring matches beat ordered subsequences. Word starts and
    /// consecutive letters help abbreviations; long gaps rank below compact matches.
    private static func score(_ term: String, in text: String) -> Int? {
        if term == text { return 10_000 }
        if text.hasPrefix(term) { return 8_000 - min(text.count, 500) }
        if let range = text.range(of: term) {
            let boundary = range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter
            return 6_000 + (boundary ? 300 : 0) - min(text.count, 500)
        }
        let characters = Array(text)
        var next = 0, previous = -2, first = 0, points = 2_000
        for (index, letter) in term.enumerated() {
            guard let found = characters[next...].firstIndex(of: letter) else { return nil }
            if index == 0 { first = found }
            if found == previous + 1 { points += 80 }
            if found == 0 || !characters[found - 1].isLetter { points += 100 }
            points -= min(found - next, 100) * 4
            previous = found; next = found + 1
        }
        return points - min(first, 100) - min(characters.count, 500)
    }
}
