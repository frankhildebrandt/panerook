import Foundation
import PaneRookTasks

public enum DirectorySyncDirection: String, Codable, Sendable { case leftToRight, rightToLeft }

public struct DirectorySyncOptions: Codable, Equatable, Sendable {
    public var direction: DirectorySyncDirection
    public var deleteExtraneous: Bool
    public var exclusions: [String]
    public init(direction: DirectorySyncDirection = .leftToRight, deleteExtraneous: Bool = false, exclusions: [String] = []) {
        self.direction = direction; self.deleteExtraneous = deleteExtraneous; self.exclusions = exclusions
    }
    /// Shell globs, case sensitive. A pattern without '/' matches names at any depth;
    /// otherwise it matches a path relative to the root. Excluded directories prune their subtree.
    public func excludes(_ path: String) -> Bool {
        exclusions.contains { raw in
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !pattern.isEmpty && LocalInspection.matches(pattern.contains("/") ? path : (path as NSString).lastPathComponent, pattern: pattern)
        }
    }
}

public struct DirectorySyncAction: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case createDirectory, addFile, updateFile, deleteFile, deleteDirectory, blocked
        public var isDeletion: Bool { self == .deleteFile || self == .deleteDirectory }
        public var label: String {
            switch self {
            case .createDirectory: return "Ordner anlegen"
            case .addFile: return "Datei hinzufügen"
            case .updateFile: return "Datei aktualisieren"
            case .deleteFile: return "Datei löschen"
            case .deleteDirectory: return "Ordner löschen"
            case .blocked: return "Gesperrt"
            }
        }
    }
    public let relativePath: String
    public var id: String { relativePath }
    public let kind: Kind
    public let bytes: Int64
    public let detail: String?
    public var isSelectable: Bool { kind != .blocked }
}

public struct DirectorySyncPlan: Sendable {
    public let source: URL
    public let destination: URL
    public let options: DirectorySyncOptions
    public let actions: [DirectorySyncAction]
    public let excludedCount: Int
    let sourceInventory: SyncInventory
    let destinationInventory: SyncInventory
    public var defaultSelection: Set<String> { Set(actions.filter(\.isSelectable).map(\.id)) }
    public func selecting(_ id: String, included: Bool, in selection: Set<String>) -> Set<String> {
        var result = selection
        guard let action = actions.first(where: { $0.id == id }), action.isSelectable else { return result }
        let children = actions.filter { $0.isSelectable && $0.id.hasPrefix(id + "/") }
        if included {
            result.insert(id)
            if action.kind == .createDirectory || action.kind == .deleteDirectory { result.formUnion(children.map(\.id)) }
            for parent in actions where parent.kind == .createDirectory && id.hasPrefix(parent.id + "/") { result.insert(parent.id) }
        } else {
            result.remove(id)
            if action.kind == .createDirectory || action.kind == .deleteDirectory { result.subtract(children.map(\.id)) }
            for parent in actions where parent.kind == .deleteDirectory && id.hasPrefix(parent.id + "/") { result.remove(parent.id) }
        }
        return result
    }
    public func transferBytes(selected: Set<String>) -> Int64 {
        actions.filter { selected.contains($0.id) && ($0.kind == .addFile || $0.kind == .updateFile) }.reduce(0) { $0 + $1.bytes }
    }
}

public enum DirectorySyncError: LocalizedError {
    case invalidRoots, changed(String), invalidSelection(String), invalidProfiles
    public var errorDescription: String? {
        switch self {
        case .invalidRoots: return "Bitte zwei getrennte lokale Ordner wählen. Identische oder ineinander verschachtelte Ordner sind nicht zulässig."
        case .changed(let path): return "Seit der Vorschau geändert oder nicht mehr sicher erreichbar: \(path). Bitte eine neue Vorschau erstellen. Bereits abgeschlossene Aktionen bleiben erhalten."
        case .invalidSelection(let path): return "Die Auswahl benötigt auch die zugehörigen Ordner-/Unteraktionen: \(path)."
        case .invalidProfiles: return "Die gespeicherten Synchronisationsprofile sind ungültig und wurden nicht verändert."
        }
    }
}

public enum DirectorySync {
    public static func plan(left: URL, right: URL, options: DirectorySyncOptions = .init(),
                            cancellation: TransferCancellation = .init(), maximumEntries: Int = 100_000,
                            maximumFileBytes: Int64 = 1_073_741_824,
                            progress: @escaping (OperationProgress) -> Void = { _ in }) throws -> DirectorySyncPlan {
        let roots = try SyncRoot.pair(left, right)
        let source = options.direction == .leftToRight ? roots.0 : roots.1
        let target = options.direction == .leftToRight ? roots.1 : roots.0
        let a = try source.inventory(options: options, cancellation: cancellation, maximumEntries: maximumEntries,
                                     maximumFileBytes: maximumFileBytes, progress: progress)
        let b = try target.inventory(options: options, cancellation: cancellation, maximumEntries: maximumEntries,
                                     maximumFileBytes: maximumFileBytes, progress: progress)
        var actions: [DirectorySyncAction] = []
        let paths = Set(a.items.keys).union(b.items.keys).union(a.problems.keys).union(b.problems.keys).sorted()
        let problems = a.problems.merging(b.problems) { first, _ in first }
        let problemPaths = Set(problems.keys)
        let excludedParents = Set(b.excluded.flatMap(syncParentPaths))
        for (index, path) in paths.enumerated() {
            try cancellation.check()
            progress(OperationProgress(completedItems: index, totalItems: paths.count, currentPath: path))
            let ai = a.items[path], bi = b.items[path]
            var kind: DirectorySyncAction.Kind?
            var detail: String?
            if let problem = problems[path] { kind = .blocked; detail = problem }
            else if syncParentPaths(path).contains(where: problemPaths.contains) { continue }
            else if ai?.type == .symlink || bi?.type == .symlink {
                kind = .blocked; detail = "Symbolischer Link: wird weder verfolgt noch verändert."
            } else if let ai, let bi, ai.type != bi.type {
                kind = .blocked; detail = "Typkonflikt: Datei und Ordner werden nicht automatisch ersetzt."
            } else if ai == nil, let bi {
                guard options.deleteExtraneous else { continue }
                if !a.problems.isEmpty {
                    kind = .blocked; detail = "Löschung gesperrt: Quelle konnte nicht vollständig gelesen werden."
                } else if bi.type == .directory && excludedParents.contains(path) {
                    kind = .blocked; detail = "Ordner enthält ausgeschlossene Einträge und bleibt erhalten."
                } else { kind = bi.type == .directory ? .deleteDirectory : .deleteFile }
            } else if let ai, bi == nil { kind = ai.type == .directory ? .createDirectory : .addFile }
            else if let ai, let bi, ai.type == .file {
                // Fingerprints protect execution; retain the existing byte-exact comparison contract.
                let token = InspectionCancellation()
                let comparison = try LocalInspection.compareFiles(source.url.appendingPathComponent(path), target.url.appendingPathComponent(path), cancellation: token, maximumBytes: maximumFileBytes) { file in
                    if cancellation.isCancelled { token.cancel() }
                    progress(OperationProgress(completedItems: index, totalItems: paths.count, currentPath: path,
                        currentFileBytes: file.currentFileBytes, currentFileTotalBytes: file.currentFileTotalBytes))
                }
                if !comparison.equal { kind = .updateFile }
                // A changing comparison must never authorize overwriting either version.
                guard try source.snapshot(path, cancellation: cancellation, maximumFileBytes: maximumFileBytes) == ai,
                      try target.snapshot(path, cancellation: cancellation, maximumFileBytes: maximumFileBytes) == bi else {
                    throw DirectorySyncError.changed(path)
                }
            }
            if let kind { actions.append(.init(relativePath: path, kind: kind, bytes: (ai ?? bi)?.size ?? 0, detail: detail)) }
        }
        // A retained child keeps its parent directory; other independent actions remain selectable.
        let retained = Set(actions.filter { !$0.isSelectable }.map(\.id)).union(b.excluded)
        let retainedParents = Set(retained.flatMap(syncParentPaths))
        actions = actions.map { action in
            if action.kind == .deleteDirectory && retainedParents.contains(action.id) {
                return DirectorySyncAction(relativePath: action.id, kind: .blocked, bytes: 0,
                    detail: "Ordner enthält gesperrte oder ausgeschlossene Einträge und bleibt erhalten.")
            }
            return action
        }
        // Suppress descendants of conflicts/links: no action may traverse a blocked parent.
        let blocked = Set(paths.filter { path in
            problems[path] != nil || a.items[path]?.type == .symlink || b.items[path]?.type == .symlink
                || (a.items[path] != nil && b.items[path] != nil && a.items[path]?.type != b.items[path]?.type)
        })
        actions.removeAll { action in syncParentPaths(action.id).contains(where: blocked.contains) }
        return DirectorySyncPlan(source: source.url, destination: target.url, options: options, actions: actions,
            excludedCount: a.excluded.count + b.excluded.count, sourceInventory: a, destinationInventory: b)
    }

    public static func execute(_ plan: DirectorySyncPlan, selected: Set<String>,
                               cancellation: TransferCancellation = .init(),
                               progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        try SyncExecutor(plan: plan, selected: selected, cancellation: cancellation, progress: progress).run()
    }
}

/// Includes the root marker, excluding the entry itself.
func syncParentPaths(_ path: String) -> [String] {
    guard !path.isEmpty else { return [] }
    var result = [""]; var parent = ""
    for component in path.split(separator: "/").dropLast() {
        parent = parent.isEmpty ? String(component) : parent + "/" + component
        result.append(parent)
    }
    return result
}
