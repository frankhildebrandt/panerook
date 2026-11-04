import AppKit
import PaneRookCore

/// Preserve identities rather than row numbers when sorting inserts new rows.
/// Restoring the clip view never makes the table first responder.
struct ListingPresentation {
    private let selected: Set<URL>
    private let anchor: URL?
    private let offset: CGFloat
    private let origin: NSPoint
    private let fallbackRow: Int

    init(table: NSTableView, entries: [FileEntry]) {
        selected = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].url.standardizedFileURL : nil })
        let origin = table.enclosingScrollView?.contentView.bounds.origin ?? .zero
        self.origin = origin
        let row = table.row(at: NSPoint(x: 0, y: origin.y))
        anchor = entries.indices.contains(row) ? entries[row].url.standardizedFileURL : nil
        offset = row >= 0 ? origin.y - table.rect(ofRow: row).minY : 0
        fallbackRow = table.selectedRow
    }

    func restore(table: NSTableView, entries: [FileEntry]) {
        var indexes = IndexSet(entries.indices.filter { selected.contains(entries[$0].url.standardizedFileURL) })
        if indexes.isEmpty, !selected.isEmpty, !entries.isEmpty {
            indexes.insert(min(max(0, fallbackRow), entries.count - 1))
        }
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        guard let scroll = table.enclosingScrollView else { return }
        var point = origin
        if let anchor, let row = entries.firstIndex(where: { $0.url.standardizedFileURL == anchor }) {
            point.y = table.rect(ofRow: row).minY + offset
        }
        point.y = max(0, min(point.y, table.bounds.height - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: point)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
