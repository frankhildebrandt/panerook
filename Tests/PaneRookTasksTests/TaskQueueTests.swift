import XCTest
@testable import PaneRookTasks

final class TaskQueueTests: XCTestCase {
    func testCancellationPreservesWorkerRecoveryError() {
        let queue = BackgroundTaskQueue()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "recovery details retained")
        let message = "Wiederherstellung fehlgeschlagen: /tmp/recovery/0"
        let id = queue.submit(title: "rename", cancellation: { release.signal() }, work: { _ in
            started.signal(); release.wait()
            throw NSError(domain: "recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }, completion: { (result: Result<Void, Error>) in
            guard case .failure(let error) = result else { XCTFail(); done.fulfill(); return }
            XCTAssertEqual(error.localizedDescription, message)
            done.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        queue.cancel(id)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(queue.snapshots.first?.state, .cancelled)
        XCTAssertEqual(queue.snapshots.first?.error, message)
    }
    func testFIFOAndFailedTaskDoNotBlockFollowingWork() {
        let queue = BackgroundTaskQueue()
        let done = expectation(description: "all completions"); done.expectedFulfillmentCount = 3
        let firstStarted = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lock = NSLock(); var order: [Int] = []
        func record(_ value: Int) { lock.lock(); order.append(value); lock.unlock() }
        queue.submit(title: "first", work: { _ in
            record(1); firstStarted.signal(); release.wait()
        }, completion: { result in XCTAssertTrue(Thread.isMainThread); if case .failure = result { XCTFail() }; done.fulfill() })
        XCTAssertEqual(firstStarted.wait(timeout: .now() + 2), .success)
        queue.submit(title: "failure", work: { _ in
            record(2); throw NSError(domain: "test", code: 7)
        }, completion: { (result: Result<Void, Error>) in if case .success = result { XCTFail() }; done.fulfill() })
        queue.submit(title: "third", work: { _ in record(3) }, completion: { _ in done.fulfill() })
        XCTAssertEqual(queue.snapshots.map(\.state), [.running, .queued, .queued])
        release.signal(); wait(for: [done], timeout: 3)
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertEqual(queue.snapshots.map(\.state), [.completed, .failed, .completed])
    }

    func testCancellingPendingTaskNeverExecutesIt() {
        let queue = BackgroundTaskQueue()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = expectation(description: "running and cancelled complete"); done.expectedFulfillmentCount = 2
        let cancellation = expectation(description: "token cancelled")
        queue.submit(title: "blocking", work: { _ in started.signal(); release.wait() }, completion: { _ in done.fulfill() })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let pending = queue.submit(title: "pending", cancellation: { cancellation.fulfill() }, work: { _ in
            XCTFail("Cancelled queued work must not execute")
        }, completion: { (result: Result<Void, Error>) in
            guard case .failure(BackgroundTaskError.cancelled) = result else { XCTFail(); done.fulfill(); return }
            done.fulfill()
        })
        queue.cancel(pending); queue.cancel(pending)
        XCTAssertEqual(queue.snapshots.last?.state, .cancelled)
        release.signal(); wait(for: [done, cancellation], timeout: 3)
        XCTAssertEqual(queue.snapshots.last?.state, .cancelled)
    }

    func testRunningCancellationWaitsForWorkerAndProgressIsPublishedOnMainThread() {
        let queue = BackgroundTaskQueue()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "cancelled worker completes")
        let notified = expectation(description: "progress published")
        var didNotify = false
        queue.onChange = { snapshots in
            XCTAssertTrue(Thread.isMainThread)
            if snapshots.first?.progress.completedBytes == 40, !didNotify {
                didNotify = true; notified.fulfill()
            }
        }
        let id = queue.submit(title: "copy", cancellation: { release.signal() }, work: { report in
            report(OperationProgress(completedItems: 1, totalItems: 2, completedBytes: 40, totalBytes: 100, currentPath: "/source"))
            started.signal(); release.wait()
            // A cooperative worker can return normally after noticing cancellation.
        }, completion: { (result: Result<Void, Error>) in
            guard case .failure(BackgroundTaskError.cancelled) = result else { XCTFail(); finished.fulfill(); return }
            finished.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(queue.snapshots.first?.progress.fraction, 0.4)
        wait(for: [notified], timeout: 2)
        queue.cancel(id); wait(for: [finished], timeout: 2)
        XCTAssertEqual(queue.snapshots.first?.state, .cancelled)
        queue.clearFinished(); XCTAssertTrue(queue.snapshots.isEmpty)
    }
}
