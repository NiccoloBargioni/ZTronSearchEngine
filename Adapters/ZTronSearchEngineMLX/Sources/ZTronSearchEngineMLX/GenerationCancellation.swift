import Foundation
import os

/// The cancellation signal of one generation.
///
/// A generation runs as one synchronous job on the runtime's thread, so nothing can reach it
/// through the actor while it runs. This flag can be set from any thread: by the stream when its
/// consumer goes away, and by `unload()`. Cancelling also cancels the generation's task, which is
/// what interrupts a long prompt prefill inside mlx-swift-lm.
final class GenerationCancellation: Sendable {
    private struct State: Sendable {
        var isCancelled = false
        var task: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// `true` once ``cancel()`` has been called.
    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// Ties the generation's task to this signal. A signal that is already cancelled cancels the
    /// task at once.
    func attach(_ task: Task<Void, Never>) {
        let isCancelled = state.withLock { state -> Bool in
            state.task = task
            return state.isCancelled
        }
        if isCancelled {
            task.cancel()
        }
    }

    /// Requests the generation to stop. Safe to call from any thread, any number of times.
    func cancel() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isCancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// The generations that are running or waiting for the runtime's thread.
final class GenerationRegistry: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: GenerationCancellation]())

    /// Creates and records the cancellation signal of a new generation.
    func register() -> GenerationCancellation {
        let cancellation = GenerationCancellation()
        active.withLock { $0[ObjectIdentifier(cancellation)] = cancellation }
        return cancellation
    }

    /// Forgets a generation that has ended.
    func unregister(_ cancellation: GenerationCancellation) {
        active.withLock { $0[ObjectIdentifier(cancellation)] = nil }
    }

    /// Cancels every generation that has not ended yet.
    func cancelAll() {
        let all = active.withLock { Array($0.values) }
        for cancellation in all {
            cancellation.cancel()
        }
    }

    /// How many generations are running or waiting.
    var count: Int {
        active.withLock { $0.count }
    }

    /// `true` when there is at least one generation and each has been asked to stop.
    var isEveryGenerationCancelled: Bool {
        let all = active.withLock { Array($0.values) }
        return !all.isEmpty && all.allSatisfy(\.isCancelled)
    }
}
