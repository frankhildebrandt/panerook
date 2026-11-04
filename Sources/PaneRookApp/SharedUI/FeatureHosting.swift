import AppKit

protocol PanelPresenting: AnyObject {
    var presentationWindow: NSWindow? { get }
    var canUseMenus: Bool { get }
    var activePane: any PanelAccess { get }
    func activate(_ pane: any PanelAccess)
}
protocol PanelPairProviding: AnyObject {
    var allPanes: [any PanelAccess] { get }
    func oppositePane(for pane: any PanelAccess) -> any PanelAccess
    var leftPane: any PanelAccess { get }
    var rightPane: any PanelAccess { get }
    var otherPane: any PanelAccess { get }
}
protocol ErrorPresenting: AnyObject {
    func showError(_ error: Error, detail: String)
}
extension ErrorPresenting {
    func showError(_ error: Error) { showError(error, detail: "") }
}
protocol TaskProviding: AnyObject { var tasks: TaskCenter { get } }

extension PanelPairProviding {
    var allPanes: [any PanelAccess] { [leftPane, rightPane] }
    func oppositePane(for pane: any PanelAccess) -> any PanelAccess { pane === leftPane ? rightPane : leftPane }
}
