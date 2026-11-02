import Foundation
import Darwin

/// A serial, cancellable Git reader shared by local inspection features.
final class GitReadOnlyProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var currentProcess: Process?
    private let timeout: TimeInterval
    private let outputLimit: Int

    init(timeout: TimeInterval = 5, outputLimit: Int = 4 * 1024 * 1024) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process = currentProcess, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func run(_ arguments: [String], in directory: URL) -> Data? {
        guard directory.isFileURL, !isCancelled else { return nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("PaneRook-git-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                  attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            let outputURL = temporary.appendingPathComponent("stdout")
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else { return nil }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = directory
            process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                                 "-c", "core.untrackedCache=false"] + arguments
            var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["LC_ALL"] = "C"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_OPTIONAL_LOCKS"] = "0"
            environment["GIT_NO_LAZY_FETCH"] = "1"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            lock.lock()
            guard !cancelled else { lock.unlock(); return nil }
            do { try process.run() } catch { lock.unlock(); return nil }
            currentProcess = process
            lock.unlock()
            defer {
                lock.lock(); currentProcess = nil; lock.unlock()
            }

            // Private files avoid waiting on a pipe inherited by a child process.
            // The watchdog bounds both execution time and the amount read into memory.
            let started = ProcessInfo.processInfo.systemUptime
            let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            monitor.schedule(deadline: .now(), repeating: .milliseconds(25))
            monitor.setEventHandler { [weak self] in
                guard let self else { return }
                let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.intValue ?? 0
                if ProcessInfo.processInfo.systemUptime - started >= self.timeout || size > self.outputLimit {
                    self.lock.lock(); defer { self.lock.unlock() }
                    if self.currentProcess === process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            monitor.resume()
            defer { monitor.cancel() }
            process.waitUntilExit()
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            guard !wasCancelled, process.terminationReason == .exit, process.terminationStatus == 0,
                  ProcessInfo.processInfo.systemUptime - started < timeout else { return nil }
            let input = try FileHandle(forReadingFrom: outputURL)
            defer { try? input.close() }
            let data = try input.read(upToCount: outputLimit + 1) ?? Data()
            guard data.count <= outputLimit else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
