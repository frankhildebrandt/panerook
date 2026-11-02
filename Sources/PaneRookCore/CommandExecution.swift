import Foundation
import Darwin

public struct CommandResult: Sendable {
    public let output: String
    public let errorOutput: String
    public let status: Int32
    public let wasCancelled: Bool
    public let truncated: Bool
}

/// Runs an explicitly requested command in its own process group. Output is bounded
/// and stored in private temporary files so descendants cannot block pipe readers.
public final class CommandExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t = 0
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let pid = processID; lock.unlock()
        if pid > 0 {
            kill(-pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if self.processID == pid { kill(-pid, SIGKILL) }
            }
        }
    }
    public func run(_ command: String, in directory: URL,
                    environment additions: [String: String] = [:], limit: Int = 4 * 1024 * 1024) throws -> CommandResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-command-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stdoutURL = temporary.appendingPathComponent("stdout")
        let stderrURL = temporary.appendingPathComponent("stderr")
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, stdoutURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, stderrURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let cdError = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        guard cdError == 0 else { throw POSIXError(POSIXErrorCode(rawValue: cdError) ?? .EIO) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments = ["/bin/zsh", "-l", "-c", command].map { (argument: String) in strdup(argument)! }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { $0 } + [nil]
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        let envStrings = environment.map { strdup("\($0.key)=\($0.value)")! }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { $0 } + [nil]
        defer { arguments.forEach { free($0) }; envStrings.forEach { free($0) } }
        lock.lock()
        if cancelled {
            lock.unlock()
            return CommandResult(output: "", errorOutput: "", status: -1, wasCancelled: true, truncated: false)
        }
        var pid: pid_t = 0
        let launchError = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, &envp)
        if launchError == 0 { processID = pid }
        lock.unlock()
        guard launchError == 0 else { throw POSIXError(POSIXErrorCode(rawValue: launchError) ?? .EIO) }
        // Stop noisy commands as well as bounding what the viewer reads. Private files
        // avoid pipe backpressure; this watchdog prevents unbounded disk growth.
        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        monitor.schedule(deadline: .now() + 0.05, repeating: 0.05)
        monitor.setEventHandler { [weak self] in
            guard let self else { return }
            let exceeded = [stdoutURL, stderrURL].contains { url in
                ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0 > max(1, limit)
            }
            if exceeded {
                self.lock.lock(); defer { self.lock.unlock() }
                if self.processID == pid { kill(-pid, SIGKILL) }
            }
        }
        monitor.resume()
        defer { monitor.cancel() }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        lock.lock(); processID = 0; let wasCancelled = cancelled; lock.unlock()
        func read(_ url: URL) throws -> (String, Bool) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: max(1, limit) + 1) ?? Data()
            return (String(decoding: data.prefix(max(1, limit)), as: UTF8.self), data.count > limit)
        }
        let output = try read(stdoutURL), errors = try read(stderrURL)
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandResult(output: output.0, errorOutput: errors.0, status: code,
                             wasCancelled: wasCancelled, truncated: output.1 || errors.1)
    }
}

public struct UserCommand: Codable, Sendable {
    public var title: String
    public var command: String
    public init(title: String, command: String) { self.title = title; self.command = command }
}
public struct ExtensionAction: Codable, Sendable {
    public var pattern: String
    public var application: String
    public init(pattern: String, application: String) { self.pattern = pattern; self.application = application }
}
public struct HighlightRule: Codable, Sendable {
    public var pattern: String
    public var color: String
    public init(pattern: String, color: String) { self.pattern = pattern; self.color = color }
}
