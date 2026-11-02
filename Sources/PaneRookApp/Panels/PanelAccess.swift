import AppKit
import PaneRookCore
import PaneRookPanels

/// Feature-facing panel API. Table, path field and controller lifetime stay private to Panels/Shell.
protocol PanelAccess: AnyObject {
    var directory: URL { get }
    var mode: PanelMode { get }
    var isArchiveDirectory: Bool { get }
    var gitRepository: GitRepositoryInfo? { get }
    var entries: [FileEntry] { get }
    var selectedEntries: [FileEntry] { get }
    var selectedFiles: [URL] { get }
    var visitedDirectories: [URL] { get }
    var filterPattern: String { get }
    var textEncoding: String.Encoding { get set }
    var showHidden: Bool { get set }
    var sortKey: String { get }
    var sortAscending: Bool { get }
    var isBriefListing: Bool { get }
    func focus()
    func setMode(_ mode: PanelMode)
    func navigate(to url: URL, recordHistory: Bool, select: URL?, preserveDirectorySizes: Bool)
    func refresh(select: URL?)
    func refreshAfterTask()
    func canApplyTaskResult(in url: URL) -> Bool
    func panelize(_ urls: [URL])
    func setFilter(_ pattern: String)
    func setSort(key: String, ascending: Bool)
    func setBriefListing(_ brief: Bool)
    func showDirectorySizes(_ sizes: [URL: Int64])
    func showInspection(of url: URL?)
    func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool)
    func applyHighlights(_ rules: [(pattern: String, color: NSColor)])
    func openSelection()
    func installFavoritesMenu(_ menu: NSMenu)
}

extension PanelAccess {
    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil, preserveDirectorySizes: Bool = false) {
        navigate(to: url, recordHistory: recordHistory, select: select, preserveDirectorySizes: preserveDirectorySizes)
    }
    func refresh() { refresh(select: nil) }
}
