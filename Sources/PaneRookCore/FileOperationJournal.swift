import Foundation
import PaneRookTasks
import Darwin

public enum FileJournalError: LocalizedError {
    case conflict(URL, String)
    case unavailable
    case unstable(URL)
    case partial(String, Int, Int, String)
    public var errorDescription: String? {
        switch self {
        case .conflict(let url, let reason): return "\(url.path): \(reason) Es wurde nichts überschrieben."
        case .unstable(let url): return "\(url.path): Während der Zustandsprüfung verändert; bitte erneut versuchen."
        case .unavailable: return "Keine passende Dateiaktion im Operationsprotokoll verfügbar."
        case .partial(let title, let completed, let total, let reason):
            return "\(title): \(completed) von \(total) Einträgen abgeschlossen. \(reason) Bereits abgeschlossene Schritte bleiben protokolliert. Noch offene Schritte lassen sich nach Beheben des Konflikts erneut versuchen."
        }
    }
}

public struct FileJournalAction: Sendable {
    public let id: UUID
    public let title: String
    public let paths: [String]
    public var description: String {
        title + (paths.count == 1 ? " „\(URL(fileURLWithPath: paths[0]).lastPathComponent)“" : " (\(paths.count) Einträge)")
    }
}

public struct FileJournalEvent: Sendable {
    public let date: Date
    public let title: String
    public let paths: [String]
    public let completed: Int
    public let total: Int
    public let error: String?
}

/// In-memory session journal. Work is serialized independently of the UI; snapshots never do I/O.
/// Successful steps survive cancellation/errors. Undo/redo split partial batches into precisely
/// the remaining and completed steps, so retries never repeat already completed mutations.
public final class FileOperationJournal: @unchecked Sendable {
    public typealias Trash = (URL) throws -> URL
    private enum Step {
        case move(FileOperationPath, FileOperationPath, FileOperationSnapshot?, restoreFromTrash: Bool)
        case trash(FileOperationPath, FileOperationSnapshot?)
        case removeDirectory(FileOperationPath, FileOperationSnapshot?)
        case createDirectory(FileOperationPath, replacing: FileOperationIdentity?)

        var path: URL {
            switch self {
            case .move(let from, _, _, _), .trash(let from, _), .removeDirectory(let from, _), .createDirectory(let from, _): return from.url
            }
        }
        var missingSnapshot: Bool {
            switch self {
            case .move(_, _, let snapshot, _), .trash(_, let snapshot), .removeDirectory(_, let snapshot): return snapshot == nil
            case .createDirectory: return false
            }
        }
        var detail: String {
            switch self {
            case .move(let from, let to, _, _): return "\(from.url.path) → \(to.url.path)"
            default: return path.path
            }
        }
    }
    private struct Batch {
        let id: UUID
        let title: String
        var steps: [Step]
        var action: FileJournalAction { FileJournalAction(id: id, title: title, paths: steps.map { $0.path.path }) }
    }
    private let stateLock = NSLock()
    private let operationLock = NSLock()
    private var undoStack: [Batch] = []
    private var redoStack: [Batch] = []
    private var events: [FileJournalEvent] = []
    private let limit: Int
    private let trash: Trash

    public init(limit: Int = 100, trash: @escaping Trash = FileOperationJournal.systemTrash) {
        self.limit = max(1, limit); self.trash = trash
    }

    public static func systemTrash(_ source: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &result)
        guard let result else {
            throw FileJournalError.conflict(source, "Im Papierkorb abgelegt, aber macOS hat keinen Wiederherstellungspfad geliefert. Bitte im Finder prüfen.")
        }
        return result as URL
    }

    public var nextUndo: FileJournalAction? { stateLock.lock(); defer { stateLock.unlock() }; return undoStack.last?.action }
    public var nextRedo: FileJournalAction? { stateLock.lock(); defer { stateLock.unlock() }; return redoStack.last?.action }
    public var history: [FileJournalEvent] { stateLock.lock(); defer { stateLock.unlock() }; return events }

    public func move(_ plan: TransferPlan, title: String = "Verschieben", cancellation: TransferCancellation = .init(),
                     progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard plan.kind == .move, !plan.items.isEmpty,
              plan.items.allSatisfy({ ArchiveFileSystem.memberLocation($0.source) == nil && ArchiveFileSystem.memberLocation($0.destination) == nil }) else {
            throw FileJournalError.unavailable
        }
        let steps = try plan.items.map { item -> Step in
            try cancellation.check()
            let from = try FileOperationPath(item.source), to = try FileOperationPath(item.destination)
            try to.requireAbsent()
            return .move(from, to, try FileOperationSnapshot.capture(from.url, cancellation: cancellation), restoreFromTrash: false)
        }
        try run(Batch(id: UUID(), title: title, steps: steps), direction: .forward, cancellation: cancellation, progress: progress)
    }

    /// Adopt already committed moves from a recoverable worker without replaying any filesystem action.
    /// The caller validates its durable manifest before and after snapshot capture. Unsafe entries are
    /// reported in history and are never admitted to the undo stack.
    public func recordCompletedMoves(_ items: [(source: URL, destination: URL)], title: String,
                                     validate: (URL, URL) throws -> Void) {
        guard !items.isEmpty else { return }
        operationLock.lock(); defer { operationLock.unlock() }
        var inverses: [Step] = [], warnings: [String] = []
        for item in items {
            do {
                let original = try FileOperationPath(item.source), destination = try FileOperationPath(item.destination)
                try original.requireAbsent()
                try validate(item.source, item.destination)
                let snapshot = try FileOperationSnapshot.capture(destination.url, cancellation: TransferCancellation())
                try validate(item.source, item.destination)
                inverses.append(.move(destination, original, snapshot, restoreFromTrash: false))
            } catch { warnings.append("\(item.destination.path): Datei-Undo nicht verfügbar. " + error.localizedDescription) }
        }
        stateLock.lock(); defer { stateLock.unlock() }
        if !inverses.isEmpty { undoStack.append(Batch(id: UUID(), title: title, steps: inverses.reversed())) }
        redoStack.removeAll()
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        events.append(FileJournalEvent(date: Date(), title: title, paths: items.map { "\($0.source.path) → \($0.destination.path)" },
            completed: items.count, total: items.count, error: warnings.isEmpty ? nil : warnings.joined(separator: "\n")))
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    public func createDirectory(named name: String, in directory: URL, cancellation: TransferCancellation = .init(),
                                progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try FileActions.validateName(name)
        guard ArchiveFileSystem.location(for: directory) == nil else { throw FileJournalError.unavailable }
        let path = try FileOperationPath(directory.appendingPathComponent(name))
        try run(Batch(id: UUID(), title: "Ordner anlegen", steps: [.createDirectory(path, replacing: nil)]), direction: .forward,
            cancellation: cancellation, progress: progress)
    }

    public func trash(_ sources: [URL], cancellation: TransferCancellation = .init(),
                      progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        guard !sources.isEmpty, sources.allSatisfy({ ArchiveFileSystem.memberLocation($0) == nil }) else { throw FileJournalError.unavailable }
        let steps = try sources.map { source -> Step in
            let path = try FileOperationPath(source)
            return .trash(path, try FileOperationSnapshot.capture(path.url, cancellation: cancellation))
        }
        try run(Batch(id: UUID(), title: "In den Papierkorb legen", steps: steps), direction: .forward,
            cancellation: cancellation, progress: progress)
    }

    public func undo(expectedID: UUID, cancellation: TransferCancellation = .init(),
                     progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        try restore(.undo, expectedID: expectedID, cancellation: cancellation, progress: progress)
    }
    public func redo(expectedID: UUID, cancellation: TransferCancellation = .init(),
                     progress: @escaping (OperationProgress) -> Void = { _ in }) throws {
        try restore(.redo, expectedID: expectedID, cancellation: cancellation, progress: progress)
    }
    private enum Direction { case forward, undo, redo }
    private func restore(_ direction: Direction, expectedID: UUID, cancellation: TransferCancellation,
                         progress: @escaping (OperationProgress) -> Void) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        stateLock.lock()
        let batch = (direction == .undo ? undoStack : redoStack).last
        stateLock.unlock()
        guard let batch, batch.id == expectedID else { throw FileJournalError.unavailable }
        try run(batch, direction: direction, cancellation: cancellation, progress: progress)
    }

    private func run(_ batch: Batch, direction: Direction, cancellation: TransferCancellation,
                     progress: @escaping (OperationProgress) -> Void) throws {
        var inverses: [Step] = []
        var failure: Error?
        let title = (direction == .undo ? "Rückgängig: " : direction == .redo ? "Wiederholen: " : "") + batch.action.description
        do {
            for (index, step) in batch.steps.enumerated() {
                try cancellation.check()
                progress(OperationProgress(completedItems: index, totalItems: batch.steps.count, currentPath: step.path.path))
                let inverse = try execute(step, cancellation: cancellation, progress: progress)
                inverses.append(inverse)
                if inverse.missingSnapshot {
                    throw FileJournalError.conflict(inverse.path, "Schritt ausgeführt, aber der neue Zustand konnte nicht sicher erfasst werden. Dieser Eintrag muss manuell geprüft werden und kann nicht automatisch rückgängig gemacht werden.")
                }
                progress(OperationProgress(completedItems: index + 1, totalItems: batch.steps.count, currentPath: step.path.path))
            }
        } catch { failure = error }
        let inverse = Batch(id: UUID(), title: batch.title, steps: inverses.reversed())
        stateLock.lock()
        switch direction {
        case .forward:
            if !inverses.isEmpty { undoStack.append(inverse); redoStack.removeAll() }
        case .undo, .redo:
            var source = direction == .undo ? undoStack : redoStack
            var destination = direction == .undo ? redoStack : undoStack
            source.removeLast()
            let remaining = Array(batch.steps.dropFirst(inverses.count))
            if !remaining.isEmpty { source.append(Batch(id: batch.id, title: batch.title, steps: remaining)) }
            if !inverses.isEmpty { destination.append(inverse) }
            if direction == .undo { undoStack = source; redoStack = destination }
            else { redoStack = source; undoStack = destination }
        }
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        if redoStack.count > limit { redoStack.removeFirst(redoStack.count - limit) }
        events.append(FileJournalEvent(date: Date(), title: title, paths: batch.steps.map(\.detail), completed: inverses.count,
            total: batch.steps.count, error: failure?.localizedDescription))
        if events.count > limit { events.removeFirst(events.count - limit) }
        stateLock.unlock()
        if let failure { throw FileJournalError.partial(title, inverses.count, batch.steps.count, failure.localizedDescription) }
    }

    private func rebindParent(_ directory: URL, from old: FileOperationIdentity, to new: FileOperationIdentity) {
        func rebind(_ step: Step) -> Step {
            func path(_ value: FileOperationPath) -> FileOperationPath { value.rebindingParent(directory, from: old, to: new) }
            switch step {
            case .move(let source, let target, let expected, let trash): return .move(path(source), path(target), expected, restoreFromTrash: trash)
            case .trash(let source, let expected): return .trash(path(source), expected)
            case .removeDirectory(let source, let expected): return .removeDirectory(path(source), expected)
            case .createDirectory(let source, let identity): return .createDirectory(path(source), replacing: identity)
            }
        }
        stateLock.lock(); defer { stateLock.unlock() }
        for index in undoStack.indices { undoStack[index].steps = undoStack[index].steps.map(rebind) }
        for index in redoStack.indices { redoStack[index].steps = redoStack[index].steps.map(rebind) }
    }

    private func verify(_ path: FileOperationPath, expected: FileOperationSnapshot?, cancellation: TransferCancellation) throws {
        try path.validateParent()
        guard let expected else { throw FileJournalError.conflict(path.url, "Zustand nach dem letzten Schritt konnte nicht erfasst werden; Wiederherstellung nur manuell möglich.") }
        guard try FileOperationSnapshot.capture(path.url, cancellation: cancellation) == expected else {
            throw FileJournalError.conflict(path.url, "Identität, Inhalt oder Attribute haben sich seit der Aktion geändert.")
        }
    }

    private func execute(_ step: Step, cancellation: TransferCancellation,
                         progress: @escaping (OperationProgress) -> Void) throws -> Step {
        switch step {
        case .move(let from, let to, let expected, let restoreFromTrash):
            try to.requireAbsent()
            try verify(from, expected: expected, cancellation: cancellation)
            try cancellation.check()
            let plan = try TransferPlan(sources: [from.url], outputs: [to.url], kind: .move)
            try TransferWorker(plan: plan, cancellation: cancellation, progress: progress, validateMoveSource: { committed in
                try to.validateParent()
                try self.verify(from, expected: expected, cancellation: committed ? TransferCancellation() : cancellation)
            }).run()
            // A committed step must be journalled even if cancellation arrives just afterwards.
            let result = try? FileOperationSnapshot.capture(to.url, cancellation: TransferCancellation())
            return restoreFromTrash ? .trash(to, result) : .move(to, from, result, restoreFromTrash: false)
        case .trash(let from, let expected):
            try verify(from, expected: expected, cancellation: cancellation)
            try cancellation.check()
            let output = try trash(from.url)
            let path = try FileOperationPath(output)
            // Rebuild a path URL; do not reuse cached resource values from macOS's returned NSURL.
            let result = try? FileOperationSnapshot.capture(path.url, cancellation: TransferCancellation())
            return .move(path, from, result, restoreFromTrash: true)
        case .createDirectory(let path, let previousIdentity):
            try path.requireAbsent(); try cancellation.check()
            try FileManager.default.createDirectory(at: path.url, withIntermediateDirectories: false)
            let result = try? FileOperationSnapshot.capture(path.url, cancellation: TransferCancellation())
            if let previousIdentity, let currentIdentity = result?.nodes.last?.identity {
                rebindParent(path.url, from: previousIdentity, to: currentIdentity)
            }
            return .removeDirectory(path, result)
        case .removeDirectory(let path, let expected):
            try verify(path, expected: expected, cancellation: cancellation)
            try cancellation.check()
            // Never remove recursively: a new child racing the check prevents rmdir.
            guard rmdir(path.url.path) == 0 else { throw FileJournalError.conflict(path.url, "Ordner ist nicht leer oder kann nicht entfernt werden.") }
            return .createDirectory(path, replacing: expected?.nodes.last?.identity)
        }
    }
}
