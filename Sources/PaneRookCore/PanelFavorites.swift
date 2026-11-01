import Foundation
import Darwin

public enum FavoriteLocationKind: String, Codable, CaseIterable, Sendable {
    case iCloudDrive, protonDrive, dropbox
}

public struct FavoriteLocation: Equatable, Sendable {
    public let kind: FavoriteLocationKind
    public let urls: [URL]
    public init(kind: FavoriteLocationKind, urls: [URL]) { self.kind = kind; self.urls = urls }
}

/// Detects provider roots only. It never traverses or reads cloud-file contents.
/// Missing providers have empty roots so the UI can omit unavailable defaults.
public enum FavoriteLocationResolver {
    public static func locations(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [FavoriteLocation] {
        guard home.isFileURL, !home.path.contains("\0") else {
            return FavoriteLocationKind.allCases.map { FavoriteLocation(kind: $0, urls: []) }
        }
        let storage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let children = ((try? FileManager.default.contentsOfDirectory(at: storage,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []).sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
        func roots(_ kind: FavoriteLocationKind) -> [URL] {
            var candidates: [URL]
            switch kind {
            case .iCloudDrive:
                candidates = [home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)]
            case .protonDrive:
                candidates = children.filter { matchesProvider($0.lastPathComponent, names: ["protondrive", "proton drive"]) }
                candidates.append(home.appendingPathComponent("Proton Drive", isDirectory: true))
            case .dropbox:
                candidates = children.filter { matchesProvider($0.lastPathComponent, names: ["dropbox"]) }
                candidates.append(home.appendingPathComponent("Dropbox", isDirectory: true))
            }
            var seen = Set<String>()
            return candidates.filter { url in
                guard isReachableDirectory(url) else { return false }
                // Legacy roots may be symlinks to a File Provider domain. Show
                // each physical root once while retaining the provider's path.
                return seen.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted
            }.map(\.standardizedFileURL)
        }
        return FavoriteLocationKind.allCases.map { FavoriteLocation(kind: $0, urls: roots($0)) }
    }

    private static func matchesProvider(_ name: String, names: [String]) -> Bool {
        let value = name.lowercased()
        return names.contains { provider in
            value == provider
                || (value.hasPrefix(provider + "-") && value.count > provider.count + 1)
                || (value.hasPrefix(provider + " (") && value.hasSuffix(")") && value.count > provider.count + 3)
        }
    }

    fileprivate static func isReachableDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, !url.path.contains("\0") else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue && access(url.path, R_OK | X_OK) == 0
    }
}

public enum PanelFavoriteError: LocalizedError {
    case invalidFolder, invalidPreferences
    public var errorDescription: String? {
        switch self {
        case .invalidFolder: return "Bitte einen erreichbaren lokalen Ordner als Favorit auswählen."
        case .invalidPreferences: return "Die gespeicherten Ordnerfavoriten sind ungültig. Sie wurden nicht verändert."
        }
    }
}

/// Shares the existing hotlist key with the MC hotlist. Reading favorites does
/// not probe their availability, so offline disks and shares remain bookmarked.
public final class PanelFavoriteStore {
    private let defaults: UserDefaults
    private let overrideKey = "PaneRook.favoriteLocations"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func folders() throws -> [URL] {
        guard let object = defaults.object(forKey: "hotlist") else { return [] }
        guard let paths = object as? [String] else { throw PanelFavoriteError.invalidPreferences }
        var seen = Set<String>()
        var result: [URL] = []
        for path in paths {
            guard validStoredPath(path) else { throw PanelFavoriteError.invalidPreferences }
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            if seen.insert(url.path).inserted { result.append(url) }
        }
        return result
    }

    public func addFolder(_ url: URL) throws {
        let value = try validatedDirectory(url)
        var values = try folders()
        guard !values.contains(where: { $0.path == value.path }) else { return }
        values.append(value)
        defaults.set(values.map(\.path), forKey: "hotlist")
    }

    public func removeFolder(_ url: URL) throws {
        guard url.isFileURL, validStoredPath(url.path) else { throw PanelFavoriteError.invalidFolder }
        let path = url.standardizedFileURL.path
        let values = try folders().filter { $0.path != path }
        defaults.set(values.map(\.path), forKey: "hotlist")
    }

    public func overrideLocation(_ kind: FavoriteLocationKind, with url: URL) throws {
        let value = try validatedDirectory(url)
        let object = defaults.object(forKey: overrideKey)
        guard object == nil || object is [String: String] else { throw PanelFavoriteError.invalidPreferences }
        var locations = object as? [String: String] ?? [:]
        locations[kind.rawValue] = value.path
        defaults.set(locations, forKey: overrideKey)
    }

    public func overriddenLocation(_ kind: FavoriteLocationKind) -> URL? {
        guard let locations = defaults.dictionary(forKey: overrideKey),
              let path = locations[kind.rawValue] as? String, validStoredPath(path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public func clearOverrideLocation(_ kind: FavoriteLocationKind) {
        guard var locations = defaults.dictionary(forKey: overrideKey) else { return }
        locations.removeValue(forKey: kind.rawValue)
        if locations.isEmpty { defaults.removeObject(forKey: overrideKey) }
        else { defaults.set(locations, forKey: overrideKey) }
    }

    private func validatedDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, validStoredPath(url.path), FavoriteLocationResolver.isReachableDirectory(url) else {
            throw PanelFavoriteError.invalidFolder
        }
        return url.standardizedFileURL
    }
    private func validStoredPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
