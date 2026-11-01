import PaneRookRemote
import AppKit
import PaneRookCore

/// Provider probing and volume metadata never block a menu's tracking loop.
final class FavoriteDestinationCache {
    struct Volume { let name: String; let url: URL; let internalDisk: Bool }
    private(set) var volumes: [Volume] = []
    private(set) var locations: [FavoriteLocation] = FavoriteLocationKind.allCases.map { FavoriteLocation(kind: $0, urls: []) }
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    init() {
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in self?.refresh(force: true) })
        }
        refresh()
    }
    deinit { for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
    func refresh(force: Bool = false) {
        guard !refreshing, force || Date().timeIntervalSince(lastRefresh) > 5 else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fm = FileManager.default
            let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []
            var seen = Set<String>()
            let volumes = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }.map { url -> Volume in
                let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey])
                return Volume(name: values?.volumeLocalizedName ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent),
                              url: url, internalDisk: values?.volumeIsInternal ?? false)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let locations = FavoriteLocationResolver.locations()
            DispatchQueue.main.async { [weak self] in
                self?.volumes = volumes; self?.locations = locations
                self?.refreshing = false; self?.lastRefresh = Date()
            }
        }
    }
}

final class PanelFavoritesController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private final class Command {
        let run: () -> Void
        let enabled: () -> Bool
        init(_ run: @escaping () -> Void, enabled: @escaping () -> Bool) { self.run = run; self.enabled = enabled }
    }
    private unowned let owner: any FavoritesHost
    private unowned let pane: any PanelAccess
    private let cache: FavoriteDestinationCache
    private let store = PanelFavoriteStore()
    private let menu = NSMenu(title: "Favoriten")
    private var menus: [NSMenu] = []
    private var tracking = Set<ObjectIdentifier>()
    private var keyMonitor: Any?
    var isTracking: Bool { !tracking.isEmpty }
    private var canUseFavorites: Bool {
        !owner.isPerformingOperation && owner.presentationWindow?.attachedSheet == nil
    }

    init(owner: any FavoritesHost, pane: any PanelAccess, cache: FavoriteDestinationCache) {
        self.owner = owner; self.pane = pane; self.cache = cache
        super.init()
        menu.delegate = self
        pane.installFavoritesMenu(menu)
        rebuild()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isTracking else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if ((event.keyCode == 53 || event.keyCode == 109) && flags.isEmpty) || (event.keyCode == 5 && flags == .control) {
                for menu in self.menus { menu.cancelTrackingWithoutAnimation() }
                return nil
            }
            return event
        }
    }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { rebuild(); cache.refresh() }
    }
    func menuWillOpen(_ menu: NSMenu) { tracking.insert(ObjectIdentifier(menu)); owner.activate(pane) }
    func menuDidClose(_ menu: NSMenu) { tracking.remove(ObjectIdentifier(menu)) }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = menuItem.representedObject as? Command else { return false }
        return canUseFavorites && command.enabled()
    }
    @objc private func run(_ sender: NSMenuItem) {
        guard canUseFavorites, let command = sender.representedObject as? Command, command.enabled() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.owner.presentationWindow?.makeKeyAndOrderFront(nil)
            self.owner.activate(self.pane)
            command.run()
        }
    }
    private func submenu(_ title: String, in parent: NSMenu, symbol: String? = nil) -> NSMenu {
        let child = NSMenu(title: title); child.delegate = self; menus.append(child)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = child
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        parent.addItem(item)
        return child
    }
    @discardableResult private func add(_ title: String, to menu: NSMenu, symbol: String? = nil, tooltip: String? = nil,
                                        enabled: @escaping () -> Bool = { true }, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = Command(action, enabled: enabled); item.toolTip = tooltip
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item); return item
    }
    private func label(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
    }
    private func open(_ url: URL) { pane.setMode(.listing); pane.navigate(to: url); owner.activate(pane) }
    private func title(_ kind: FavoriteLocationKind) -> String {
        switch kind { case .iCloudDrive: return "iCloud Drive"; case .protonDrive: return "Proton Drive"; case .dropbox: return "Dropbox" }
    }
    private func rebuild() {
        menu.removeAllItems(); menus = [menu]
        let heading = NSMenuItem(title: "Favoriten", action: nil, keyEquivalent: "")
        heading.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
        menu.addItem(heading)
        let volumes = submenu("Volumes", in: menu, symbol: "externaldrive")
        if cache.volumes.isEmpty { add("Macintosh HD", to: volumes, symbol: "internaldrive") { [weak self] in self?.open(URL(fileURLWithPath: "/")) } }
        for volume in cache.volumes {
            add(volume.name, to: volumes, symbol: volume.internalDisk ? "internaldrive" : "externaldrive", tooltip: volume.url.path) { [weak self] in self?.open(volume.url) }
        }
        volumes.addItem(.separator())
        add("Alle Volumes", to: volumes, symbol: "externaldrive", tooltip: "/Volumes") { [weak self] in self?.open(URL(fileURLWithPath: "/Volumes", isDirectory: true)) }
        for kind in FavoriteLocationKind.allCases {
            let roots = store.overriddenLocation(kind).map { [$0] } ?? cache.locations.first(where: { $0.kind == kind })?.urls ?? []
            guard !roots.isEmpty else { continue }
            if roots.count > 1 {
                let accounts = submenu(title(kind), in: menu, symbol: "cloud")
                for url in roots { add(url.lastPathComponent, to: accounts, symbol: "folder", tooltip: url.path) { [weak self] in self?.open(url) } }
            } else {
                add(title(kind), to: menu, symbol: "cloud", tooltip: roots.first?.path) { [weak self] in
                    guard let self else { return }
                    if let url = roots.first { self.open(url) }
                }
            }
        }
        add("Netzwerk", to: menu, symbol: "network") { [weak self] in
            guard let self else { return }; self.pane.setMode(.network); self.owner.activate(self.pane)
        }
        menu.addItem(.separator())
        let favorites = submenu("Eigene Favoriten", in: menu, symbol: "star")
        do {
            let folders = try store.folders()
            if !folders.isEmpty { label("Ordner", in: favorites) }
            for url in folders {
                add(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent, to: favorites, symbol: "folder", tooltip: url.path) { [weak self] in self?.open(url) }
            }
        } catch { label(error.localizedDescription, in: favorites) }
        do {
            let bookmarks = try owner.savedBookmarks()
            if !bookmarks.isEmpty { label("Verbindungen", in: favorites) }
            for bookmark in bookmarks.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                add(bookmark.name + " · " + bookmark.kind.provider.title, to: favorites, symbol: "server.rack", tooltip: ((try? bookmark.connection())?.displayName ?? bookmark.host) + "\n" + bookmark.path) { [weak self] in
                    guard let self else { return }; self.owner.openSavedBookmark(bookmark, pane: self.pane)
                }
            }
        } catch { label("Verbindungsarchiv nicht lesbar", in: favorites) }
        favorites.addItem(.separator())
        add("Aktuellen Ordner hinzufügen", to: favorites, symbol: "star.badge.plus", tooltip: pane.directory.path,
            enabled: { [weak self] in
                guard let self else { return false }
                return self.pane.mode != .network && !self.pane.isArchiveDirectory
            }) { [weak self] in
            guard let self else { return }
            do { try self.store.addFolder(self.pane.directory) } catch { self.owner.showError(error) }
        }
        add("Ordner hinzufügen …", to: favorites, symbol: "folder.badge.plus") { [weak self] in self?.chooseFavoriteFolder() }
        add("Ordnerfavoriten entfernen …", to: favorites) { [weak self] in self?.removeFavorite() }
        add("Verbindungsarchiv …", to: favorites, symbol: "server.rack") { [weak self] in
            guard let self else { return }; self.owner.showConnectionArchive(pane: self.pane)
        }
        let cloud = submenu("Cloud-Ordner zuordnen", in: favorites)
        for kind in FavoriteLocationKind.allCases {
            guard store.overriddenLocation(kind) != nil || cache.locations.contains(where: { $0.kind == kind && !$0.urls.isEmpty }) else { continue }
            let options = submenu(title(kind), in: cloud)
            add("Ordner auswählen …", to: options) { [weak self] in self?.chooseCloudFolder(kind, navigate: false) }
            if store.overriddenLocation(kind) != nil {
                add("Automatisch erkennen", to: options) { [weak self] in self?.store.clearOverrideLocation(kind) }
            }
        }
    }
    private func folderChooser(title: String, start: URL?, completion: @escaping (URL) -> Void) {
        guard owner.canUseMenus, let window = owner.presentationWindow else { return }
        let chooser = NSOpenPanel()
        chooser.title = title; chooser.prompt = "Auswählen"
        chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.allowsMultipleSelection = false
        chooser.directoryURL = start.flatMap { ArchiveFileSystem.location(for: $0)?.archiveURL.deletingLastPathComponent() ?? $0 }
        chooser.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }; self.owner.activate(self.pane)
            if result == .OK, let url = chooser.url { completion(url) }
        }
    }
    private func chooseCloudFolder(_ kind: FavoriteLocationKind, navigate: Bool) {
        let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        folderChooser(title: title(kind) + "-Ordner auswählen", start: store.overriddenLocation(kind) ?? storage) { [weak self] url in
            guard let self else { return }
            do { try self.store.overrideLocation(kind, with: url); if navigate { self.open(url) } }
            catch { self.owner.showError(error) }
        }
    }
    private func chooseFavoriteFolder() {
        folderChooser(title: "Ordner als Favorit hinzufügen", start: pane.directory) { [weak self] url in
            guard let self else { return }
            do { try self.store.addFolder(url) } catch { self.owner.showError(error) }
        }
    }
    private func removeFavorite() {
        do {
            let urls = try store.folders()
            ToolUI.choose(owner: owner, title: "Ordnerfavoriten entfernen", labels: urls.map(\.path), accept: "Entfernen") { [weak self] index, _ in
                guard let self, urls.indices.contains(index) else { return }
                do { try self.store.removeFolder(urls[index]) } catch { self.owner.showError(error) }
            }
        } catch { owner.showError(error) }
    }
}

protocol FavoritesHost: PanelPresenting, ErrorPresenting {
    var isPerformingOperation: Bool { get }
    func showConnectionArchive(pane: any PanelAccess)
    func savedBookmarks() throws -> [ConnectionBookmark]
    func openSavedBookmark(_ bookmark: ConnectionBookmark, pane: any PanelAccess)
}
