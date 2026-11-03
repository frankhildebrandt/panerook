import Foundation
import PaneRookCore

extension FileOperations {
    var canBatchRenameSelection: Bool {
        guard owner.canUseSelection, owner.activePane.remoteContent == nil else { return false }
        let sources = owner.activePane.selectedFiles
        return !sources.isEmpty && sources.allSatisfy {
            $0.isFileURL && (ArchiveFileSystem.location(for: $0)?.memberPath.isEmpty ?? true)
        }
    }
    func batchRenameSelection() {
        guard canBatchRenameSelection, let window = owner.presentationWindow, batchRenameDialog == nil else { return }
        let pane = owner.activePane
        let sources = pane.selectedFiles
        let dialog = BatchRenameDialog(sources: sources) { [weak self] plan in
            guard let self else { return }
            self.batchRenameDialog = nil
            self.owner.activate(pane)
            guard let plan else { return }
            let token = TransferCancellation()
            let reportWindow = BatchRenameReportWindow()
            self.owner.tasks.submit(title: "Mehrfachumbenennen", detail: plan.items.map {
                "\($0.source.url.path) → \($0.destination.path)"
            }.joined(separator: "\n"), cancellation: { token.cancel() }, work: { report in
                try plan.execute(cancellation: token, progress: report)
            }, onReveal: {
                reportWindow.showWindow(nil)
                reportWindow.window?.makeKeyAndOrderFront(nil)
            }, completion: { [weak self] result in
                reportWindow.finish(result, plan: plan)
                self?.owner.refreshAfterTask()
            })
        }
        batchRenameDialog = dialog
        dialog.begin(on: window)
    }
}
