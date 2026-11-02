import Foundation
import Darwin

/// Finds a possible worktree boundary using filesystem metadata only. Run on a
/// background queue and always follow a cache hit with a fresh Git query.
public enum GitWorktreeLocation {
    public static func root(containing directory: URL) -> URL? {
        guard directory.isFileURL,
              directory.host == nil || directory.host == "" || directory.host == "localhost",
              !directory.path.contains("\0") else { return nil }
        var current = directory.resolvingSymlinksInPath().standardizedFileURL
        while true {
            // Git's own metadata is not part of the working tree.
            guard current.lastPathComponent != ".git" else { return nil }
            let marker = current.appendingPathComponent(".git").path
            let probe = marker.withCString { path -> (result: Int32, error: Int32) in
                var attributes = stat()
                let result = lstat(path, &attributes)
                return (result, errno)
            }
            // lstat deliberately includes malformed files and dangling symlinks:
            // either is a boundary, even though Git may reject it afterward.
            if probe.result == 0 { return current }
            guard probe.error == ENOENT || probe.error == ENOTDIR else { return nil }
            let parent = current.deletingLastPathComponent()
            guard parent != current else { return nil }
            current = parent
        }
    }
}
