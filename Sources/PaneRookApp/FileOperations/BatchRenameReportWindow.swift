import AppKit
import PaneRookCore

/// Kept by the task's result action, including after failure or cancellation.
final class BatchRenameReportWindow: NSWindowController {
    private let text = NSTextView()
    init() {
        let panel = ToolPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Mehrfachumbenennen · Protokoll"
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak panel] in panel?.orderOut(nil) }
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 14, height: 14)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; panel.contentView!.addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    func finish(_ result: Result<Void, Error>, plan: BatchRenamePlan) {
        let message: String
        switch result {
        case .success: message = "\(plan.changedItems.count) Einträge erfolgreich umbenannt."
        case .failure(let error): message = error.localizedDescription
        }
        text.string = message + "\n\nBestätigter Plan (Quelle → Ziel):\n" + plan.items.map {
            "\($0.source.url.path) → \($0.destination.path)" + ($0.changesName ? "" : " (unverändert)")
        }.joined(separator: "\n")
    }
}
