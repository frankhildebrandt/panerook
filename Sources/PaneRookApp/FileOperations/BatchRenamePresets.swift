import Foundation
import PaneRookCore

/// Separate, versioned keys leave existing keyboard and transfer settings intact.
final class BatchRenamePresets {
    struct Preset: Codable, Equatable {
        let name: String
        let rules: BatchRenameRules
    }
    private let defaults: UserDefaults
    private let key = "files.batchRename.presets.v1"
    private let lastKey = "files.batchRename.lastRules.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var presets: [Preset] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }
    var lastRules: BatchRenameRules {
        guard let data = defaults.data(forKey: lastKey),
              let rules = try? JSONDecoder().decode(BatchRenameRules.self, from: data) else { return .init() }
        return rules
    }
    func remember(_ rules: BatchRenameRules) throws {
        defaults.set(try JSONEncoder().encode(rules), forKey: lastKey)
    }
    func save(name: String, rules: BatchRenameRules) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw BatchRenameError("Bitte einen Preset-Namen mit 1 bis 100 Zeichen eingeben.") }
        var values = presets.filter { $0.name != name }
        values.append(Preset(name: name, rules: rules))
        values.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }
    func remove(name: String) throws {
        defaults.set(try JSONEncoder().encode(presets.filter { $0.name != name }), forKey: key)
    }
}
