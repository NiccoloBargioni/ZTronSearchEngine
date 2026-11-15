import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Section 16, "Concurrency and liveness", and the liveness table of section 11.
final class ConcurrencyTests: XCTestCase {
    /// A corpus large enough for a query to take measurable time.
    private static let heavyItems: [AnySearchable<CatalogKind>] = {
        var corpus = RandomCorpus(seed: 4242)
        return corpus.items(30_000)
    }()

    private func heavyQuery() -> CatalogQuery {
        // Common words: long posting lists, every clause expanded and corrected.
        CatalogQuery(text: "the map of all rounds and doors with power to best steps")
    }

    /// Runs `operation` and fails the test when it does not finish in time: a deadlock guard.
    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: Cancellation before, during and after index search

    func testCancellationBeforeTheSearchStarts() async {
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: TestSupport.configuration(lexicalDebounce: 0.3))
        let task = Task { () -> Int in
            var count = 0
            for await _ in await service.results(for: CatalogQuery(text: "harbor")) { count += 1 }
            return count
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        let cancelledAt = Date()
        task.cancel()
        let count = await task.value
        XCTAssertEqual(count, 0, "cancelled during the debounce: no work, no snapshot")
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.1, "the sleep is cancelled, not waited out")
    }

    func testCancellationDuringTheIndexSearchIsHonouredAtTheNextCheckpoint() async {
        let service = await TestSupport.indexedService(Self.heavyItems)
        let query = heavyQuery()
        // How long the search takes when left alone.
        let clock = Date()
        let complete = await TestSupport.final(service, query)
        let full = Date().timeIntervalSince(clock)
        XCTAssertFalse(TestSupport.ids(complete).isEmpty)

        var worst: TimeInterval = 0
        var interrupted = 0
        for attempt in 0..<40 {
            let task = Task { () -> Int in
                var count = 0
                for await _ in await service.results(for: query, trigger: .submit) { count += 1 }
                return count
            }
            // Cancel at a different point inside the search each time.
            try? await Task.sleep(nanoseconds: UInt64(full * 1_000_000_000 * Double(attempt % 10) / 12))
            let cancelledAt = Date()
            task.cancel()
            let count = await task.value
            worst = max(worst, Date().timeIntervalSince(cancelledAt))
            if count == 0 { interrupted += 1 }
        }
        XCTAssertGreaterThan(interrupted, 0, "at least some cancellations landed inside the search (it takes \(full * 1000) ms)")
        XCTAssertLessThan(worst, 0.010 + full / 4, "cancellation is honoured within 10 ms of the next checkpoint (worst \(worst * 1000) ms)")

        // The service is unharmed: the next query answers in full.
        let after = await TestSupport.final(service, query)
        XCTAssertEqual(TestSupport.ids(after), TestSupport.ids(complete))
    }

    func testTheScoringLoopChecksCancellation() async throws {
        let index = LexicalIndex()
        var corpus = RandomCorpus(seed: 77)
        let items = corpus.items(4_000)
        let service = CatalogService(index: index, configuration: TestSupport.configuration())
        await service.index(items)
        let prepared = SearchPipeline.prepare(
            heavyQuery(), configuration: TestSupport.configuration(), languages: ResolvedLanguages(active: "en"), session: TokenizerSession()
        )
        let request = SearchPipeline.request(for: prepared, profile: .default, configuration: TestSupport.configuration())
        // A task that is already cancelled cannot get past the first checkpoint.
        let task = Task { () -> Bool in
            await Task.yield()
            do {
                _ = try await index.search(request)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        task.cancel()
        let threw = await task.value
        XCTAssertTrue(threw, "Task.checkCancellation() runs inside the scoring loops")
    }

    func testCancellationAfterTheFinalSnapshotIsHarmless() async {
        let service = await TestSupport.indexedService(TestSupport.catalog)
        let task = Task { await TestSupport.final(service, "harbor") }
        let snapshot = await task.value
        task.cancel()
        XCTAssertEqual(snapshot?.isFinal, true)
        let again = await TestSupport.final(service, "harbor")
        XCTAssertEqual(TestSupport.ids(again), TestSupport.ids(snapshot))
    }

    func testCancellingTheConsumerCancelsTheProducerThroughOnTermination() async {
        let stub = StubSemantic()
        await stub.setDelay(seconds: 5)
        var configuration = TestSupport.configuration()
        configuration.semanticHardCap = 10
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: configuration, semantic: stub)
        let task = Task { () -> [SearchPhase] in
            var phases: [SearchPhase] = []
            for await snapshot in await service.results(for: CatalogQuery(text: "harbor"), trigger: .submit) {
                phases.append(snapshot.phase)
            }
            return phases
        }
        // Wait for the semantic phase to be in flight, then walk away.
        let encoding = await eventually { await stub.encodeCalls == 1 }
        XCTAssertTrue(encoding)
        let cancelledAt = Date()
        task.cancel()
        let phases = await task.value
        XCTAssertEqual(phases, [.lexical])
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5, "nobody waits for the 5 s encode")
    }

    func testANewerQueryCancelsThePriorOneBeforeAnyWorkStarts() async {
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: TestSupport.configuration(lexicalDebounce: 0.05))
        let first = await service.results(for: CatalogQuery(text: "harbor"))
        let second = await service.results(for: CatalogQuery(text: "temple"))
        var fromFirst: [CatalogSnapshot] = []
        for await snapshot in first { fromFirst.append(snapshot) }
        var fromSecond: [CatalogSnapshot] = []
        for await snapshot in second { fromSecond.append(snapshot) }
        XCTAssertTrue(fromFirst.isEmpty)
        XCTAssertEqual(fromSecond.count, 1)
        XCTAssertEqual(fromSecond.first?.query.text, "temple")
    }

    // MARK: Stale results

    /// Every snapshot a stream yields belongs to that stream's own query and generation, and
    /// once a newer query has been issued an older stream never yields again.
    func testNoStaleSnapshotsOverRandomizedQuerySequences() async {
        let stub = StubSemantic()
        var corpus = RandomCorpus(seed: 2024)
        let service = await TestSupport.indexedService(
            corpus.items(300),
            configuration: TestSupport.configuration(lexicalDebounce: 0.0004, semanticDebounce: 0.0008),
            semantic: stub
        )
        actor Ledger {
            var mismatched = 0
            var published = 0
            var finals = 0

            func received(_ snapshot: CatalogSnapshot, expected: CatalogQuery, streamGeneration: UInt64?) {
                published += 1
                if snapshot.isFinal { finals += 1 }
                if snapshot.query != expected { mismatched += 1 }
                if let streamGeneration, snapshot.generation != streamGeneration { mismatched += 1 }
            }
        }
        let ledger = Ledger()
        let changes = 10_000
        var consumers: [Task<Void, Never>] = []
        var previousGeneration: UInt64 = 0

        for step in 0..<changes {
            let query = corpus.query()
            let stream = await service.results(for: query, trigger: step % 3 == 0 ? .submit : .typing)
            // `results(for:)` has returned: every older stream is now obsolete.
            consumers.append(Task {
                var own: UInt64?
                for await snapshot in stream {
                    if own == nil { own = snapshot.generation }
                    await ledger.received(snapshot, expected: query, streamGeneration: own)
                }
            })
            // Sometimes let the query run to completion, sometimes type over it at once.
            switch corpus.random.int(0..<8) {
            case 0: try? await Task.sleep(nanoseconds: 2_000_000)
            case 1, 2: await Task.yield()
            default: break
            }
            if step % 500 == 499 {
                // Generations only ever grow.
                let final = await TestSupport.final(service, "map")
                XCTAssertGreaterThan(final?.generation ?? 0, previousGeneration)
                previousGeneration = final?.generation ?? 0
            }
        }
        for consumer in consumers { await consumer.value }

        let mismatched = await ledger.mismatched
        let published = await ledger.published
        let finals = await ledger.finals
        XCTAssertEqual(mismatched, 0, "every snapshot belongs to its own stream's query and generation")
        XCTAssertGreaterThan(published, 0)
        XCTAssertLessThanOrEqual(finals, changes + 20)
        // The last query issued is never cancelled by anything: it must have completed.
        let last = await TestSupport.final(service, "map")
        XCTAssertEqual(last?.isFinal, true)
    }

    /// The service-side half of "no stale results": a producer never yields after a newer query
    /// has been accepted. The stream of an older query is finished without another element.
    func testAnObsoleteProducerNeverYields() async {
        let stub = StubSemantic()
        await stub.setDelay(seconds: 0.05)
        var corpus = RandomCorpus(seed: 31)
        let service = await TestSupport.indexedService(corpus.items(200), semantic: stub)
        for _ in 0..<60 {
            let old = await service.results(for: CatalogQuery(text: "map round"), trigger: .submit)
            var iterator = old.makeAsyncIterator()
            // Take the lexical snapshot, so the producer is parked in the semantic phase.
            let lexical = await iterator.next()
            XCTAssertEqual(lexical?.phase, .lexical)
            XCTAssertEqual(lexical?.isFinal, false)
            // A newer query arrives.
            let newer = await service.results(for: CatalogQuery(text: "door"), trigger: .submit)
            // The old stream must end without the semantic snapshot it was working on.
            let late = await iterator.next()
            XCTAssertNil(late, "a snapshot was published after a newer query started")
            var phases: [SearchPhase] = []
            for await snapshot in newer { phases.append(snapshot.phase) }
            XCTAssertEqual(phases, [.lexical, .semantic])
        }
    }

    // MARK: Reentrancy

    func testNoDeadlockUnderReentrantCallsIntoTheService() async {
        var corpus = RandomCorpus(seed: 808)
        let items = corpus.items(1_500)
        let extra = corpus.items(400, prefix: "extra")
        let stub = StubSemantic()
        let service = await TestSupport.indexedService(items, semantic: stub)
        let queries = (0..<40).map { _ in corpus.query() }

        let finished = await withTimeout(60) {
            await withTaskGroup(of: Void.self) { group in
                for worker in 0..<12 {
                    group.addTask {
                        for step in 0..<40 {
                            switch (worker + step) % 9 {
                            case 0:
                                await service.index(Array(extra[(step * 7 % 380)..<(step * 7 % 380 + 20)]))
                            case 1:
                                await service.remove((0..<5).map { SearchableID("extra-\(($0 + step) % 400)") })
                            case 2:
                                _ = await service.suggestions(for: "ma", limit: 5)
                            case 3:
                                if let snapshot = await TestSupport.final(service, queries[step % queries.count]), let cursor = snapshot.nextCursor {
                                    _ = try? await service.page(after: cursor, generation: snapshot.generation)
                                }
                            case 4:
                                _ = await service.count
                                _ = await service.document(for: SearchableID("doc-\(step)"))
                            case 5:
                                await service.cancel()
                            case 6 where step % 20 == 0:
                                await service.setLocale(Locale(identifier: step % 40 == 0 ? "it" : "en"))
                            default:
                                for await _ in await service.results(for: queries[(worker * 3 + step) % queries.count], trigger: .submit) {}
                            }
                        }
                    }
                }
                await group.waitForAll()
            }
            return true
        }
        XCTAssertEqual(finished, true, "the mixed workload must finish: no deadlock, no lost continuation")

        // The service still answers, and its index is consistent.
        let snapshot = await TestSupport.final(service, "map")
        XCTAssertEqual(snapshot?.isFinal, true)
        let count = await service.count
        XCTAssertGreaterThanOrEqual(count, 1_500)
    }

    func testConcurrentUpsertsAndRemovalsLeaveAConsistentIndex() async {
        var corpus = RandomCorpus(seed: 55)
        let batches = (0..<16).map { corpus.items(60, prefix: "batch\($0)") }
        let service = CatalogService(index: LexicalIndex(), configuration: TestSupport.configuration())
        await withTaskGroup(of: Void.self) { group in
            for batch in batches {
                group.addTask { await service.index(batch) }
            }
            await group.waitForAll()
        }
        await withTaskGroup(of: Void.self) { group in
            for batch in 0..<8 {
                group.addTask { await service.remove((0..<60).map { SearchableID("batch\(batch)-\($0)") }) }
            }
            await group.waitForAll()
        }
        let count = await service.count
        XCTAssertEqual(count, 8 * 60)
        // Whatever order the mutations ran in, the result is the index of the surviving documents.
        let fresh = await TestSupport.indexedService(batches[8...].flatMap { $0 })
        for _ in 0..<30 {
            let query = corpus.query()
            let lhs = RankingFingerprint(await TestSupport.final(service, query))
            let rhs = RankingFingerprint(await TestSupport.final(fresh, query))
            XCTAssertEqual(lhs, rhs, query.text)
        }
    }

    // MARK: Bounded work

    func testAtMostTwoThousandLexicalCandidatesAreScored() async {
        // 6,000 documents all contain "lantern": the candidate cap binds.
        let items: [AnySearchable<CatalogKind>] = (0..<6_000).map {
            Tool(id: String(format: "tool-%05d", $0), title: $0 % 3 == 0 ? "Lantern \($0)" : "Planner \($0)", text: "a lantern for the road")
        }.erased()
        let index = LexicalIndex()
        let service = CatalogService(index: index, configuration: TestSupport.configuration())
        await service.index(items)
        let prepared = SearchPipeline.prepare(
            CatalogQuery(text: "lantern"), configuration: TestSupport.configuration(), languages: ResolvedLanguages(active: "en"), session: TokenizerSession()
        )
        let response = try? await index.search(SearchPipeline.request(for: prepared, profile: .default, configuration: TestSupport.configuration()))
        XCTAssertEqual(response?.lexical.count, 200, "each channel brings at most 200 entries into fusion")
        // Candidates are admitted heaviest field first, so the capped set is the title matches.
        XCTAssertTrue(response?.lexical.allSatisfy { Int($0.id.rawValue.dropFirst(5))! % 3 == 0 } ?? false)

        var tight = TestSupport.configuration()
        tight.limits = SearchLimits(lexicalCandidates: 50, fusionEntriesPerChannel: 200)
        let capped = try? await index.search(SearchPipeline.request(for: prepared, profile: .default, configuration: tight))
        XCTAssertEqual(capped?.lexical.count, 50, "never more candidates than the limit")
    }

    func testPrefixExpansionIsCappedAtThirtyTwoTermsAndFuzzyAtEightPerToken() async {
        // 100 distinct terms share the prefix "lan"; 20 sit one edit from "lantxrn".
        var titles: [String] = (0..<100).map { "lan" + String(repeating: "a", count: $0 % 5) + "q\(Character(UnicodeScalar(97 + $0 % 26)!))" + String($0 / 26 == 0 ? "" : String(repeating: "z", count: $0 / 26)) }
        titles += (0..<20).map { "lant\(Character(UnicodeScalar(97 + $0)!))rn" }
        let items: [AnySearchable<CatalogKind>] = titles.enumerated().map { Tool(id: "t\($0)", title: $1, text: "x") }.erased()
        let service = await TestSupport.indexedService(items)
        var query = CatalogQuery(text: "lan")
        query.limit = 200
        let prefix = await TestSupport.final(service, query)
        XCTAssertEqual(prefix?.hits.count, 32, "prefix expansion of the final token is capped at 32 terms")

        var typo = CatalogQuery(text: "lantxrn ")
        typo.limit = 200
        let fuzzy = await TestSupport.final(service, typo)
        XCTAssertEqual(fuzzy?.hits.count, 8, "at most 8 candidates per token")
        XCTAssertTrue(fuzzy?.hits.allSatisfy { $0.channels == [.fuzzy] } ?? false)
    }
}
