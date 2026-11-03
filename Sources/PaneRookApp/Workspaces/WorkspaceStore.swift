import Foundation
import PaneRookRemote

/// Only restorable configuration. Never contains a RemoteConnection, credentials,
/// file listings, task sources/targets, terminal scrollback or running processes.
struct WorkspaceTab: Codable, Equatable, Identifiable {
    var id = UUID()
    var directory: URL
    var mode = "listing"
    var terminalDirectory: URL?
    var connection: ConnectionBookmark?
    var sortKey = "name"
    var sortAscending = true
    var brief = false
    var filter = ""
    var gitFilter = "all"
    var encoding = String.Encoding.utf8.rawValue
    var showHidden = false
}

struct WorkspacePanelGroup: Codable, Equatable {
    var tabs: [WorkspaceTab]
    var activeTab: UUID
    init(tabs: [WorkspaceTab], activeTab: UUID? = nil) {
        self.tabs = tabs
        self.activeTab = activeTab ?? tabs[0].id
    }
}

struct ProjectWorkspace: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var left: WorkspacePanelGroup
    var right: WorkspacePanelGroup
    var activeRight = false
}

struct WorkspaceArchive: Codable, Equatable {
    var version = 1
    var session: ProjectWorkspace?
    var workspaces: [ProjectWorkspace] = []

    func validated() throws -> Self {
        guard version == 1 else { throw WorkspaceError.invalidArchive }
        var ids = Set<UUID>(), names = Set<String>()
        for workspace in workspaces {
            guard ids.insert(workspace.id).inserted,
                  !workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !workspace.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  names.insert(workspace.name.lowercased()).inserted else { throw WorkspaceError.invalidArchive }
        }
        for workspace in workspaces + [session].compactMap({ $0 }) {
            for group in [workspace.left, workspace.right] {
                guard !group.tabs.isEmpty, Set(group.tabs.map(\.id)).count == group.tabs.count,
                      group.tabs.contains(where: { $0.id == group.activeTab }) else { throw WorkspaceError.invalidArchive }
                for tab in group.tabs {
                    guard tab.directory.isFileURL, tab.directory.path.hasPrefix("/"),
                          !tab.directory.path.contains("\0"),
                          tab.terminalDirectory.map({ $0.isFileURL && !$0.path.contains("\0") }) ?? true,
                          ["listing", "quickView", "info", "tree", "network", "gitHistory", "terminal"].contains(tab.mode),
                          ["name", "size", "modified"].contains(tab.sortKey) else { throw WorkspaceError.invalidArchive }
                }
            }
        }
        return self
    }
}

enum WorkspaceError: LocalizedError {
    case invalidArchive, invalidName
    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Die gespeicherten Arbeitsbereiche sind ungültig oder haben eine neuere Version. Die Daten wurden nicht überschrieben."
        case .invalidName: return "Bitte einen eindeutigen Namen ohne Steuerzeichen eingeben."
        }
    }
}

final class WorkspaceStore {
    static let key = "projectWorkspaces.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() throws -> WorkspaceArchive {
        guard let data = defaults.data(forKey: Self.key) else { return WorkspaceArchive() }
        do { return try JSONDecoder().decode(WorkspaceArchive.self, from: data).validated() }
        catch { throw WorkspaceError.invalidArchive }
    }
    func save(_ archive: WorkspaceArchive) throws {
        // Do not overwrite a corrupt or future archive with a fallback session.
        _ = try load()
        defaults.set(try JSONEncoder().encode(archive.validated()), forKey: Self.key)
    }
}
