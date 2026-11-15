import XCTest
import ZTronSearchFixtures
@testable import ZTronSearchEngine

/// Sections 9 (snapshot semantics), 7.4 (rerank), 10 (throttling) and 15.5 (degradation policy).
final class SnapshotPipelineTests: XCTestCase {
    private func semantic(_ scripts: [String: [String]] = [:]) async -> StubSemantic {
        let stub = StubSemantic()
        for (query, ids) in scripts { await stub.script(query, ids) }
        return stub
    }

    // MARK: Two snapshots

    func testLexicalThenSemanticSnapshot() async {
        // The semantic channel finds a paraphrase the lexical channel cannot.
        let stub = await semantic(["cold port": ["map-harbor", "image-harbor", "ghost"]])
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "cold port"))

        XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic])
        XCTAssertEqual(snapshots.map(\.isFinal), [false, true])
        XCTAssertEqual(Set(snapshots.map(\.generation)).count, 1, "one query, one generation")
        XCTAssertTrue(TestSupport.ids(snapshots.first).isEmpty)
        XCTAssertNil(snapshots.first?.nextCursor)
        // Ids the index does not hold are dropped; the rest arrive in semantic order.
        XCTAssertEqual(TestSupport.ids(snapshots.last), ["map-harbor", "image-harbor"])
        XCTAssertEqual(snapshots.last?.hits.first?.channels, [.semantic])
        XCTAssertNil(snapshots.last?.hits.first?.matchedField)
        XCTAssertEqual(snapshots.last?.degraded, [])
    }

    func testSemanticSnapshotRefusesTheCachedLexicalLists() async {
        let stub = await semantic(["harbor": ["tool-calc", "map-harbor"]])
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(snapshots.count, 2)
        let lexicalIDs = TestSupport.ids(snapshots.first)
        let fusedIDs = TestSupport.ids(snapshots.last)
        // Everything the lexical snapshot had is still there; the semantic-only hit joined.
        XCTAssertTrue(Set(lexicalIDs).isSubset(of: Set(fusedIDs)))
        XCTAssertTrue(fusedIDs.contains("tool-calc"))
        XCTAssertFalse(lexicalIDs.contains("tool-calc"))
        // A document in every list collects every contribution.
        let harbor = snapshots.last?.hits.first { $0.id == "map-harbor" }
        XCTAssertEqual(harbor?.channels, [.lexical, .fuzzy, .semantic])
        let lexicalOnly = snapshots.first?.hits.first { $0.id == "map-harbor" }
        XCTAssertGreaterThan(harbor?.score ?? 0, lexicalOnly?.score ?? 0)
        let encodes = await stub.encodeCalls
        XCTAssertEqual(encodes, 1, "the query is encoded once")
    }

    func testSemanticHitsRespectHardConstraints() async {
        let stub = await semantic(["cold port": ["map-harbor", "image-harbor", "tool-box"]])
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        let snapshot = await TestSupport.final(service, CatalogQuery(text: "cold port", tokens: [.kind(.image)]))
        XCTAssertEqual(TestSupport.ids(snapshot), ["image-harbor"], "no hit may violate a hard constraint")
        let filtered = await TestSupport.final(service, CatalogQuery(text: "cold port", filters: [.platform(.ios)]))
        XCTAssertEqual(Set(TestSupport.ids(filtered)), ["map-harbor", "tool-box"])
    }

    func testIdentifierQueriesSkipTheSemanticPhase() async {
        let stub = await semantic()
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "m1911-a1"))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.isFinal, true)
        XCTAssertEqual(snapshots.first?.degraded, [.semantic])
        let encodes = await stub.encodeCalls
        XCTAssertEqual(encodes, 0)
    }

    func testWithoutASemanticChannelTheLexicalSnapshotIsFinalAndNothingIsDegraded() async {
        let service = await TestSupport.indexedService(TestSupport.catalog)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.isFinal, true)
        XCTAssertEqual(snapshots.first?.degraded, [])
    }

    // MARK: Throttling

    func testNeverEncodesOnEveryKeystroke() async {
        let stub = await semantic()
        let service = await TestSupport.indexedService(
            TestSupport.catalog,
            configuration: TestSupport.configuration(lexicalDebounce: 0.03, semanticDebounce: 0.12),
            semantic: stub
        )
        // Keystrokes arrive faster than the lexical debounce: each cancels the previous one.
        var streams: [AsyncStream<CatalogSnapshot>] = []
        for text in ["har", "harb", "harbo", "harbor"] {
            streams.append(await service.results(for: CatalogQuery(text: text)))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        var counts: [Int] = []
        var lastSnapshots: [CatalogSnapshot] = []
        for stream in streams {
            var count = 0
            for await snapshot in stream {
                count += 1
                lastSnapshots.append(snapshot)
            }
            counts.append(count)
        }
        XCTAssertEqual(counts, [0, 0, 0, 2], "only the last keystroke publishes")
        XCTAssertEqual(lastSnapshots.map(\.query.text), ["harbor", "harbor"])
        let encodes = await stub.encodeCalls
        XCTAssertEqual(encodes, 1)
    }

    func testDebounceTimersStartAtTheKeystroke() async {
        let stub = await semantic()
        let service = await TestSupport.indexedService(
            TestSupport.catalog,
            configuration: TestSupport.configuration(lexicalDebounce: 0.08, semanticDebounce: 0.25),
            semantic: stub
        )
        let started = Date()
        var arrivals: [TimeInterval] = []
        for await _ in await service.results(for: CatalogQuery(text: "harbor")) {
            arrivals.append(Date().timeIntervalSince(started))
        }
        XCTAssertEqual(arrivals.count, 2)
        XCTAssertGreaterThanOrEqual(arrivals[0], 0.08)
        XCTAssertLessThan(arrivals[0], 0.2)
        // The semantic pause is measured from the keystroke, not from the lexical snapshot.
        XCTAssertGreaterThanOrEqual(arrivals[1], 0.25)
        XCTAssertLessThan(arrivals[1], 0.45)
    }

    func testSubmitRunsEveryPhaseImmediately() async {
        let stub = await semantic()
        let service = await TestSupport.indexedService(
            TestSupport.catalog,
            configuration: TestSupport.configuration(lexicalDebounce: 2, semanticDebounce: 4),
            semantic: stub
        )
        let started = Date()
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"), trigger: .submit)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    // MARK: Degradation

    private func breachingConfiguration(recorder: DiagnosticsRecorder? = nil) -> SearchEngineConfiguration {
        var configuration = TestSupport.configuration(diagnostics: recorder?.sink)
        configuration.semanticHardCap = 0.03
        configuration.rerankHardCap = 0.03
        return configuration
    }

    func testASemanticCapBreachSkipsTheChannelAndTheLexicalSnapshotStands() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        await stub.setDelay(seconds: 0.5)
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: breachingConfiguration(), semantic: stub)
        let started = Date()
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "the cap is a hard cap: nobody waits for the slow encode")

        // The lexical snapshot is never withheld; it is republished as final with the channel degraded.
        XCTAssertEqual(snapshots.map(\.phase), [.lexical, .lexical])
        XCTAssertEqual(snapshots.map(\.isFinal), [false, true])
        XCTAssertEqual(snapshots.first?.degraded, [])
        XCTAssertEqual(snapshots.last?.degraded, [.semantic])
        XCTAssertEqual(TestSupport.ids(snapshots.first), TestSupport.ids(snapshots.last))
        XCTAssertFalse(TestSupport.ids(snapshots.last).contains("tool-calc"))
    }

    func testThreeConsecutiveSemanticBreachesDisableTheChannelUntilTheNextForeground() async {
        let recorder = DiagnosticsRecorder()
        let stub = await semantic(["harbor": ["tool-calc"]])
        await stub.setDelay(seconds: 0.2)
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: breachingConfiguration(recorder: recorder), semantic: stub)
        for _ in 0..<3 {
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertEqual(snapshots.count, 2)
        }
        let afterThree = await stub.encodeCalls
        XCTAssertEqual(afterThree, 3)

        // Disabled for the session: one final lexical snapshot, the encoder is not even called.
        let disabled = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(disabled.count, 1)
        XCTAssertEqual(disabled.first?.isFinal, true)
        XCTAssertEqual(disabled.first?.degraded, [.semantic])
        let stillThree = await stub.encodeCalls
        XCTAssertEqual(stillThree, 3)

        // Re-enabled on the next foreground.
        await stub.setDelay(seconds: 0)
        await service.handleForeground()
        let restored = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(restored.map(\.phase), [.lexical, .semantic])
        XCTAssertTrue(TestSupport.ids(restored.last).contains("tool-calc"))

        let diagnostics = await recorder.finish()
        XCTAssertEqual(diagnostics.filter { if case .channelDegraded(.semantic, _) = $0 { return true } else { return false } }.count, 3)
        XCTAssertEqual(diagnostics.filter { if case .channelDisabled(.semantic, _) = $0 { return true } else { return false } }.count, 1)
    }

    func testABreachCountIsResetByASuccess() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: breachingConfiguration(), semantic: stub)
        for round in 0..<3 {
            await stub.setDelay(seconds: 0.2)
            _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            await stub.setDelay(seconds: 0)
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertEqual(snapshots.last?.phase, .semantic, "round \(round): two breaches then a success never disable")
        }
    }

    func testAMemoryWarningDisablesTheSemanticChannelAndUnloadsTheModels() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker()
        var configuration = TestSupport.configuration()
        configuration.reranking = .on
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: configuration, semantic: stub, reranker: reranker)
        let before = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(before.last?.phase, .reranked)

        await service.handleMemoryWarning()
        let semanticUnloads = await stub.unloadCalls
        let rerankerUnloads = await reranker.unloadCalls
        XCTAssertEqual(semanticUnloads, 1)
        XCTAssertEqual(rerankerUnloads, 1)

        let after = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.degraded, [.semantic, .rerank])
        await service.handleForeground()
        let restored = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(restored.last?.phase, .reranked)
    }

    func testTheMemoryWarningNotificationIsObserved() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        // The notification is posted by name: no UI framework is imported anywhere in core.
        NotificationCenter.default.post(name: Notification.Name("UIApplicationDidReceiveMemoryWarningNotification"), object: nil)
        let unloaded = await eventually { await stub.unloadCalls == 1 }
        XCTAssertTrue(unloaded)
    }

    func testModelsUnloadAfterTheIdleInterval() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker()
        var configuration = TestSupport.configuration()
        configuration.modelIdleUnload = 0.15
        configuration.reranking = .on
        let service = await TestSupport.indexedService(TestSupport.catalog, configuration: configuration, semantic: stub, reranker: reranker)
        _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        let early = await stub.unloadCalls
        XCTAssertEqual(early, 0)
        // A second query restarts the clock.
        try? await Task.sleep(nanoseconds: 80_000_000)
        _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let midway = await stub.unloadCalls
        XCTAssertEqual(midway, 0, "idle is measured from the last use")
        let unloaded = await eventually { await stub.unloadCalls == 1 }
        XCTAssertTrue(unloaded)
        // The reranker unloads with the embedding model.
        let rerankerUnloads = await reranker.unloadCalls
        XCTAssertEqual(rerankerUnloads, 1)
    }

    func testAFailingEmbeddingProviderDegradesWithoutCountingAsABreach() async {
        let stub = await semantic()
        await stub.setFails(true)
        let service = await TestSupport.indexedService(TestSupport.catalog, semantic: stub)
        for _ in 0..<5 {
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertEqual(snapshots.map(\.isFinal), [false, true])
            XCTAssertEqual(snapshots.last?.degraded, [.semantic])
        }
        let calls = await stub.encodeCalls
        XCTAssertEqual(calls, 5, "a failure is not a budget breach: the channel stays enabled")
    }

    // MARK: Rerank

    private func rerankService(
        mode: RerankingMode,
        reranker: StubReranker,
        semantic stub: StubSemantic,
        cap: TimeInterval = 0.4,
        recorder: DiagnosticsRecorder? = nil
    ) async -> CatalogService {
        var configuration = TestSupport.configuration(diagnostics: recorder?.sink)
        configuration.reranking = mode
        configuration.rerankHardCap = cap
        return await TestSupport.indexedService(TestSupport.catalog, configuration: configuration, semantic: stub, reranker: reranker)
    }

    func testThirdSnapshotReordersTheHeadOnDevicesPastTheGate() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        // The cross-encoder prefers the last passage it is shown.
        let reranker = StubReranker { _, passages in passages.indices.map { Float($0) } }
        let service = await rerankService(mode: .on, reranker: reranker, semantic: stub)
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))

        XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic, .reranked])
        // On these devices the semantic snapshot is no longer final.
        XCTAssertEqual(snapshots.map(\.isFinal), [false, false, true])
        XCTAssertEqual(Set(TestSupport.ids(snapshots[1])), Set(TestSupport.ids(snapshots[2])))
        XCTAssertNotEqual(TestSupport.ids(snapshots[1]), TestSupport.ids(snapshots[2]))
        XCTAssertTrue(snapshots[2].hits.allSatisfy { $0.channels.contains(.rerank) })
        XCTAssertTrue(snapshots[1].hits.allSatisfy { !$0.channels.contains(.rerank) })
        let calls = await reranker.scoreCalls
        XCTAssertEqual(calls, 1, "one batched call")
        // Each candidate is paired with its localized surface.
        let passages = await reranker.lastPassages
        XCTAssertEqual(passages.count, snapshots[1].hits.count)
        XCTAssertTrue(passages.contains("Frozen Harbor"))
        XCTAssertTrue(passages.contains("Harbor at dawn\nThe lighthouse over the frozen harbor"))
    }

    func testOffNeverLoadsTheModel() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker()
        let service = await rerankService(mode: .off, reranker: reranker, semantic: stub)
        for _ in 0..<3 {
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic])
            XCTAssertEqual(snapshots.last?.degraded, [])
        }
        let scoreCalls = await reranker.scoreCalls
        let enabledCalls = await reranker.enabledCalls
        XCTAssertEqual(scoreCalls, 0)
        XCTAssertEqual(enabledCalls, 0, ".off never even asks the gate")
    }

    func testAutoCalibratesOnFirstUseAndNeverDelaysASnapshot() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker(enabled: true)
        let service = await rerankService(mode: .auto, reranker: reranker, semantic: stub)
        // The first query triggers the calibration and is answered without the stage.
        let first = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(first.map(\.phase), [.lexical, .semantic])
        XCTAssertEqual(first.last?.isFinal, true)
        let measured = await eventually { await reranker.enabledCalls == 1 }
        XCTAssertTrue(measured)
        // Once measured, the verdict applies; it is not asked for again.
        let enabled = await eventually {
            (await TestSupport.all(service, CatalogQuery(text: "harbor"))).last?.phase == .reranked
        }
        XCTAssertTrue(enabled)
        _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        let asked = await reranker.enabledCalls
        XCTAssertEqual(asked, 1, "one-time calibration")
    }

    func testADeviceThatFailsCalibrationNeverRunsTheStage() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker(enabled: false)
        let service = await rerankService(mode: .auto, reranker: reranker, semantic: stub)
        _ = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        let measured = await eventually { await reranker.enabledCalls == 1 }
        XCTAssertTrue(measured)
        for _ in 0..<3 {
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic])
            XCTAssertEqual(snapshots.last?.isFinal, true)
            XCTAssertEqual(snapshots.last?.degraded, [], "the stage does not exist on this device: nothing is degraded")
        }
        let calls = await reranker.scoreCalls
        XCTAssertEqual(calls, 0, "the reference device never loads the reranker")
    }

    func testRerankIsSkippedWithDegradedSetWhenSemanticWasSkippedOrTheQueryIsTokensOnly() async {
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker()
        let service = await rerankService(mode: .on, reranker: reranker, semantic: stub)
        // Shorter than 3 characters: the semantic phase is skipped, and so is the rerank.
        let short = await TestSupport.all(service, CatalogQuery(text: "ha"))
        XCTAssertEqual(short.count, 1)
        XCTAssertEqual(short.first?.degraded, [.semantic, .rerank])
        // Tokens only.
        let tokens = await TestSupport.all(service, CatalogQuery(text: "", tokens: [.kind(.map)]))
        XCTAssertEqual(tokens.count, 1)
        XCTAssertEqual(tokens.first?.degraded, [.semantic, .rerank])
        let calls = await reranker.scoreCalls
        XCTAssertEqual(calls, 0)
    }

    func testARerankCapBreachFallsBackToTheFusedOrderAndThreeBreachesDisableTheStage() async {
        let recorder = DiagnosticsRecorder()
        let stub = await semantic(["harbor": ["tool-calc"]])
        let reranker = StubReranker { _, passages in passages.indices.map { Float($0) } }
        await reranker.setDelay(seconds: 0.25)
        let service = await rerankService(mode: .on, reranker: reranker, semantic: stub, cap: 0.03, recorder: recorder)

        for _ in 0..<3 {
            let started = Date()
            let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
            // No `.reranked` snapshot: the semantic list is republished as final, fused order intact.
            XCTAssertEqual(snapshots.map(\.phase), [.lexical, .semantic, .semantic])
            XCTAssertEqual(snapshots.map(\.isFinal), [false, false, true])
            XCTAssertEqual(snapshots[2].degraded, [.rerank])
            XCTAssertEqual(TestSupport.ids(snapshots[1]), TestSupport.ids(snapshots[2]))
            XCTAssertEqual(snapshots[1].hits.map(\.score), snapshots[2].hits.map(\.score))
        }
        // Disabled for the session, and recalibration is forced for the next launch.
        let disabled = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(disabled.map(\.phase), [.lexical, .semantic])
        XCTAssertEqual(disabled.last?.isFinal, true)
        XCTAssertEqual(disabled.last?.degraded, [.rerank])
        let calls = await reranker.scoreCalls
        XCTAssertEqual(calls, 3)
        let invalidated = await eventually { await reranker.invalidations == 1 }
        XCTAssertTrue(invalidated)
        let diagnostics = await recorder.finish()
        XCTAssertEqual(diagnostics.filter { if case .channelDisabled(.rerank, _) = $0 { return true } else { return false } }.count, 1)
    }

    func testEditorialPinsApplyAfterTheRerank() async {
        struct Pins: EditorialProvider {
            func decision(for id: SearchableID) throws -> EditorialDecision? { id == "tip-doors" ? .pin(rank: 0) : nil }
        }
        let stub = await semantic(["harbor": ["tool-calc"]])
        // The cross-encoder ranks the pinned document last.
        let reranker = StubReranker { _, passages in passages.map { $0.contains("doors") ? -100 : 1 } }
        var configuration = TestSupport.configuration()
        configuration.reranking = .on
        let service = await TestSupport.indexedService(
            TestSupport.catalog, configuration: configuration, signals: SignalProviders(editorial: Pins()), semantic: stub, reranker: reranker
        )
        let snapshots = await TestSupport.all(service, CatalogQuery(text: "harbor"))
        XCTAssertEqual(snapshots.last?.phase, .reranked)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.hits.first?.id, "tip-doors", "\(snapshot.phase)")
        }
    }

    // MARK: Paging

    func testPagingContinuesTheFinalSnapshotsList() async throws {
        let items: [AnySearchable<CatalogKind>] = (0..<57).map { Tool(id: String(format: "tool-%03d", $0), title: "Lantern \($0)", text: "a lantern") }.erased()
        let service = await TestSupport.indexedService(items)
        var query = CatalogQuery(text: "lantern")
        query.limit = 20
        let firstSnapshot = await TestSupport.final(service, query)
        let first = try XCTUnwrap(firstSnapshot)
        XCTAssertEqual(first.hits.count, 20)

        var collected = first.hits.map(\.id)
        var cursor = first.nextCursor
        var pages = 1
        while let next = cursor {
            let page = try await service.page(after: next, generation: first.generation)
            XCTAssertEqual(page.generation, first.generation)
            XCTAssertTrue(page.isFinal)
            XCTAssertEqual(page.query, query)
            collected.append(contentsOf: page.hits.map(\.id))
            cursor = page.nextCursor
            pages += 1
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(collected.count, 57)
        XCTAssertEqual(Set(collected).count, 57, "no hit is repeated across pages")

        // The same page asked twice is the same page.
        let again = try await service.page(after: SearchCursor(offset: 20), generation: first.generation)
        XCTAssertEqual(again.hits.map(\.id), Array(collected[20..<40]))
    }

    func testACursorFromAStaleGenerationThrows() async throws {
        let items: [AnySearchable<CatalogKind>] = (0..<50).map { Tool(id: "tool-\($0)", title: "Lantern \($0)", text: "a lantern") }.erased()
        let service = await TestSupport.indexedService(items)
        let firstSnapshot = await TestSupport.final(service, "lantern")
        let first = try XCTUnwrap(firstSnapshot)
        let cursor = try XCTUnwrap(first.nextCursor)

        // A query change clears the cursor.
        let secondSnapshot = await TestSupport.final(service, "lantern 4")
        let second = try XCTUnwrap(secondSnapshot)
        XCTAssertGreaterThan(second.generation, first.generation)
        do {
            _ = try await service.page(after: cursor, generation: first.generation)
            XCTFail("a stale cursor must throw")
        } catch let error as SearchError {
            XCTAssertEqual(error, .staleGeneration)
        }
        do {
            _ = try await service.page(after: SearchCursor(offset: 10_000), generation: second.generation)
            XCTFail("a cursor outside the list must throw")
        } catch let error as SearchError {
            XCTAssertEqual(error, .invalidCursor)
        }
        await service.cancel()
        do {
            _ = try await service.page(after: SearchCursor(offset: 0), generation: second.generation)
            XCTFail("reset forgets the results")
        } catch let error as SearchError {
            XCTAssertEqual(error, .staleGeneration)
        }
    }

    func testAtMostTwoHundredHitsAreKeptForPaging() async throws {
        let items: [AnySearchable<CatalogKind>] = (0..<450).map { Tool(id: "tool-\($0)", title: "Lantern \($0)", text: "a lantern") }.erased()
        let service = await TestSupport.indexedService(items)
        var query = CatalogQuery(text: "lantern")
        query.limit = 150
        let firstSnapshot = await TestSupport.final(service, query)
        let first = try XCTUnwrap(firstSnapshot)
        let rest = try await service.page(after: try XCTUnwrap(first.nextCursor), generation: first.generation)
        XCTAssertEqual(first.hits.count + rest.hits.count, 200)
        XCTAssertNil(rest.nextCursor)
    }

    // MARK: Suggestions

    func testSuggestions() async {
        let service = await TestSupport.indexedService(TestSupport.catalog)
        let titles = await service.suggestions(for: "froz", limit: 5)
        XCTAssertEqual(titles.first?.text, "Frozen Harbor")
        XCTAssertEqual(titles.first?.source, .title)
        XCTAssertEqual(titles.first?.itemID, "map-harbor")
        XCTAssertTrue(titles.contains { $0.source == .term && $0.text == "frozen" })

        // The completed last word keeps what was typed before it.
        let twoWords = await service.suggestions(for: "Mystery bo", limit: 5)
        XCTAssertEqual(twoWords.first?.text, "Mystery Box Tracker")
        XCTAssertTrue(twoWords.contains { $0.text == "Mystery box" })

        // Disabled below two characters; at most `limit` per page.
        let tooShort = await service.suggestions(for: "f", limit: 5)
        XCTAssertTrue(tooShort.isEmpty)
        let limited = await service.suggestions(for: "ro", limit: 2)
        XCTAssertEqual(limited.count, 2)
        let unique = await service.suggestions(for: "ha", limit: 10)
        XCTAssertEqual(Set(unique.map(\.id)).count, unique.count)
        // A scan context suggests the same way.
        let scan = TestSupport.scanService(TestSupport.catalog)
        let scanned = await scan.suggestions(for: "froz", limit: 5)
        XCTAssertEqual(scanned.map(\.text), titles.map(\.text))
    }
}
