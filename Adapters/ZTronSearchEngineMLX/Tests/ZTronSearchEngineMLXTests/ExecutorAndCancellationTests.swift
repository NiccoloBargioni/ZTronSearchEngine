import XCTest
@testable import ZTronSearchEngineMLX

/// An actor that runs on a `DedicatedThreadExecutor`, the way `MLXLanguageModel` does.
private actor ThreadBoundActor {
    nonisolated let executor: DedicatedThreadExecutor
    private var values: [Int] = []

    init(threadName: String) {
        executor = DedicatedThreadExecutor(threadName: threadName)
    }

    deinit {
        executor.shutdown()
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func threadFacts() -> (name: String?, isMain: Bool, isExecutorThread: Bool) {
        (Thread.current.name, Thread.isMainThread, executor.isCurrentThread)
    }

    func append(_ value: Int) -> Int {
        values.append(value)
        return values.count
    }

    func sum() -> Int {
        values.reduce(0, +)
    }

    func stackSize() -> Int {
        Thread.current.stackSize
    }

    /// Runs the isolation checks the Swift runtime can make from inside isolated code.
    func passesIsolationChecks() -> Bool {
        assertIsolated()
        preconditionIsolated()
        executor.checkIsolated()
        return true
    }
}

final class DedicatedThreadExecutorTests: XCTestCase {
    func testIsolatedCodeRunsOnTheNamedThread() async {
        let actor = ThreadBoundActor(threadName: "ZTronSearchEngineMLXTests.worker")
        let facts = await actor.threadFacts()
        XCTAssertEqual(facts.name, "ZTronSearchEngineMLXTests.worker")
        XCTAssertFalse(facts.isMain)
        XCTAssertTrue(facts.isExecutorThread)
        XCTAssertFalse(actor.executor.isCurrentThread, "the test itself does not run on the executor's thread")
    }

    func testIsolationChecksPassOnTheExecutorsThread() async {
        let actor = ThreadBoundActor(threadName: "checked")
        let passed = await actor.passesIsolationChecks()
        XCTAssertTrue(passed)
    }

    func testTwoExecutorsUseTwoThreads() async {
        let first = ThreadBoundActor(threadName: "first")
        let second = ThreadBoundActor(threadName: "second")
        let firstFacts = await first.threadFacts()
        let secondFacts = await second.threadFacts()
        XCTAssertEqual(firstFacts.name, "first")
        XCTAssertEqual(secondFacts.name, "second")
        XCTAssertFalse(first.executor === second.executor)
    }

    func testJobsFromManyTasksAllRunAndNeverOverlap() async {
        let actor = ThreadBoundActor(threadName: "serial")
        await withTaskGroup(of: Void.self) { group in
            for value in 1 ... 500 {
                group.addTask {
                    _ = await actor.append(value)
                }
            }
        }
        let sum = await actor.sum()
        let count = await actor.append(0)
        XCTAssertEqual(sum, 500 * 501 / 2)
        XCTAssertEqual(count, 501)
    }

    func testThreadHasALargerStackThanTheDefault() async {
        // Secondary threads get 512 KB unless told otherwise.
        let actor = ThreadBoundActor(threadName: "deep")
        let stackSize = await actor.stackSize()
        XCTAssertGreaterThanOrEqual(stackSize, 4 * 1_024 * 1_024)
    }

    func testThreadExitsAfterShutdown() async throws {
        weak var weakExecutor: DedicatedThreadExecutor?
        do {
            let actor = ThreadBoundActor(threadName: "short-lived")
            weakExecutor = actor.executor
            _ = await actor.append(1)
        }
        // The thread holds the executor until its loop ends; the actor's deinit asks it to end.
        let deadline = Date().addingTimeInterval(5)
        while weakExecutor != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(weakExecutor)
    }

    func testShutdownTwiceIsHarmless() async throws {
        weak var weakExecutor: DedicatedThreadExecutor?
        do {
            let executor = DedicatedThreadExecutor(threadName: "manual")
            weakExecutor = executor
            XCTAssertFalse(executor.isCurrentThread)
            executor.shutdown()
            executor.shutdown()
        }
        let deadline = Date().addingTimeInterval(5)
        while weakExecutor != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(weakExecutor)
    }
}

final class GenerationCancellationTests: XCTestCase {
    func testCancelSetsTheFlag() {
        let cancellation = GenerationCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        cancellation.cancel()
        cancellation.cancel()
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testCancelReachesTheAttachedTask() async {
        let cancellation = GenerationCancellation()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        cancellation.attach(task)
        cancellation.cancel()
        await task.value
        XCTAssertTrue(task.isCancelled)
    }

    func testAttachingToACancelledSignalCancelsTheTaskAtOnce() async {
        let cancellation = GenerationCancellation()
        cancellation.cancel()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
        }
        cancellation.attach(task)
        await task.value
        XCTAssertTrue(task.isCancelled)
    }

    func testRegistryTracksAndCancelsGenerations() {
        let registry = GenerationRegistry()
        XCTAssertEqual(registry.count, 0)
        XCTAssertFalse(registry.isEveryGenerationCancelled, "an empty registry has nothing cancelled")

        let first = registry.register()
        let second = registry.register()
        XCTAssertEqual(registry.count, 2)
        XCTAssertFalse(registry.isEveryGenerationCancelled)

        first.cancel()
        XCTAssertFalse(registry.isEveryGenerationCancelled)

        registry.cancelAll()
        XCTAssertTrue(first.isCancelled)
        XCTAssertTrue(second.isCancelled)
        XCTAssertTrue(registry.isEveryGenerationCancelled)

        registry.unregister(first)
        registry.unregister(first)
        XCTAssertEqual(registry.count, 1)
        registry.unregister(second)
        XCTAssertEqual(registry.count, 0)
    }
}
