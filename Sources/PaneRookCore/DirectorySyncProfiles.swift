import Foundation

public struct DirectorySyncProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var left: URL
    public var right: URL
    public var options: DirectorySyncOptions
    public init(id: UUID = UUID(), name: String, left: URL, right: URL, options: DirectorySyncOptions) {
        self.id = id; self.name = name; self.left = left; self.right = right; self.options = options
    }
}

/// Versioned, separate preferences key; invalid archives are never silently overwritten.
/// Profiles store configuration, never a reusable authorization or a stale execution plan.
public final class DirectorySyncProfileStore {
    private struct Archive: Codable { var version = 1; var profiles: [DirectorySyncProfile] }
    private let defaults: UserDefaults
    private let key = "PaneRook.directorySyncProfiles.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func profiles() throws -> [DirectorySyncProfile] {
        guard let raw = defaults.object(forKey: key) else { return [] }
        guard let data = raw as? Data, let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
              Set(archive.profiles.map(\.id)).count == archive.profiles.count,
              archive.profiles.allSatisfy(Self.valid) else { throw DirectorySyncError.invalidProfiles }
        return archive.profiles
    }
    public func save(_ profile: DirectorySyncProfile) throws {
        guard Self.valid(profile) else { throw DirectorySyncError.invalidProfiles }
        var values = try profiles()
        if let index = values.firstIndex(where: { $0.id == profile.id }) { values[index] = profile }
        else { values.append(profile) }
        defaults.set(try JSONEncoder().encode(Archive(profiles: values)), forKey: key)
    }
    public func remove(_ id: UUID) throws {
        let values = try profiles().filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(Archive(profiles: values)), forKey: key)
    }
    private static func valid(_ profile: DirectorySyncProfile) -> Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && [profile.left, profile.right].allSatisfy { $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }
            && profile.options.exclusions.allSatisfy { !$0.contains("\0") }
    }
}
