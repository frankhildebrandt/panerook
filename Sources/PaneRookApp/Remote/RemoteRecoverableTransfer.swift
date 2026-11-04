import AppKit
import PaneRookRemote
import PaneRookTasks

extension RemoteBrowser {
    func performRecoverableTransfer(_ record: RecoverableTransfer, remotes: [RemoteFileSystem], completion: @escaping () -> Void) {
        guard !busy, !disconnected else { return }
        // The marker protects the browser UI; TaskCenter owns the actual worker cancellation.
        cancellation = RemoteCancellation()
        buttons.forEach { $0.isEnabled = false }; table.isEnabled = false; pathField.isEnabled = false
        cancel.isHidden = false; spinner.startAnimation(nil); status.stringValue = record.title
        updateNavigation(); onStateChanged?()
        let finish = { [weak self, weak peer] in
            peer?.refreshAfterTask()
            guard let self else { return }
            self.queuedTask = nil; self.cancellation = nil
            self.buttons.forEach { $0.isEnabled = true }; self.table.isEnabled = true; self.pathField.isEnabled = true
            self.cancel.isHidden = true; self.spinner.stopAnimation(nil)
            if !self.disconnected { completion() }
            self.finishOperation(); self.onStateChanged?()
        }
        queuedTask = tasks.submitTransfer(record, remotes: remotes, resolveConflicts: true, completion: finish)
        if queuedTask == nil { finish() }
    }
}
