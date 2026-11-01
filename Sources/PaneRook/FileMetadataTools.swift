import AppKit
import PaneRookCore

/// MC's permission, ownership and link commands, presented as native sheets.
final class FileMetadataTools {
    private unowned let owner: CommanderController
    init(owner: CommanderController) { self.owner = owner }

    func chmod() {
        withSelection { urls, snapshots in
            let permissions = PermissionGrid(snapshots: snapshots)
            let alert = self.alert("Chmod", urls: urls)
            alert.accessoryView = permissions
            self.present(alert) {
                let (values, mask) = permissions.change
                self.owner.runOperation("Rechte ändern …") {
                    try FileMetadata.changePermissions(of: urls, values: values, mask: mask)
                }
            }
        }
    }

    func chown(advanced: Bool) {
        withSelection { urls, snapshots in
            let user = self.field(label: "Benutzer", value: Set(snapshots.map(\.ownerID)).count == 1 ? snapshots[0].owner : "")
            let group = self.field(label: "Gruppe", value: Set(snapshots.map(\.groupID)).count == 1 ? snapshots[0].group : "")
            user.placeholderString = "Unverändert · Name oder UID"
            group.placeholderString = "Unverändert · Name oder GID"
            user.toolTip = "Ein leeres Feld behält den bisherigen Benutzer bei."
            group.toolTip = "Ein leeres Feld behält die bisherige Gruppe bei."
            let content = self.form([("Benutzer", user), ("Gruppe", group)])
            let permissions = advanced ? PermissionGrid(snapshots: snapshots) : nil
            if let permissions { content.addArrangedSubview(permissions) }
            let alert = self.alert(advanced ? "Erweitertes chown" : "Chown", urls: urls)
            alert.accessoryView = content
            self.present(alert, firstResponder: user) {
                let userName = user.stringValue
                let groupName = group.stringValue
                let change = permissions?.change
                self.owner.runOperation("Eigentümer ändern …") {
                    try FileMetadata.changeOwnership(of: urls, owner: userName, group: groupName,
                        permissionValues: change?.values, permissionMask: change?.mask ?? 0)
                }
            }
        }
    }

    func createHardLink() {
        withSingleSelection { source in
            do {
                guard try FileMetadata.inspect(source).isRegularFile else {
                    throw FileMetadataError.notRegularFile(source.lastPathComponent)
                }
                let base = self.owner.active.directory
                let linkName = self.field(label: "Linkname", value: self.defaultLinkURL(for: source).path)
                let alert = self.alert("Harter Link", urls: [source])
                alert.buttons[0].title = "Anlegen"
                alert.accessoryView = self.form([("Linkname", linkName)])
                self.present(alert, firstResponder: linkName) {
                    do {
                        let destination = try self.destination(linkName.stringValue, relativeTo: base, name: source.lastPathComponent)
                        self.owner.runOperation("Harten Link anlegen …") {
                            try FileMetadata.createHardLink(to: source, at: destination)
                        }
                    } catch { self.owner.showError(error) }
                }
            } catch { self.owner.showError(error) }
        }
    }

    func createSymbolicLink(relative: Bool) {
        withSingleSelection { source in
            let base = self.owner.active.directory
            let target = self.field(label: "Ziel", value: source.path)
            target.toolTip = relative
                ? "Das Ziel wird relativ zum neuen Link gespeichert. Eingaben ohne / am Anfang beziehen sich auf das aktive Verzeichnis."
                : "Der eingegebene Pfad wird als Linkziel gespeichert. Relative Ziele beziehen sich auf den Ordner des neuen Links."
            let linkName = self.field(label: "Linkname", value: self.defaultLinkURL(for: source).path)
            let alert = self.alert(relative ? "Relativer symbolischer Link" : "Symbolischer Link", urls: [])
            alert.buttons[0].title = "Anlegen"
            alert.accessoryView = self.form([("Ziel", target), ("Linkname", linkName)])
            self.present(alert, firstResponder: linkName) {
                do {
                    let destination = try self.destination(linkName.stringValue, relativeTo: base, name: source.lastPathComponent)
                    let literalTarget = target.stringValue
                    let storedTarget: String
                    if relative {
                        guard !literalTarget.isEmpty else { throw FileMetadataError.invalidLinkTarget }
                        let targetURL = self.pathURL(literalTarget, relativeTo: base)
                        storedTarget = FileMetadata.relativePath(to: targetURL, from: destination.deletingLastPathComponent())
                    } else { storedTarget = literalTarget }
                    self.owner.runOperation("Symbolischen Link anlegen …") {
                        try FileMetadata.createSymbolicLink(target: storedTarget, at: destination)
                    }
                } catch { self.owner.showError(error) }
            }
        }
    }

    func editSymbolicLink() {
        withSingleSelection { source in
            do {
                let target = self.field(label: "Ziel", value: try FileMetadata.symbolicLinkTarget(at: source))
                target.toolTip = "Relative Ziele beziehen sich auf den Ordner dieses Links. Das Ziel darf noch nicht existieren."
                let alert = self.alert("Symbolischen Link bearbeiten", urls: [source])
                alert.accessoryView = self.form([("Ziel", target)])
                self.present(alert, firstResponder: target) {
                    let value = target.stringValue
                    self.owner.runOperation("Linkziel ändern …") { try FileMetadata.editSymbolicLink(at: source, target: value) }
                }
            } catch { self.owner.showError(error) }
        }
    }

    private func withSelection(_ body: ([URL], [FileMetadata.Snapshot]) -> Void) {
        guard owner.canUseMenus else { return }
        let urls = owner.active.selectedFiles
        guard !urls.isEmpty else { NSSound.beep(); return }
        do { body(urls, try urls.map(FileMetadata.inspect)) }
        catch { owner.showError(error) }
    }
    private func withSingleSelection(_ body: (URL) -> Void) {
        guard owner.canUseMenus else { return }
        let urls = owner.active.selectedFiles
        guard urls.count == 1 else {
            let error = NSError(domain: "PaneRook", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bitte genau einen Eintrag auswählen."])
            owner.showError(error)
            return
        }
        guard urls[0].isFileURL else { owner.showError(FileMetadataError.localFilesOnly); return }
        body(urls[0])
    }
    private func alert(_ title: String, urls: [URL]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        if urls.count == 1 { alert.informativeText = urls[0].lastPathComponent }
        else if !urls.isEmpty { alert.informativeText = "\(urls.count) ausgewählte Einträge" }
        alert.addButton(withTitle: "Anwenden")
        alert.addButton(withTitle: "Abbrechen")
        alert.configureKeyboardShortcuts()
        return alert
    }
    private func present(_ alert: NSAlert, firstResponder: NSView? = nil, accept: @escaping () -> Void) {
        guard let window = owner.view.window, window.attachedSheet == nil else { return }
        let pane = owner.active!
        alert.window.initialFirstResponder = firstResponder
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.owner.activate(pane)
            if response == .alertFirstButtonReturn { accept() }
        }
    }
    private func field(label: String, value: String) -> NSTextField {
        let field = NSTextField(string: value)
        AppStyle.configureField(field)
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 430).isActive = true
        return field
    }
    private func form(_ rows: [(String, NSTextField)]) -> NSStackView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        for (title, field) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            let group = NSStackView(views: [label, field])
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 4
            content.addArrangedSubview(group)
        }
        content.frame.size = content.fittingSize
        return content
    }
    private func defaultLinkURL(for source: URL) -> URL {
        let other = owner.active === owner.left ? owner.right.directory : owner.left.directory
        let base = other.isFileURL ? other : owner.active.directory
        let target = base.appendingPathComponent(source.lastPathComponent)
        return target.standardizedFileURL == source.standardizedFileURL
            ? base.appendingPathComponent(source.lastPathComponent + ".link") : target
    }
    private func pathURL(_ path: String, relativeTo base: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded)).standardizedFileURL
    }
    private func destination(_ value: String, relativeTo base: URL, name: String) throws -> URL {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else {
            throw FileActionError.invalidName
        }
        var url = pathURL(value, relativeTo: base)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            url.appendPathComponent(name)
        }
        return url
    }
}

private final class PermissionGrid: NSStackView {
    private var controls: [(UInt16, NSButton)] = []
    var change: (values: UInt16, mask: UInt16) {
        var values: UInt16 = 0
        var mask: UInt16 = 0
        for (bit, button) in controls where button.state != .mixed {
            mask |= bit
            if button.state == .on { values |= bit }
        }
        return (values, mask)
    }
    init(snapshots: [FileMetadata.Snapshot]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let columns = ["Lesen", "Schreiben", "Ausführen"]
        var rows: [[NSView]] = [[NSTextField(labelWithString: "")] + columns.map { NSTextField(labelWithString: $0) }]
        for (label, shift) in [("Benutzer", 6), ("Gruppe", 3), ("Andere", 0)] {
            var row: [NSView] = [NSTextField(labelWithString: label)]
            for (index, mode) in [4, 2, 1].enumerated() {
                row.append(checkbox(bit: UInt16(mode << shift), label: "\(label): \(columns[index])", snapshots: snapshots))
            }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 7
        grid.columnSpacing = 24
        for index in 1...3 { grid.column(at: index).xPlacement = .center }
        addArrangedSubview(grid)
        let special = NSStackView()
        special.spacing = 18
        for (name, bit): (String, UInt16) in [("Setuid", 0o4000), ("Setgid", 0o2000), ("Sticky", 0o1000)] {
            let button = checkbox(bit: bit, label: name, snapshots: snapshots)
            button.title = name
            special.addArrangedSubview(button)
        }
        addArrangedSubview(special)
        frame.size = fittingSize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    private func checkbox(bit: UInt16, label: String, snapshots: [FileMetadata.Snapshot]) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.allowsMixedState = true
        button.setAccessibilityLabel(label)
        let states = Set(snapshots.map { $0.permissions & bit != 0 })
        button.state = states.count > 1 ? .mixed : states.contains(true) ? .on : .off
        button.toolTip = "Eine gemischte Auswahl behält die jeweiligen bisherigen Rechte bei."
        controls.append((bit, button))
        return button
    }
}
