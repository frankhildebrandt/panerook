import AppKit
import PaneRookCore

/// A compact status stays in the name column, including in brief listings.
struct GitStatusPresentation {
    let status: GitRepositoryStatus

    var text: String {
        let symbol = status.conflictCount > 0 ? "!" : (status.isClean ? "✓" : "●")
        var value = "\(symbol) \(status.branch ?? "HEAD")"
        if status.aheadCount > 0 { value += " ↑\(status.aheadCount)" }
        if status.behindCount > 0 { value += " ↓\(status.behindCount)" }
        return value
    }

    var color: NSColor {
        status.conflictCount > 0 ? .systemRed : (status.isClean ? .systemGreen : .systemOrange)
    }

    var detail: String {
        var lines = ["Git · \(status.branch.map { "Branch \($0)" } ?? "Detached HEAD")"]
        if status.isClean { lines.append("Arbeitsverzeichnis sauber") }
        if status.stagedCount > 0 { lines.append("\(status.stagedCount) zum Commit vorgemerkt") }
        if status.modifiedCount > 0 { lines.append("\(status.modifiedCount) nicht vorgemerkte Änderungen") }
        if status.untrackedCount > 0 { lines.append("\(status.untrackedCount) unversionierte Einträge") }
        if status.conflictCount > 0 { lines.append("\(status.conflictCount) Konflikte") }
        if status.aheadCount > 0 { lines.append("\(status.aheadCount) Commits voraus") }
        if status.behindCount > 0 { lines.append("\(status.behindCount) Commits zurück") }
        return lines.joined(separator: "\n")
    }
}

final class GitStatusBadge: NSTextField {
    init(status: GitRepositoryStatus) {
        super.init(frame: .zero)
        let presentation = GitStatusPresentation(status: status)
        isEditable = false
        isSelectable = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        stringValue = presentation.text
        textColor = presentation.color
        font = .systemFont(ofSize: 10, weight: .medium)
        lineBreakMode = .byTruncatingMiddle
        maximumNumberOfLines = 1
        alignment = .right
        toolTip = presentation.detail
        setAccessibilityLabel(presentation.detail.replacingOccurrences(of: "\n", with: ", "))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}
