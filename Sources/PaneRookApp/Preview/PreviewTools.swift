import AppKit
import Quartz
import PaneRookCore
import PaneRookTasks

protocol PreviewHost: PanelPresenting, ErrorPresenting, TaskProviding {
    var canUseSelection: Bool { get }
    var canUseNativeSelection: Bool { get }
    func recordFiles(_ urls: [URL])
    func openUsingExtension(_ urls: [URL]) -> Bool
}

final class PreviewTools: NSObject, QLPreviewPanelDataSource {
    unowned let owner: any PreviewHost
    private var previewURLs: [URL] = []
    init(owner: any PreviewHost) { self.owner = owner }
    func openSelection() {
        if let remote = owner.activePane.remoteContent { remote.openSelection(); return }
        guard let entry = owner.activePane.selectedEntries.first else { return }
        // Archives enter the panel before extension-to-app associations are considered.
        if entry.isDirectory || (!entry.isSymbolicLink && ArchiveFileSystem.location(for: entry.url)?.memberPath.isEmpty == true) {
            owner.activePane.openSelection()
            return
        }
        if let location = ArchiveFileSystem.location(for: entry.url), !location.memberPath.isEmpty {
            withReadableFiles([entry.url]) { [weak self] files in
                guard let self else { return }
                if !self.owner.openUsingExtension(files), let file = files.first, !NSWorkspace.shared.open(file) {
                    self.owner.showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Die Archivdatei konnte nicht geöffnet werden."]))
                }
            }
            return
        }
        if owner.activePane.selectedEntries.contains(where: { !$0.isDirectory && !$0.isParent }), owner.openUsingExtension(owner.activePane.selectedFiles) { return }
        owner.activePane.openSelection()
    }
    func choosePreviewFile() {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let chooser = NSOpenPanel()
        chooser.title = "Datei anzeigen"
        chooser.prompt = "Anzeigen"
        chooser.directoryURL = ArchiveFileSystem.location(for: owner.activePane.directory)?.archiveURL.deletingLastPathComponent() ?? owner.activePane.directory
        chooser.canChooseDirectories = false
        chooser.allowsMultipleSelection = false
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = chooser.url else { return }
            self.previewFiles([url])
        }
    }
    func previewSelection() {
        if let remote = owner.activePane.remoteContent {
            remote.preparePreview { [weak self] files in self?.showPreviewFiles(files) }
            return
        }
        previewFiles(owner.activePane.selectedFiles)
    }
    func previewFiles(_ urls: [URL]) {
        withReadableFiles(urls) { [weak self] files in
            self?.owner.recordFiles(urls)
            self?.showPreviewFiles(files)
        }
    }
    private func withReadableFiles(_ urls: [URL], completion: @escaping ([URL]) -> Void) {
        guard !urls.isEmpty else { NSSound.beep(); return }
        guard urls.contains(where: { ArchiveFileSystem.location(for: $0).map { !$0.memberPath.isEmpty } ?? false }) else {
            completion(urls)
            return
        }
        let token = TransferCancellation()
        var readable: [URL]?
        owner.tasks.submit(title: "Archivvorschau vorbereiten", detail: urls.map(\.path).joined(separator: "\n"),
            cancellation: { token.cancel() }, work: { report in
                var files: [URL] = []
                for (index, url) in urls.enumerated() {
                    try token.check()
                    report(OperationProgress(completedItems: index, totalItems: urls.count, currentPath: url.path))
                    files.append(try ArchivePreviewStore.shared.readableURL(for: url, cancellation: token, progress: report))
                }
                try token.check()
                report(OperationProgress(completedItems: urls.count, totalItems: urls.count))
                return files
            }, onReveal: {
                if let readable { completion(readable) }
            }, completion: { result in
                if case .success(let files) = result { readable = files }
            })
    }
    private func showPreviewFiles(_ urls: [URL]) {
        previewURLs = urls
        guard !previewURLs.isEmpty else { NSSound.beep(); return }
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewURLs[index] as NSURL }

    func editSelection() {
        guard owner.canUseNativeSelection else {
            if owner.activePane.isArchiveDirectory {
                owner.showError(NSError(domain: "PaneRook", code: 1, userInfo: [NSLocalizedDescriptionKey: "Zum Bearbeiten die Datei zuerst in einen lokalen Ordner kopieren."]),
                          detail: "Dateien aus Archiven werden als temporäre Lesekopien geöffnet. Änderungen werden nicht automatisch ins Archiv zurückgeschrieben.")
            }
            return
        }
        let files = owner.activePane.selectedEntries.filter { !$0.isParent && !$0.isDirectory }.map(\.url)
        guard !files.isEmpty else { NSSound.beep(); return }
        owner.recordFiles(files)
        let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: .init()) { [weak self] _, error in
            if let error { DispatchQueue.main.async { self?.owner.showError(error) } }
        }
    }
}
