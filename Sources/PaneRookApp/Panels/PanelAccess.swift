import AppKit
import PaneRookRemote
import PaneRookCore
import PaneRookPanels
import PaneRookRemote

/// Captured endpoint and path remain valid when the panel navigates or disconnects.
struct RemoteEditRequest {
    let fileSystem: RemoteFileSystem
    let path: String
}

/// A connection occupies one panel while its local directory is retained for disconnecting.
protocol RemotePanelContent: AnyObject {
    var workspaceBookmark: ConnectionBookmark? { get }
    var awaitsWorkspaceAuthentication: Bool { get }
    var onKey: ((NSEvent) -> Bool)? { get set }
    var isActive: Bool { get set }
    var viewController: NSViewController { get }
    var isBusy: Bool { get }
    var hasSelection: Bool { get }
    var canDownload: Bool { get }
    var canUpload: Bool { get }
    var canMove: Bool { get }
    var canRename: Bool { get }
    var canPreview: Bool { get }
    var remoteEditRequests: [RemoteEditRequest] { get }
    var showHidden: Bool { get set }
    var sortKey: String { get }
    var sortAscending: Bool { get }
    var filterPattern: String { get }
    var isBriefListing: Bool { get }
    func focus()
    func focusPath()
    func refresh()
    func goUp()
    func goBack()
    func openSelection()
    func download()
    func upload()
    func moveSelection()
    func moveLocalSelection()
    func renameSelection()
    func preparePreview(completion: @escaping ([URL]) -> Void)
    func setFilter(_ pattern: String)
    func setSort(key: String, ascending: Bool)
    func setBriefListing(_ brief: Bool)
    func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool)
    func selectMatching(_ pattern: String, select: Bool)
    func invertSelection()
    func installFavoritesMenu(_ menu: NSMenu)
    func installFileContextMenu(provider: @escaping () -> NSMenu?)
    func showFavorites()
    func makeDirectory()
    func deleteSelected()
    func disconnect()
}

extension RemotePanelContent {
    var workspaceBookmark: ConnectionBookmark? { nil }
    var awaitsWorkspaceAuthentication: Bool { false }
    var canMove: Bool { false }
    var canRename: Bool { false }
    var canPreview: Bool { false }
    var remoteEditRequests: [RemoteEditRequest] { [] }
    var showHidden: Bool { get { false } set {} }
    var sortKey: String { "name" }
    var sortAscending: Bool { true }
    var filterPattern: String { "" }
    var isBriefListing: Bool { false }
    func goBack() {}
    func moveSelection() {}
    func moveLocalSelection() {}
    func renameSelection() {}
    func preparePreview(completion: @escaping ([URL]) -> Void) {}
    func setFilter(_ pattern: String) {}
    func setSort(key: String, ascending: Bool) {}
    func setBriefListing(_ brief: Bool) {}
    func applyDisplayOptions(rowHeight: CGFloat, showIcons: Bool, showSummary: Bool) {}
    func selectMatching(_ pattern: String, select: Bool) {}
    func invertSelection() {}
    func installFavoritesMenu(_ menu: NSMenu) {}
    func installFileContextMenu(provider: @escaping () -> NSMenu?) {}
    func showFavorites() {}
}

/// Feature-facing panel API. Table, path field and controller lifetime stay private to Panels/Shell.
protocol PanelAccess: AnyObject {
    /// Native exchange is limited to a ready local file list. Search results may export,
    /// but have no unambiguous background destination.
    var canExportNativeFiles: Bool { get }
    var fileExchangeDirectory: URL? { get }
    var hasFileListKeyboardFocus: Bool { get }
    func installFileExchange(_ exchange: NativeFileExchange)
    var remoteContent: (any RemotePanelContent)? { get }
    var directory: URL { get }
    var mode: PanelMode { get }
    var isArchiveDirectory: Bool { get }
    var gitRepository: GitRepositoryInfo? { get }
    var entries: [FileEntry] { get }
    var selectedEntries: [FileEntry] { get }
    var selectedFiles: [URL] { get }
    var visitedDirectories: [URL] { get }
    var filterPattern: String { get }
    var gitFilter: GitFileFilter { get }
    var textEncoding: String.Encoding { get set }
    var showHidden: Bool { get set }
    var sortKey: String { get }
    var sortAscending: Bool { get }
    var isBriefListing: Bool { get }
    func focus()
    func showRemoteContent(_ content: (any RemotePanelContent)?)
    func remoteStateDidChange()
    func activate()
    func setMode(_ mode: PanelMode)
    func navigate(to url: URL, recordHistory: Bool, select: URL?, preserveDirectorySizes: Bool)
    func refresh(select: URL?)
    func refreshAfterTask()
    func canApplyTaskResult(in url: URL) -> Bool
    func panelize(_ urls: [URL])
    func setFilter(_ pattern: String)
    func setGitFilter(_ filter: GitFileFilter)
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
    var canExportNativeFiles: Bool { false }
    var fileExchangeDirectory: URL? { nil }
    var hasFileListKeyboardFocus: Bool { false }
    func installFileExchange(_ exchange: NativeFileExchange) {}
    func navigate(to url: URL, recordHistory: Bool = true, select: URL? = nil, preserveDirectorySizes: Bool = false) {
        navigate(to: url, recordHistory: recordHistory, select: select, preserveDirectorySizes: preserveDirectorySizes)
    }
    func refresh() { refresh(select: nil) }
}
