import Foundation

/// A worker reports only measured units. Missing totals deliberately produce an indeterminate bar.
public struct OperationProgress: Sendable {
    public var completedItems: Int
    public var totalItems: Int?
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var currentPath: String?
    public var currentFileBytes: Int64
    public var currentFileTotalBytes: Int64?

    public init(completedItems: Int = 0, totalItems: Int? = nil, completedBytes: Int64 = 0,
                totalBytes: Int64? = nil, currentPath: String? = nil, currentFileBytes: Int64 = 0,
                currentFileTotalBytes: Int64? = nil) {
        self.completedItems = completedItems; self.totalItems = totalItems
        self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.currentPath = currentPath
        self.currentFileBytes = currentFileBytes; self.currentFileTotalBytes = currentFileTotalBytes
    }

    public var fraction: Double? {
        if let totalBytes, totalBytes > 0 { return min(1, max(0, Double(completedBytes) / Double(totalBytes))) }
        if let totalItems, totalItems > 0 { return min(1, max(0, Double(completedItems) / Double(totalItems))) }
        return nil
    }
}

public enum BackgroundTaskState: Sendable {
    case queued, running, cancelling, completed, failed, cancelled, interrupted
    public var isActive: Bool { self == .queued || self == .running || self == .cancelling }
}

public struct BackgroundTaskSnapshot: Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let state: BackgroundTaskState
    public let progress: OperationProgress
    public let error: String?
    public var canResume: Bool = false
}

public enum BackgroundTaskError: LocalizedError {
    case cancelled
    public var errorDescription: String? { "Aufgabe abgebrochen." }
}

/// One worker runs at a time. Cancellation of a running worker is cooperative: the next task
/// starts only after that worker returns, so conflicting file operations cannot overlap.
public final class BackgroundTaskQueue: @unchecked Sendable {
    private final class Job {
        let id: UUID
        let title: String
        var detail: String
        var state: BackgroundTaskState = .queued
        var progress = OperationProgress()
        var error: String?
        var recoverable = false
        var cancellation: (() -> Void)?
        var cancelledBeforeStart: (() -> Void)?
        init(id: UUID, title: String, detail: String, cancellation: @escaping () -> Void) {
            self.id = id; self.title = title; self.detail = detail; self.cancellation = cancellation
        }
        var snapshot: BackgroundTaskSnapshot {
            BackgroundTaskSnapshot(id: id, title: title, detail: detail, state: state, progress: progress, error: error, canResume: recoverable && !state.isActive && state != .completed)
        }
    }
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "app.panerook.tasks", qos: .userInitiated)
    private var jobs: [Job] = []
    private var changeHandler: (([BackgroundTaskSnapshot]) -> Void)?
    private var notificationPending = false
    public init() {}

    /// Change notifications and completions always arrive on the main queue.
    public var onChange: (([BackgroundTaskSnapshot]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return changeHandler }
        set { lock.lock(); changeHandler = newValue; lock.unlock() }
    }
    public var snapshots: [BackgroundTaskSnapshot] {
        lock.lock(); defer { lock.unlock() }; return jobs.map(\.snapshot)
    }

    @discardableResult
    public func submit<Value>(id: UUID = UUID(), recoverable: Bool = false, title: String, detail: String = "", cancellation: @escaping () -> Void = {},
                              work: @escaping (@escaping (OperationProgress) -> Void) throws -> Value,
                              completion: @escaping (Result<Value, Error>) -> Void) -> UUID {
        let job = Job(id: id, title: title, detail: detail, cancellation: cancellation)
        job.cancelledBeforeStart = { completion(.failure(BackgroundTaskError.cancelled)) }
        lock.lock()
        guard !jobs.contains(where: { $0.id == id && $0.state.isActive }) else { lock.unlock(); return id }
        jobs.removeAll { $0.id == id }
        job.recoverable = recoverable
        jobs.append(job)
        notifyLocked()
        worker.async { [self, job] in
            lock.lock()
            guard job.state == .queued else { lock.unlock(); return }
            job.state = .running; job.cancelledBeforeStart = nil; notifyLocked(); lock.unlock()
            var result = Result { try work { [weak self, weak job] progress in
                guard let self, let job else { return }
                self.lock.lock()
                if job.state == .running { job.progress = progress; self.notifyLocked() }
                self.lock.unlock()
            } }
            lock.lock()
            if job.state == .cancelling {
                job.state = .cancelled
                // Recovery may itself fail. Keep the worker's precise error and
                // recovery paths instead of hiding them behind a generic cancel.
                if case .failure(let error) = result { job.error = error.localizedDescription }
                else { result = .failure(BackgroundTaskError.cancelled) }
            } else {
                switch result {
                case .success: job.state = .completed
                case .failure(let error): job.state = .failed; job.error = error.localizedDescription
                }
            }
            job.cancellation = nil
            notifyLocked(); lock.unlock()
            DispatchQueue.main.async { completion(result) }
        }
        lock.unlock()
        return job.id
    }

    public func cancel(_ id: UUID) {
        lock.lock()
        guard let job = jobs.first(where: { $0.id == id }), job.state == .queued || job.state == .running else {
            lock.unlock(); return
        }
        let cancellation = job.cancellation
        let completion = job.state == .queued ? job.cancelledBeforeStart : nil
        job.state = job.state == .queued ? .cancelled : .cancelling
        job.cancelledBeforeStart = nil
        if job.state == .cancelled { job.cancellation = nil }
        notifyLocked(); lock.unlock()
        cancellation?()
        if let completion { DispatchQueue.main.async(execute: completion) }
    }
    public func cancelAll() { snapshots.filter { $0.state.isActive }.forEach { cancel($0.id) } }
    public func clearFinished() {
        lock.lock(); jobs.removeAll { !$0.state.isActive && !$0.snapshot.canResume }; notifyLocked(); lock.unlock()
    }
    public func restoreTransfer(_ transfer: RecoverableTransfer) {
        lock.lock(); defer { lock.unlock() }
        guard !jobs.contains(where: { $0.id == transfer.id }) else { return }
        let job = Job(id: transfer.id, title: transfer.title, detail: transfer.detail, cancellation: {})
        switch transfer.state {
        case .completed: job.state = .completed
        case .failed: job.state = .failed
        case .cancelled: job.state = .cancelled
        default: job.state = .interrupted
        }
        if let entries = transfer.entries {
            job.progress = OperationProgress(completedItems: entries.filter { $0.destination != nil && $0.error == nil }.count, totalItems: entries.count)
        }
        job.error = transfer.error
        job.recoverable = true
        jobs.append(job); notifyLocked()
    }
    public func updateDetail(_ id: UUID, detail: String) {
        lock.lock(); defer { lock.unlock() }
        jobs.first { $0.id == id }?.detail = detail; notifyLocked()
    }
    public func removeInactive(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        jobs.removeAll { $0.id == id && !$0.state.isActive }; notifyLocked()
    }
    /// Called under the lock. Coalescing bounds main-queue work even for byte-level updates.
    private func notifyLocked() {
        guard !notificationPending else { return }
        notificationPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notificationPending = false
            let snapshots = self.jobs.map(\.snapshot), handler = self.changeHandler
            self.lock.unlock()
            handler?(snapshots)
        }
    }
}
