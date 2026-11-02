import AppKit

extension NSTableView {
    /// MC-style list navigation moves selection and viewport together.
    func handleListNavigation(_ event: NSEvent, defaults: UserDefaults = .standard) -> Bool {
        guard !KeyboardCaptureState.isRecording else { return false }
        guard let action = ContextCommands.matching(event, scope: .table, defaults: defaults) else {
            // Swallow replaced list keys before NSTableView can execute its native defaults.
            return ContextCommands.definitions.contains { $0.scope == .table && $0.defaultBinding?.matches(event) == true }
        }
        let home = action == "table.home"
        let end = action == "table.end"
        if home || end {
            guard isEnabled, numberOfRows > 0 else { return true }
            let destination = home ? 0 : numberOfRows - 1
            selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
            scrollRowToVisible(destination)
            return true
        }
        let direction: Int
        if action == "table.pageUp" { direction = -1 }
        else if action == "table.pageDown" { direction = 1 }
        else { return false }

        guard isEnabled, numberOfRows > 0 else { return true }
        let viewport = visibleRect
        let visibleRows = rows(in: viewport)
        // Keep one row of overlap and still work for a very short/empty viewport.
        let stride = max(1, min(numberOfRows, visibleRows.length) - 1)
        let firstVisible = visibleRows.location == NSNotFound ? 0 : min(visibleRows.location, numberOfRows - 1)
        let current = selectedRow >= 0 ? min(selectedRow, numberOfRows - 1) : firstVisible
        let destination = min(numberOfRows - 1, max(0, current + direction * stride))
        let offset = rect(ofRow: destination).minY - rect(ofRow: current).minY

        selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        let maximumY = max(bounds.minY, bounds.maxY - viewport.height)
        let newY = min(maximumY, max(bounds.minY, viewport.minY + offset))
        scroll(NSPoint(x: viewport.minX, y: newY))
        scrollRowToVisible(destination)
        return true
    }
}
