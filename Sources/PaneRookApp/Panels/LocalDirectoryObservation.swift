import Foundation
import CoreServices

struct LocalDirectoryEvent {
    let url: URL
    var mustRescan = false
    var rootChanged = false
}

protocol LocalDirectoryEventSource: AnyObject {
    func cancel()
}

/// One stream per visible local panel, never one descriptor per file. All calls
/// and deliveries use the main queue; cancellation releases the native stream.
final class NativeDirectoryEventSource: LocalDirectoryEventSource {
    private final class Delivery {
        var receive: (([LocalDirectoryEvent]) -> Void)?
        init(_ receive: @escaping ([LocalDirectoryEvent]) -> Void) { self.receive = receive }
    }
    private var stream: FSEventStreamRef?
    private let delivery: Delivery

    init?(urls: [URL], receive: @escaping ([LocalDirectoryEvent]) -> Void) {
        delivery = Delivery(receive)
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(delivery).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Delivery>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Delivery>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let delivery = Unmanaged<Delivery>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as! [String]
            let events = (0..<count).map { index in
                LocalDirectoryEvent(url: URL(fileURLWithPath: paths[index], isDirectory: false),
                    mustRescan: flags[index] & UInt32(kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0,
                    rootChanged: flags[index] & UInt32(kFSEventStreamEventFlagRootChanged
                        | kFSEventStreamEventFlagUnmount) != 0)
            }
            delivery.receive?(events)
        }, &context, urls.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, FSEventStreamCreateFlags(flags))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else { cancel(); return nil }
    }

    func cancel() {
        delivery.receive = nil
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
    deinit { cancel() }
}

/// Event classification and bounded burst coalescing, independent of AppKit and
/// directory loading. A fixed window also makes progress during continuous builds.
final class LocalDirectoryObservation {
    typealias Factory = ([URL], @escaping ([LocalDirectoryEvent]) -> Void) -> (any LocalDirectoryEventSource)?
    struct Change {
        var listing = false
        var git = false
        var repository = false
        var invalidated = false
        var descendants = Set<URL>()
        var isEmpty: Bool { !listing && !git && !repository && !invalidated && descendants.isEmpty }
        mutating func merge(_ other: Self) {
            listing = listing || other.listing; git = git || other.git
            repository = repository || other.repository; invalidated = invalidated || other.invalidated
            descendants.formUnion(other.descendants)
        }
    }

    private let factory: Factory
    private let delay: TimeInterval
    private var source: (any LocalDirectoryEventSource)?
    private var roots: [URL] = []
    private var directory: URL?
    private var worktree: URL?
    private var metadata: URL?
    private var ignoredPaths = Set<URL>()
    private var revision = 0
    private var pending = Change()
    private var scheduled: DispatchWorkItem?
    var onChange: ((Change) -> Void)?

    init(delay: TimeInterval = 0.6, factory: @escaping Factory = { NativeDirectoryEventSource(urls: $0, receive: $1) }) {
        self.delay = delay; self.factory = factory
    }

    func watch(directory: URL, worktree: URL? = nil, metadata: URL? = nil, ignoredPaths: Set<URL> = []) {
        self.ignoredPaths = Set(ignoredPaths.map(Self.canonical))
        let directory = Self.canonical(directory.resolvingSymlinksInPath())
        let worktree = worktree.map { Self.canonical($0.resolvingSymlinksInPath()) }
        let metadata = metadata.map { Self.canonical($0.resolvingSymlinksInPath()) }
        guard self.directory != directory || self.worktree != worktree || self.metadata != metadata || source == nil else { return }
        let previousDirectory = self.directory
        let changes = pending
        stop()
        self.directory = directory; self.worktree = worktree; self.metadata = metadata
        roots = Array(Set([directory] + [worktree, metadata].compactMap { $0 })).sorted { $0.path < $1.path }
        let request = revision
        source = factory(roots) { [weak self] events in
            guard let self, self.revision == request else { return }
            for event in events { self.pending.merge(self.classify(event)) }
            self.schedule()
        }
        // Adding Git roots must not drop a directory change already delivered.
        if previousDirectory == directory { pending.merge(changes); schedule() }
    }

    func stop() {
        revision += 1
        source?.cancel(); source = nil
        scheduled?.cancel(); scheduled = nil
        pending = Change(); directory = nil; worktree = nil; metadata = nil; roots = []
    }
    deinit { source?.cancel(); scheduled?.cancel() }

    private func schedule() {
        guard !pending.isEmpty, scheduled == nil else { return }
        let request = revision
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.revision == request else { return }
            self.scheduled = nil
            let change = self.pending; self.pending = Change()
            self.onChange?(change)
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func classify(_ event: LocalDirectoryEvent) -> Change {
        guard let directory else { return Change() }
        let url = Self.canonical(event.url)
        var change = Change()
        if event.rootChanged {
            change.invalidated = roots.contains { Self.contains(url, $0) }
            change.listing = true; change.git = true; change.repository = true
            return change
        }
        if event.mustRescan {
            change.listing = true; change.git = true; change.repository = true
            return change
        }
        // Git's optional locks are disabled by the existing readers. Ignore
        // transient locks and object writes as well, including external git gc.
        let parts = url.pathComponents
        let marker = parts.firstIndex(of: ".git")
        let inMetadata = metadata.map { Self.contains($0, url) } ?? false
        if marker != nil || inMetadata {
            let relative = inMetadata ? String(url.path.dropFirst(metadata!.path.count)).split(separator: "/").map(String.init)
                : Array(parts.dropFirst(marker! + 1))
            guard !relative.contains(where: { $0.hasSuffix(".lock") }),
                  !["objects", "hooks"].contains(relative.first ?? ""),
                  relative.first != "logs" || relative.last == "stash" else { return change }
            change.git = true
            change.repository = relative.isEmpty || relative.first == "worktrees" || relative.first == "config" || relative.first == "HEAD"
        } else if let worktree, Self.contains(worktree, url) {
            change.git = !ignoredPaths.contains { Self.contains($0, url) }
        }
        if Self.contains(directory, url) {
            if url.path == directory.path || url.deletingLastPathComponent().path == directory.path { change.listing = true }
            let relative = url.pathComponents.dropFirst(directory.pathComponents.count)
            if let first = relative.first { change.descendants.insert(directory.appendingPathComponent(first)) }
            if relative.contains(".git") { change.repository = true }
        }
        return change
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }

    /// Foundation may shorten /private/var and /private/tmp even after resolving
    /// symlinks; FSEvents always reports their physical spelling. Normalize
    /// lexically so deleted paths work too, without a stat per event.
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        for alias in ["/tmp", "/var", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: false)
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }
}
