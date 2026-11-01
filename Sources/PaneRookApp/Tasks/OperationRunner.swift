import Foundation
import PaneRookCore
import PaneRookTasks

/// Shared operation submission, independent of panels and feature controllers.
final class OperationRunner {
    private let tasks: TaskCenter
    private let refresh: () -> Void
    init(tasks: TaskCenter, refresh: @escaping () -> Void) {
        self.tasks = tasks
        self.refresh = refresh
    }
    func runOperation(
        _ title: String, completion: (() -> Void)? = nil,
        errorDetail: String =
            "Bei mehreren Einträgen können vorherige Schritte bereits abgeschlossen sein. Bitte beide Panels prüfen.",
        work: @escaping () throws -> Void
    ) {
        tasks.submit(
            title: title, detail: errorDetail, work: { _ in try work() },
            completion: { [weak self] result in
                if case .success = result { completion?() }
                self?.refresh()
            })
    }
    func runArchiveOperation(
        _ title: String, detail: String, completion: (() -> Void)? = nil,
        work: @escaping (TransferCancellation, @escaping (OperationProgress) -> Void) throws -> Void
    ) {
        let token = TransferCancellation()
        tasks.submit(
            title: title, detail: detail, cancellation: { token.cancel() },
            work: { report in try work(token, report) },
            completion: { [weak self] result in
                if case .success = result { completion?() }
                self?.refresh()
            })
    }
    /// Checkpoints between native filesystem calls keep batch actions cancellable.
    func runItemOperation(_ title: String, sources: [URL], work: @escaping (URL) throws -> Void) {
        let token = InspectionCancellation()
        tasks.submit(
            title: title, detail: "Bereits abgeschlossene Einträge bleiben bei Abbruch erhalten.",
            cancellation: { token.cancel() },
            work: { report in
                for (index, source) in sources.enumerated() {
                    try token.check()
                    report(
                        OperationProgress(completedItems: index, totalItems: sources.count, currentPath: source.path))
                    try work(source)
                    report(
                        OperationProgress(
                            completedItems: index + 1, totalItems: sources.count, currentPath: source.path))
                }
            }, completion: { [weak self] _ in self?.refresh() })
    }
}
