import Foundation
import os

/// A serial executor that runs every job on one thread of its own.
///
/// ``MLXLanguageModel`` uses it as its actor executor, so everything the actor does, MLX
/// evaluation included, happens on this thread and never on a thread of Swift's cooperative pool
/// (specification section 14.1). A generation is one long synchronous job; other calls to the
/// actor wait behind it in arrival order.
///
/// The thread keeps the executor alive. The owner calls ``shutdown()`` when it goes away: the
/// thread then finishes the jobs it already has and exits.
final class DedicatedThreadExecutor: SerialExecutor {
    private struct State: Sendable {
        var jobs: [UnownedJob] = []
        var isShutDown = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Counts the jobs waiting, plus one for the shutdown request.
    private let wake = DispatchSemaphore(value: 0)

    /// The name of the thread, visible in debuggers and crash logs.
    let threadName: String

    /// Starts the thread.
    ///
    /// - Parameters:
    ///   - threadName: Name of the thread.
    ///   - stackSize: Stack size in bytes. Secondary threads get 512 KB by default, which is tight
    ///     for a recursive template renderer on top of a deep call stack.
    ///   - qualityOfService: Scheduling class of the thread.
    init(
        threadName: String,
        stackSize: Int = 4 * 1024 * 1024,
        qualityOfService: QualityOfService = .userInitiated
    ) {
        self.threadName = threadName
        let thread = Thread { [self] in
            self.runLoop()
        }
        thread.name = threadName
        thread.stackSize = stackSize
        thread.qualityOfService = qualityOfService
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        state.withLock { $0.jobs.append(job) }
        wake.signal()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Asks the thread to exit once the jobs already enqueued have run. Safe to call more than once.
    func shutdown() {
        let isFirstRequest = state.withLock { state -> Bool in
            guard !state.isShutDown else { return false }
            state.isShutDown = true
            return true
        }
        if isFirstRequest {
            wake.signal()
        }
    }

    /// Asked by the Swift runtime when it cannot tell from the current task whether code is
    /// running on this executor. Being on the executor's thread is the answer.
    func checkIsolated() {
        precondition(isCurrentThread, "Expected to be running on the thread \(threadName)")
    }

    /// `true` when the caller runs on this executor's thread.
    var isCurrentThread: Bool {
        Thread.current.threadDictionary[Self.markerKey] as? ObjectIdentifier == ObjectIdentifier(self)
    }

    private static let markerKey = "ZTronSearchEngineMLX.DedicatedThreadExecutor"

    private func runLoop() {
        Thread.current.threadDictionary[Self.markerKey] = ObjectIdentifier(self)
        let executor = asUnownedSerialExecutor()
        while true {
            wake.wait()
            // Every signal stands for one job, except the single one sent by `shutdown()`.
            guard let job = state.withLock({ $0.jobs.isEmpty ? nil : $0.jobs.removeFirst() }) else {
                return
            }
            // The thread never returns to a run loop, so each job drains its own pool: one model
            // forward leaves hundreds of autoreleased wrapper objects behind.
            autoreleasepool {
                job.runSynchronously(on: executor)
            }
        }
    }
}
